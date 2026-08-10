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
    private var lastPriTypeToggleEnabled: Bool?

    /// Whether the IOKit fallback currently owns keyboard monitoring.
    public var isRunning: Bool { manager != nil }
    
    /// Callback when toggle key is pressed
    public var onRightCommandToggle: (@Sendable () -> Void)?
    
    /// Track one modifier-only down/chord/release cycle.
    private var togglePressState = ReleaseTogglePressState()
    
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
            DebugLogger.log("IOKitManager: Already running")
            return true
        }

        guard ToggleMonitorStatusStore.shared.reserveStart(.iokit) else {
            DebugLogger.log("IOKitManager: Start blocked because another backend owns monitoring")
            return false
        }
        
        DebugLogger.log("IOKitManager: Starting IOKit-only toggle detection...")
        
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
            DebugLogger.log("IOKitManager: Failed to open IOHIDManager: \(result)")
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
        DebugLogger.log("IOKitManager: Started successfully (toggle=\(config.toggleKeyBinding.displayName), hanja=\(config.hanjaKeyBinding.displayName))")
        return true
    }
    
    /// Stop monitoring
    public func stop() {
        if let keyBindingObserver {
            NotificationCenter.default.removeObserver(keyBindingObserver)
            self.keyBindingObserver = nil
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
        
        DebugLogger.log("IOKitManager: Stopped")
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
        
        // Log events for debugging (limit to modifiers to reduce noise)
        if usage >= 0xE0 && usage <= 0xE7 {
            DebugLogger.log("IOKitManager: Modifier key 0x\(String(usage, radix: 16)) \(pressed ? "DOWN" : "UP")")
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
            togglePressState.reset()
        }
        
        // Get HID usages for configured keys
        let toggleUsage = Self.hidUsage(for: toggleBinding.keyCode)
        let hanjaUsage = Self.hidUsage(for: hanjaBinding.keyCode)

        // Check for toggle key (only for modifier-only bindings)
        if priTypeToggleEnabled && toggleBinding.isModifierOnly, let expectedUsage = toggleUsage {
            switch togglePressState.handle(usage: usage, pressed: pressed, toggleUsage: expectedUsage) {
            case .pressed:
                DebugLogger.log("IOKitManager: Toggle key DOWN (\(toggleBinding.displayName))")
            case .repeatIgnored:
                DebugLogger.log("IOKitManager: Repeated toggle DOWN ignored")
            case .chorded:
                DebugLogger.log("IOKitManager: Another physical key pressed while toggle key is down")
            case .released(shouldToggle: true):
                DebugLogger.log("IOKitManager: TOGGLE triggered! (\(toggleBinding.displayName))")
                let callback = onRightCommandToggle
                DispatchQueue.main.async {
                    callback?()
                }
            case .released(shouldToggle: false):
                DebugLogger.log("IOKitManager: Toggle skipped (used with other key)")
            case .none:
                break
            }
        } else {
            togglePressState.reset()
        }

        if hanjaBinding.isModifierOnly,
           let expectedUsage = hanjaUsage, usage == expectedUsage,
           hanjaBinding.keyCode != toggleBinding.keyCode {
            // Hanja key (only if different from toggle key)
            if pressed && !hanjaKeyIsDown {
                hanjaKeyIsDown = true
                
                // Debounce: ignore if last trigger was within 500ms
                let now = DispatchTime.now()
                let elapsed = now.uptimeNanoseconds - lastHanjaTriggerTime.uptimeNanoseconds
                let elapsedMs = elapsed / 1_000_000
                if elapsedMs < 500 {
                    DebugLogger.log("IOKitManager: Hanja key DEBOUNCED (\(elapsedMs)ms)")
                    return
                }
                lastHanjaTriggerTime = now
                
                DebugLogger.log("IOKitManager: Hanja key DOWN (\(hanjaBinding.displayName)) - HANJA")
                let callback = onRightOptionHanja
                DispatchQueue.main.async {
                    callback?()
                }
            } else if !pressed && hanjaKeyIsDown {
                hanjaKeyIsDown = false
                DebugLogger.log("IOKitManager: Hanja key UP (\(hanjaBinding.displayName))")
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
        togglePressState.reset()
        hanjaKeyIsDown = false
    }
}
