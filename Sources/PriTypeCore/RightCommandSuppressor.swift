import Foundation
import Cocoa
import ApplicationServices

/// Primary toggle key handler using CGEventTap.
///
/// ## Role
/// Intercepts user-configured toggle and hanja key events at the system level
/// using CGEventTap to provide instant language mode switching.
///
/// ## Dynamic Key Binding
/// Instead of hardcoded keys, this class reads `ConfigurationManager.toggleKeyBinding`
/// and `ConfigurationManager.hanjaKeyBinding` to determine which keys to intercept.
/// Users can configure any modifier key or key combination via the Settings UI.
///
/// ## Relationship with IOKitManager
/// - **Primary handler**: `RightCommandSuppressor` (this class)
/// - **Backup handler**: `IOKitManager`
///
/// This class uses `IOKitManager.hasAccessibilityPermission()` to check permissions.
/// If CGEventTap creation fails (e.g., permission issues), `IOKitManager` takes over.
///
/// ## Key Features
/// - **Instant toggle**: Switches on key press, not release
/// - **Modifier stripping**: When toggle modifier is held, removes its modifier from other keys
/// - **Dynamic binding**: Supports any key via KeyBinding struct
public final class RightCommandSuppressor: @unchecked Sendable {
    
    // Singleton - accessed from CGEventTap callback context
    public static let shared = RightCommandSuppressor()

    static let monitoredEventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    
    /// Whether the event tap is currently running
    public var isRunning: Bool { eventTap != nil }
    
    /// Callback for toggle
    public var onToggle: (@Sendable (ToggleLatencyTrace) -> Void)?
    
    /// Callback for Hanja lookup
    public var onHanjaLookup: (@Sendable () -> Void)?
    
    /// Track the exact side/keyCode and suppressed down/up pairs.
    private var modifierKeyState = ModifierKeyPressState()
    private var regularKeyState = RegularKeyPressState()
    private var suppressedToggleModifierKeyCode: Int64?
    private var suppressedHanjaModifierKeyCode: Int64?
    
    /// Debounce timer for Hanja trigger to prevent double-fire
    private var lastHanjaTriggerTime: DispatchTime = .init(uptimeNanoseconds: 0)

    /// Track CGEventTap disable events for auto-recovery
    private var tapDisableTracker = TapDisableTracker()
    private var permanentlyHandedOff = false
    
    /// Callback for when CGEventTap permanently fails and IOKit should take over
    public var onTapFailed: (@Sendable () -> Void)?
    
    /// Whether recording mode is active (for Key Recorder in settings)
    public var isRecordingKey = false
    
    /// Callback for key recording (settings UI)
    public var onKeyRecorded: ((_ keyCode: Int64, _ modifiers: UInt64) -> Void)?
    
    private init() {}
    
    // MARK: - Start/Stop
    
    /// Start monitoring toggle keys
    /// - Returns: `true` if CGEventTap was created successfully, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil else {
            DebugLogger.event("toggle_backend.start_skipped", metadata: [
                .state("backend", "event_tap"),
                .state("reason", "already_running")
            ])
            return true
        }
        guard !permanentlyHandedOff else {
            DebugLogger.event("toggle_backend.start_skipped", metadata: [
                .state("backend", "event_tap"),
                .state("reason", "permanent_handoff")
            ])
            return false
        }

        guard ToggleMonitorStatusStore.shared.reserveStart(.eventTap) else {
            DebugLogger.event("toggle_backend.start_skipped", metadata: [
                .state("backend", "event_tap"),
                .state("reason", "backend_owned")
            ])
            return false
        }
        
        guard IOKitManager.hasAccessibilityPermission() else {
            DebugLogger.event("toggle_backend.start_failed", metadata: [
                .state("backend", "event_tap"),
                .state("reason", "accessibility_permission")
            ])
            ToggleMonitorStatusStore.shared.failStart(.eventTap, issue: .accessibilityPermissionRequired)
            return false
        }
        
        // Observe keyUp too, so every suppressed regular/combo down has a
        // matching suppressed release and the host never receives an orphan up.
        // Create event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.monitoredEventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let suppressor = Unmanaged<RightCommandSuppressor>.fromOpaque(refcon).takeUnretainedValue()
                return suppressor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            DebugLogger.event("toggle_backend.start_failed", metadata: [
                .state("backend", "event_tap"),
                .state("reason", "tap_creation")
            ])
            permanentlyHandedOff = true
            _ = ToggleMonitorStatusStore.shared.beginEventTapHandoff()
            return false
        }
        
        // Add to run loop
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            DebugLogger.event("toggle_backend.start_failed", metadata: [
                .state("backend", "event_tap"),
                .state("reason", "run_loop_source")
            ])
            permanentlyHandedOff = true
            tearDownEventTap()
            _ = ToggleMonitorStatusStore.shared.beginEventTapHandoff()
            return false
        }
        let currentRunLoop: CFRunLoop = CFRunLoopGetCurrent()
        runLoopSource = source
        eventTapRunLoop = currentRunLoop
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        resetKeyState()
        tapDisableTracker.reset()
        ToggleMonitorStatusStore.shared.markRunning(.eventTap)
        
        DebugLogger.event("toggle_backend.started", metadata: [
            .state("backend", "event_tap")
        ])
        return true
    }
    
    /// Stop monitoring
    public func stop() {
        tearDownEventTap()
        permanentlyHandedOff = false
        tapDisableTracker.reset()
        resetKeyState()
        ToggleMonitorStatusStore.shared.markStopped(.eventTap)
        DebugLogger.event("toggle_backend.stopped", metadata: [
            .state("backend", "event_tap")
        ])
    }
    
    // MARK: - Event Handling
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable transient failures, but permanently tear down the tap
        // before notifying the IOKit fallback after the third failure.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            switch tapDisableTracker.recordDisable(at: ProcessInfo.processInfo.systemUptime) {
            case .handoff:
                DebugLogger.event("toggle_backend.degraded", metadata: [
                    .state("from", "event_tap"),
                    .state("to", "iokit"),
                    .count("disable_count", tapDisableTracker.maximumRetryCount)
                ])
                permanentlyHandedOff = true
                tearDownEventTap()
                resetKeyState()

                guard ToggleMonitorStatusStore.shared.beginEventTapHandoff() else {
                    return Unmanaged.passUnretained(event)
                }
                let callback = onTapFailed
                DispatchQueue.main.async {
                    callback?()
                }
            case .reenable(let attempt):
                DebugLogger.event("toggle_backend.recovering", metadata: [
                    .state("backend", "event_tap"),
                    .count("disable_count", attempt)
                ])
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            case .ignore:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let config = ConfigurationManager.shared
        let toggleBinding = config.toggleKeyBinding
        let hanjaBinding = config.hanjaKeyBinding
        let priTypeToggleEnabled = !config.capsLockInputSourceSwitchEnabled

        if type == .keyUp, regularKeyState.keyUp(keyCode: keyCode) == .suppress {
            DebugLogger.event("input.suppressed_key_up")
            return nil
        }

        if type == .flagsChanged {
            // Caps Lock is a lock-state edge rather than a down/up pair. Keep
            // the existing TIS ownership behavior and avoid polluting the
            // physical modifier pressed set with its latched state.
            if keyCode == 57 {
                // This low-frequency edge is also an ownership refresh
                // boundary. Defer preference I/O until after the event-tap
                // callback returns so key delivery is never delayed.
                DispatchQueue.main.async {
                    ConfigurationManager.shared.refreshCapsLockInputSourceSwitchState()
                }
                if isRecordingKey {
                    let recordCallback = onKeyRecorded
                    DispatchQueue.main.async {
                        recordCallback?(keyCode, 0)
                    }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            let modifierMask = Self.modifierMask(for: keyCode)
            let maskIsSet = modifierMask.rawValue != 0 && event.flags.contains(modifierMask)
            let transition = modifierKeyState.observe(keyCode: keyCode, aggregateMaskIsSet: maskIsSet)

            if transition == .up, modifierKeyState.consumeSuppressedRelease(keyCode: keyCode) {
                if suppressedToggleModifierKeyCode == keyCode {
                    suppressedToggleModifierKeyCode = nil
                    DebugLogger.event("toggle.physical_up", metadata: [
                        .state("backend", "event_tap")
                    ])
                }
                if suppressedHanjaModifierKeyCode == keyCode {
                    suppressedHanjaModifierKeyCode = nil
                    DebugLogger.event("hanja.physical_up", metadata: [
                        .state("backend", "event_tap")
                    ])
                }
                return nil
            }

            // Key recording mode — capture only a physical down transition.
            if isRecordingKey, transition == .down {
                modifierKeyState.suppressUntilRelease(keyCode: keyCode)
                let recordCallback = onKeyRecorded
                DispatchQueue.main.async {
                    recordCallback?(keyCode, 0)
                }
                return nil
            }

            if transition == .down,
               priTypeToggleEnabled,
               toggleBinding.isModifierKey,
               toggleBinding.isModifierOnly,
               keyCode == toggleBinding.keyCode {
                suppressedToggleModifierKeyCode = keyCode
                modifierKeyState.suppressUntilRelease(keyCode: keyCode)
                DebugLogger.event("toggle.requested", metadata: [
                    .state("backend", "event_tap")
                ])
                triggerToggle()
                return nil
            }

            if transition == .down,
               hanjaBinding.isModifierKey,
               hanjaBinding.isModifierOnly,
               keyCode == hanjaBinding.keyCode,
               keyCode != toggleBinding.keyCode {
                suppressedHanjaModifierKeyCode = keyCode
                modifierKeyState.suppressUntilRelease(keyCode: keyCode)

                let now = DispatchTime.now()
                let elapsed = now.uptimeNanoseconds - lastHanjaTriggerTime.uptimeNanoseconds
                let elapsedMs = elapsed / 1_000_000
                if elapsedMs < 500 {
                    DebugLogger.event("hanja.request_debounced", metadata: [
                        .state("backend", "event_tap"),
                        .durationMicroseconds("elapsed", elapsed / 1_000)
                    ])
                    return nil
                }
                lastHanjaTriggerTime = now

                DebugLogger.event("hanja.requested", metadata: [
                    .state("backend", "event_tap")
                ])
                triggerHanjaLookup()
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        if isRecordingKey {
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let action = regularKeyState.keyDown(
                    keyCode: keyCode,
                    isRepeat: isRepeat,
                    matchesBinding: true
                )
                guard action == .triggerAndSuppress else { return nil }

                let modifiers = event.flags.rawValue & 0xFFFF0000  // Keep only modifier flags
                let recordCallback = onKeyRecorded
                DispatchQueue.main.async {
                    recordCallback?(keyCode, modifiers)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let toggleMatches = priTypeToggleEnabled
                && keyCode == toggleBinding.keyCode
                && !toggleBinding.isModifierKey
                && (toggleBinding.isModifierOnly || Self.hasRequiredModifiers(
                    flags: event.flags,
                    required: CGEventFlags(rawValue: toggleBinding.modifiers)
                ))

            switch regularKeyState.keyDown(
                keyCode: keyCode,
                isRepeat: isRepeat,
                matchesBinding: toggleMatches
            ) {
            case .triggerAndSuppress:
                DebugLogger.event("toggle.requested", metadata: [
                    .state("backend", "event_tap")
                ])
                triggerToggle()
                return nil
            case .suppress:
                return nil
            case .passThrough:
                break
            }

            let hanjaMatches = keyCode == hanjaBinding.keyCode
                && !hanjaBinding.isModifierKey
                && keyCode != toggleBinding.keyCode
                && (hanjaBinding.isModifierOnly || Self.hasRequiredModifiers(
                    flags: event.flags,
                    required: CGEventFlags(rawValue: hanjaBinding.modifiers)
                ))

            switch regularKeyState.keyDown(
                keyCode: keyCode,
                isRepeat: isRepeat,
                matchesBinding: hanjaMatches
            ) {
            case .triggerAndSuppress:
                DebugLogger.event("hanja.requested", metadata: [
                    .state("backend", "event_tap")
                ])
                triggerHanjaLookup()
                return nil
            case .suppress:
                return nil
            case .passThrough:
                break
            }
        }

        // When the suppressed toggle modifier is held, strip only its modifier
        // family unless the opposite-side modifier in that family is also down.
        if type == .keyDown || type == .keyUp,
           let toggleKeyCode = suppressedToggleModifierKeyCode {
            let modifierMask = Self.modifierMask(for: toggleKeyCode)
            let siblingKeyCodes = Self.modifierFamilyKeyCodes(for: toggleKeyCode)
            if !modifierKeyState.hasPressedSibling(of: toggleKeyCode, sharingKeyCodes: siblingKeyCodes) {
                var newFlags = event.flags
                newFlags.remove(modifierMask)
                event.flags = newFlags
                DebugLogger.event("input.toggle_modifier_stripped")
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    // MARK: - Helpers
    
    /// Get the CGEventFlags modifier mask for a given keyCode
    private static func modifierMask(for keyCode: Int64) -> CGEventFlags {
        switch keyCode {
        case 54, 55: return .maskCommand       // Right/Left Command
        case 61, 58: return .maskAlternate      // Right/Left Option
        case 62, 59: return .maskControl        // Right/Left Control
        case 56, 60: return .maskShift          // Left/Right Shift
        case 57:     return .maskAlphaShift     // Caps Lock
        default:     return CGEventFlags(rawValue: 0)
        }
    }

    private static func modifierFamilyKeyCodes(for keyCode: Int64) -> Set<Int64> {
        switch keyCode {
        case 54, 55: return [54, 55]
        case 61, 58: return [61, 58]
        case 62, 59: return [62, 59]
        case 56, 60: return [56, 60]
        case 57: return [57]
        default: return []
        }
    }
    
    /// Check if event flags contain required modifier flags
    private static func hasRequiredModifiers(flags: CGEventFlags, required: CGEventFlags) -> Bool {
        return flags.intersection(required) == required
    }

    private func tearDownEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource, let eventTapRunLoop {
            CFRunLoopRemoveSource(eventTapRunLoop, runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        eventTapRunLoop = nil
    }

    private func resetKeyState() {
        modifierKeyState.reset()
        regularKeyState.reset()
        suppressedToggleModifierKeyCode = nil
        suppressedHanjaModifierKeyCode = nil
    }

    private func triggerToggle() {
        let callback = onToggle
        let trace = ToggleLatencyTrace.begin(source: .customKey)
        // Hop to the main run loop and let the toggle settle there. This matches
        // the proven v2.6.5 baseline: first-key stability comes from the single
        // internal state machine (`HangulComposer.inputMode` with no async TIS
        // source selection), NOT from running the toggle synchronously inside the
        // CGEventTap callback. Keeping IMK commit / keyboard-override work off the
        // tap callback also protects against `kCGEventTapDisabledByTimeout`.
        DispatchQueue.main.async {
            callback?(trace)
        }
    }
    
    private func triggerHanjaLookup() {
        let callback = onHanjaLookup
        DispatchQueue.main.async {
            callback?()
        }
    }
}
