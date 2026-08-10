import Foundation
import IOKit
import IOKit.hid
import ApplicationServices

/// Manager for IOHIDManager to detect toggle/hanja keys at hardware level.
///
/// ## Role
/// Provides hardware-level keyboard monitoring via IOHIDManager.
/// This class serves as a **backup fallback** when CGEventTap fails to start.
///
/// ## Dynamic Key Binding
/// Reads `ConfigurationManager.toggleKeyBinding` and `ConfigurationManager.hanjaKeyBinding`
/// to determine which keys to monitor. Modifier-only bindings are supported;
/// regular/combo bindings are reported as fallback limitations.
///
/// ## Relationship with RightCommandSuppressor
/// - **Primary handler**: `RightCommandSuppressor` (CGEventTap)
/// - **Backup handler**: `IOKitManager` (IOHIDManager)
///
/// The main entry point (`main.swift`) first attempts to start `RightCommandSuppressor`.
/// If that fails, `IOKitManager` takes over as the primary toggle handler.
/// When CGEventTap succeeds, `IOKitManager` remains stopped so there is exactly
/// one active owner. The fallback supports modifier-only bindings; unsupported
/// regular/combo bindings are exposed through `ToggleMonitorStatusStore`.
///
/// ## Primary Use Cases
/// - Accessibility permission check (`hasAccessibilityPermission()`)
/// - Hardware-level key event monitoring when CGEventTap is unavailable
public final class IOKitManager: @unchecked Sendable {
    
    // Singleton - accessed from IOKit callback context
    public static let shared = IOKitManager()
    
    private var manager: IOHIDManager?
    private var managerRunLoop: CFRunLoop?
    private var keyBindingObserver: NSObjectProtocol?
    private var capsLockPreferenceObserver: NSObjectProtocol?
    private var lastPriTypeToggleEnabled: Bool?

    /// Whether the IOKit fallback currently owns keyboard monitoring.
    public var isRunning: Bool { manager != nil }
    
    /// Callback when toggle key is pressed
    public var onRightCommandToggle: (@Sendable (ToggleLatencyTrace) -> Void)?
    
    /// Track one modifier-only down/chord/release cycle.
    private var togglePressState = ReleaseTogglePressState()
    private var toggleTraceLifecycle = IOKitToggleTraceLifecycle()
    
    /// Track hanja key state
    private var hanjaKeyIsDown = false
    
    /// Debounce for Hanja trigger
    private var lastHanjaTriggerTime: DispatchTime = .init(uptimeNanoseconds: 0)
    
    /// Callback when hanja key is pressed
    public var onRightOptionHanja: (@Sendable () -> Void)?
    
    private init() {}
    
    // MARK: - HID Usage Mapping
    
    /// Map macOS virtual key code to HID usage
    static func hidUsage(for keyCode: Int64) -> UInt32? {
        switch keyCode {
        case 54: return 0xE7  // Right GUI (Command)
        case 55: return 0xE3  // Left GUI (Command)
        case 61: return 0xE6  // Right Alt (Option)
        case 58: return 0xE2  // Left Alt (Option)
        case 62: return 0xE4  // Right Control
        case 59: return 0xE0  // Left Control
        case 56: return 0xE1  // Left Shift
        case 60: return 0xE5  // Right Shift
        case 57: return 0x39  // Caps Lock
        default: return nil
        }
    }
    
    // MARK: - Accessibility Permission
    
    /// Check if Accessibility permission is granted
    public static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Request Accessibility permission (shows system dialog)
    public static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    // MARK: - Start/Stop
    
    /// Start monitoring keyboard events via IOHIDManager
    /// - Returns: `true` if successfully started, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        guard manager == nil else {
            refreshBindingLimitations()
            DebugLogger.event("toggle_backend.start_skipped", metadata: [
                .state("backend", "iokit"),
                .state("reason", "already_running")
            ])
            return true
        }

        guard ToggleMonitorStatusStore.shared.reserveStart(.iokit) else {
            DebugLogger.event("toggle_backend.start_skipped", metadata: [
                .state("backend", "iokit"),
                .state("reason", "backend_owned")
            ])
            return false
        }
        
        DebugLogger.event("toggle_backend.starting", metadata: [
            .state("backend", "iokit")
        ])
        
        // Create HID Manager
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hidManager
        
        // Match keyboard devices
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(hidManager, matchingDict as CFDictionary)
        
        // No input value matching - receive ALL keyboard events
        IOHIDManagerSetInputValueMatching(hidManager, nil)
        
        // Set input value callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, { context, result, sender, value in
            guard let context = context else { return }
            let manager = Unmanaged<IOKitManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleInputValue(value)
        }, context)
        
        // Schedule with current run loop (like Gureum)
        let currentRunLoop: CFRunLoop = CFRunLoopGetCurrent()
        managerRunLoop = currentRunLoop
        IOHIDManagerScheduleWithRunLoop(hidManager, currentRunLoop, CFRunLoopMode.defaultMode.rawValue)
        
        // Open manager
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            DebugLogger.event("toggle_backend.start_failed", metadata: [
                .state("backend", "iokit"),
                .statusCode("status_code", Int(result))
            ])
            if let managerRunLoop {
                IOHIDManagerUnscheduleFromRunLoop(hidManager, managerRunLoop, CFRunLoopMode.defaultMode.rawValue)
            }
            manager = nil
            managerRunLoop = nil
            ToggleMonitorStatusStore.shared.failStart(
                .iokit,
                issue: .iokitOpenFailed(Int32(result))
            )
            return false
        }

        resetKeyState()
        keyBindingObserver = NotificationCenter.default.addObserver(
            forName: .keyBindingChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshBindingLimitations()
        }
        capsLockPreferenceObserver = NotificationCenter.default.addObserver(
            forName: .capsLockInputSourceSwitchChanged,
            object: ConfigurationManager.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refreshBindingLimitations()
        }
        
        let config = ConfigurationManager.shared
        let priTypeToggleEnabled = !config.capsLockInputSourceSwitchEnabled
        lastPriTypeToggleEnabled = priTypeToggleEnabled
        ToggleMonitorStatusStore.shared.markRunning(
            .iokit,
            limitations: Self.bindingLimitations(
                toggleBinding: config.toggleKeyBinding,
                hanjaBinding: config.hanjaKeyBinding,
                priTypeToggleEnabled: priTypeToggleEnabled
            )
        )
        DebugLogger.event("toggle_backend.started", metadata: [
            .state("backend", "iokit")
        ])
        return true
    }
    
    /// Stop monitoring
    public func stop() {
        if let keyBindingObserver {
            NotificationCenter.default.removeObserver(keyBindingObserver)
            self.keyBindingObserver = nil
        }
        if let capsLockPreferenceObserver {
            NotificationCenter.default.removeObserver(capsLockPreferenceObserver)
            self.capsLockPreferenceObserver = nil
        }

        guard let hidManager = manager else {
            ToggleMonitorStatusStore.shared.markStopped(.iokit)
            return
        }
        
        if let managerRunLoop {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, managerRunLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        managerRunLoop = nil
        lastPriTypeToggleEnabled = nil
        resetKeyState()
        ToggleMonitorStatusStore.shared.markStopped(.iokit)
        
        DebugLogger.event("toggle_backend.stopped", metadata: [
            .state("backend", "iokit")
        ])
    }
    
    // MARK: - Input Handling
    
    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let pressed = intValue > 0
        
        // Only interested in keyboard page
        guard usagePage == kHIDPage_KeyboardOrKeypad else { return }

        if usage == 0x39, pressed {
            // Refresh after returning from the hardware callback. The cached
            // getter keeps every HID event free of CFPreferences work.
            DispatchQueue.main.async {
                ConfigurationManager.shared.refreshCapsLockInputSourceSwitchState()
            }
        }
        
        let config = ConfigurationManager.shared
        let toggleBinding = config.toggleKeyBinding
        let hanjaBinding = config.hanjaKeyBinding
        let priTypeToggleEnabled = !config.capsLockInputSourceSwitchEnabled
        if lastPriTypeToggleEnabled != priTypeToggleEnabled {
            lastPriTypeToggleEnabled = priTypeToggleEnabled
            resetKeyState()
            ToggleMonitorStatusStore.shared.updateLimitations(
                Self.bindingLimitations(
                    toggleBinding: toggleBinding,
                    hanjaBinding: hanjaBinding,
                    priTypeToggleEnabled: priTypeToggleEnabled
                ),
                for: .iokit
            )
        }
        if !priTypeToggleEnabled {
            resetTogglePressState()
        }
        
        // Get HID usages for configured keys
        let toggleUsage = Self.hidUsage(for: toggleBinding.keyCode)
        let hanjaUsage = Self.hidUsage(for: hanjaBinding.keyCode)

        // Check for toggle key (only for modifier-only bindings)
        let toggleRoute = ShortcutBindingRouter.routeModifierKey(
            keyCode: toggleBinding.keyCode,
            toggleBinding: toggleBinding,
            hanjaBinding: hanjaBinding,
            priTypeToggleEnabled: priTypeToggleEnabled
        )
        if toggleRoute == .toggle, let expectedUsage = toggleUsage {
            switch togglePressState.handle(usage: usage, pressed: pressed, toggleUsage: expectedUsage) {
            case .pressed:
                toggleTraceLifecycle.begin()
                DebugLogger.event("toggle.physical_down", metadata: [
                    .state("backend", "iokit")
                ])
            case .repeatIgnored:
                DebugLogger.event("toggle.ignored", metadata: [
                    .state("source", "iokit"),
                    .state("reason", "repeat")
                ])
            case .chorded:
                toggleTraceLifecycle.cancel()
                DebugLogger.event("toggle.chord_detected", metadata: [
                    .state("backend", "iokit")
                ])
            case .released(shouldToggle: true):
                guard let trace = toggleTraceLifecycle.finish() else {
                    DebugLogger.event("toggle.ignored", metadata: [
                        .state("source", "iokit"),
                        .state("reason", "missing_trace")
                    ])
                    break
                }
                DebugLogger.event("toggle.requested", metadata: [
                    .state("backend", "iokit")
                ])
                let callback = onRightCommandToggle
                DispatchQueue.main.async {
                    callback?(trace)
                }
            case .released(shouldToggle: false):
                toggleTraceLifecycle.cancel()
                DebugLogger.event("toggle.ignored", metadata: [
                    .state("source", "iokit"),
                    .state("reason", "used_as_modifier")
                ])
            case .none:
                break
            }
        } else {
            resetTogglePressState()
        }

        let hanjaRoute = ShortcutBindingRouter.routeModifierKey(
            keyCode: hanjaBinding.keyCode,
            toggleBinding: toggleBinding,
            hanjaBinding: hanjaBinding,
            priTypeToggleEnabled: priTypeToggleEnabled
        )
        if hanjaRoute == .hanja,
           let expectedUsage = hanjaUsage, usage == expectedUsage {
            // Hanja key
            if pressed && !hanjaKeyIsDown {
                hanjaKeyIsDown = true
                
                // Debounce: ignore if last trigger was within 500ms
                let now = DispatchTime.now()
                let elapsed = now.uptimeNanoseconds - lastHanjaTriggerTime.uptimeNanoseconds
                let elapsedMs = elapsed / 1_000_000
                if elapsedMs < 500 {
                    DebugLogger.event("hanja.request_debounced", metadata: [
                        .state("backend", "iokit"),
                        .durationMicroseconds("elapsed", elapsed / 1_000)
                    ])
                    return
                }
                lastHanjaTriggerTime = now
                
                DebugLogger.event("hanja.requested", metadata: [
                    .state("backend", "iokit")
                ])
                let callback = onRightOptionHanja
                DispatchQueue.main.async {
                    callback?()
                }
            } else if !pressed && hanjaKeyIsDown {
                hanjaKeyIsDown = false
                DebugLogger.event("hanja.physical_up", metadata: [
                    .state("backend", "iokit")
                ])
            }
        }
    }

    static func bindingLimitations(
        toggleBinding: KeyBinding,
        hanjaBinding: KeyBinding,
        priTypeToggleEnabled: Bool
    ) -> [ToggleMonitorIssue] {
        var limitations: [ToggleMonitorIssue] = []

        if priTypeToggleEnabled,
           (!toggleBinding.isModifierOnly || hidUsage(for: toggleBinding.keyCode) == nil) {
            limitations.append(.unsupportedIOKitToggleBinding(toggleBinding.displayName))
        }

        if hanjaBinding != toggleBinding,
           (!hanjaBinding.isModifierOnly || hidUsage(for: hanjaBinding.keyCode) == nil) {
            limitations.append(.unsupportedIOKitHanjaBinding(hanjaBinding.displayName))
        }

        return limitations
    }

    private func refreshBindingLimitations() {
        guard manager != nil else { return }
        resetKeyState()
        let config = ConfigurationManager.shared
        let priTypeToggleEnabled = !config.capsLockInputSourceSwitchEnabled
        lastPriTypeToggleEnabled = priTypeToggleEnabled
        ToggleMonitorStatusStore.shared.updateLimitations(
            Self.bindingLimitations(
                toggleBinding: config.toggleKeyBinding,
                hanjaBinding: config.hanjaKeyBinding,
                priTypeToggleEnabled: priTypeToggleEnabled
            ),
            for: .iokit
        )
    }

    private func resetKeyState() {
        resetTogglePressState()
        hanjaKeyIsDown = false
    }

    private func resetTogglePressState() {
        togglePressState.reset()
        toggleTraceLifecycle.cancel()
    }
}
