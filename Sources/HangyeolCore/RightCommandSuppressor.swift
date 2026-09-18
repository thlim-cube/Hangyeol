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
/// - **Chord-safe modifier toggle**: Modifier-only keys toggle on physical down;
///   the opposite Command rolls the change back for the host screenshot shortcut
/// - **Pair-safe suppression**: Suppressed bindings never leak an orphan down/up edge
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
    public var onToggle: (@Sendable (ToggleLatencyTrace, TimeInterval?) -> Void)?
    
    /// Callback for Hanja lookup
    public var onHanjaLookup: (@Sendable () -> Void)?
    
    /// Track the exact side/keyCode and suppressed down/up pairs.
    private var modifierKeyState = ModifierKeyPressState()
    private var modifierToggleState = EventTapModifierToggleState()
    private var regularKeyState = RegularKeyPressState()
    private var keyBindingRecorderState = KeyBindingRecorderState()
    private var suppressedHanjaModifierKeyCode: Int64?
    
    /// Track CGEventTap disable events for auto-recovery
    private var tapDisableTracker = TapDisableTracker()
    private var permanentlyHandedOff = false
    
    /// Callback for when CGEventTap permanently fails and IOKit should take over
    public var onTapFailed: (@Sendable () -> Void)?
    
    /// Whether recording mode is active (for Key Recorder in settings)
    public var isRecordingKey = false
    
    /// Callback for key recording (settings UI)
    public var onKeyRecorded: ((_ keyCode: Int64, _ modifiers: UInt64) -> Void)?

    func beginKeyRecording(
        onRecorded: ((_ keyCode: Int64, _ modifiers: UInt64) -> Void)?
    ) {
        keyBindingRecorderState.reset()
        onKeyRecorded = onRecorded
        isRecordingKey = true
    }

    func endKeyRecording() {
        isRecordingKey = false
        onKeyRecorded = nil
        keyBindingRecorderState.reset()
    }
    
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

        // Resolve persisted bindings on the start caller before the event tap
        // can deliver its first callback. Hot-path getters are memory-only after this.
        ConfigurationManager.shared.prewarmKeyBindingCache()
        
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
        resynchronizeKeyState()
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
                    resynchronizeKeyState()
                }
            case .ignore:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        // Deferred Chromium host keys belong to the host even when the same key is
        // configured as a custom Hangyeol shortcut.
        if DeferredHostKeyDelivery.isReplayedHostKey(event) {
            if type == .keyDown {
                PhysicalKeyDelivery.shared.record(event, isHostReplay: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Settings records shortcuts with an app-local monitor. Let the complete
        // chord reach that monitor instead of triggering or suppressing the
        // currently configured shortcut before it can be replaced.
        if isRecordingKey, onKeyRecorded == nil {
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let config = ConfigurationManager.shared
        let toggleBinding = config.toggleKeyBinding
        let hanjaBinding = config.hanjaKeyBinding
        let hangyeolToggleEnabled = !config.capsLockInputSourceSwitchEnabled
        let usesPassThroughModifierToggle = !isRecordingKey
            && hangyeolToggleEnabled
            && toggleBinding.isModifierOnly
            && ShortcutBindingRouter.routeModifierKey(
                keyCode: toggleBinding.keyCode,
                toggleBinding: toggleBinding,
                hanjaBinding: hanjaBinding,
                hangyeolToggleEnabled: hangyeolToggleEnabled
            ) == .toggle
        if !usesPassThroughModifierToggle {
            modifierToggleState.reset()
        }

        if usesPassThroughModifierToggle,
           (type == .keyDown || type == .keyUp) {
            _ = modifierToggleState.handle(
                keyCode: keyCode,
                pressed: type == .keyDown,
                toggleKeyCode: toggleBinding.keyCode,
                inputKind: .regular
            )
        }

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
                sanitizeModifierFlagsForHost(event)
                return Unmanaged.passUnretained(event)
            }

            let physicalKeyIsDown = Self.modifierKeyIsDown(
                keyCode: keyCode,
                eventFlags: event.flags
            )
            let modifierToggleAction = usesPassThroughModifierToggle
                ? modifierToggleState.handle(
                    keyCode: keyCode,
                    pressed: physicalKeyIsDown,
                    toggleKeyCode: toggleBinding.keyCode,
                    inputKind: .modifier
                )
                : .passThrough
            let transition = modifierKeyState.observe(
                keyCode: keyCode,
                physicalKeyIsDown: physicalKeyIsDown
            )

            if isRecordingKey, let recordCallback = onKeyRecorded {
                let decision = keyBindingRecorderState.handleModifier(
                    keyCode: keyCode,
                    isDown: physicalKeyIsDown
                )
                switch decision {
                case .pending:
                    if transition == .down {
                        modifierKeyState.suppressUntilRelease(keyCode: keyCode)
                    } else if transition == .up {
                        _ = modifierKeyState.consumeSuppressedRelease(keyCode: keyCode)
                    }
                    return nil
                case .ignored:
                    return Unmanaged.passUnretained(event)
                case .recorded(let binding):
                    if transition == .up {
                        _ = modifierKeyState.consumeSuppressedRelease(keyCode: keyCode)
                    }
                    DispatchQueue.main.async {
                        recordCallback(binding.keyCode, binding.modifiers)
                    }
                    return nil
                case .cancelled:
                    return nil
                case .capsLockBlocked:
                    DispatchQueue.main.async {
                        recordCallback(keyCode, 0)
                    }
                    return nil
                }
            }

            if transition == .up, modifierKeyState.consumeSuppressedRelease(keyCode: keyCode) {
                if suppressedHanjaModifierKeyCode == keyCode {
                    suppressedHanjaModifierKeyCode = nil
                    DebugLogger.event("hanja.physical_up", metadata: [
                        .state("backend", "event_tap")
                    ])
                }
                return nil
            }

            let route = transition == .down ? ShortcutBindingRouter.routeModifierKey(
                keyCode: keyCode,
                toggleBinding: toggleBinding,
                hanjaBinding: hanjaBinding,
                hangyeolToggleEnabled: hangyeolToggleEnabled
            ) : nil

            if modifierToggleAction == .toggleAndPassThrough {
                DebugLogger.event("toggle.requested", metadata: [
                    .state("backend", "event_tap")
                ])
                triggerToggle(eventTimestamp: Double(event.timestamp) / 1_000_000_000)
            }

            if route == .hanja,
               HanjaShortcutSuppressionPolicy.allowsSuppression(
                   binding: hanjaBinding,
                   sessionState: HanjaShortcutSessionStateStore.shared.state
               ) {
                suppressedHanjaModifierKeyCode = keyCode
                modifierKeyState.suppressUntilRelease(keyCode: keyCode)

                DebugLogger.event("hanja.requested", metadata: [
                    .state("backend", "event_tap")
                ])
                triggerHanjaLookup()
                return nil
            }

            sanitizeModifierFlagsForHost(event)
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

                let decision = keyBindingRecorderState.handleKeyDown(
                    keyCode: keyCode,
                    modifiers: event.flags.rawValue
                )
                let recordCallback = onKeyRecorded
                switch decision {
                case .recorded(let binding):
                    DispatchQueue.main.async {
                        recordCallback?(binding.keyCode, binding.modifiers)
                    }
                case .cancelled:
                    DispatchQueue.main.async {
                        recordCallback?(keyCode, 0)
                    }
                case .pending, .ignored, .capsLockBlocked:
                    break
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // A modifier release and the next key can cross an input-source handoff.
        // Rebuild tracked modifier families from physical flagsChanged state so a
        // stale Command bit cannot turn the first typed key into a host shortcut.
        let hiddenTypingToggleKeyCode = type == .keyDown || type == .keyUp
            ? modifierToggleState.activeStandaloneToggleKeyCode
            : nil
        sanitizeModifierFlagsForHost(
            event,
            additionallyHiding: hiddenTypingToggleKeyCode,
            normalizingModifierKeyCode: usesPassThroughModifierToggle
                ? toggleBinding.keyCode
                : nil
        )

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let route = ShortcutBindingRouter.routeRegularKey(
                keyCode: keyCode,
                modifiers: event.flags.rawValue,
                toggleBinding: toggleBinding,
                hanjaBinding: hanjaBinding,
                hangyeolToggleEnabled: hangyeolToggleEnabled
            )
            let suppressionAllowed = route != .hanja || HanjaShortcutSuppressionPolicy.allowsSuppression(
                binding: hanjaBinding,
                sessionState: HanjaShortcutSessionStateStore.shared.state
            )

            switch regularKeyState.keyDown(
                keyCode: keyCode,
                isRepeat: isRepeat,
                matchesBinding: route != nil,
                suppressionAllowed: suppressionAllowed
            ) {
            case .triggerAndSuppress:
                switch route {
                case .toggle:
                    DebugLogger.event("toggle.requested", metadata: [
                        .state("backend", "event_tap")
                    ])
                    triggerToggle()
                    return nil
                case .hanja:
                    DebugLogger.event("hanja.requested", metadata: [
                        .state("backend", "event_tap")
                    ])
                    triggerHanjaLookup()
                    return nil
                case nil:
                    return Unmanaged.passUnretained(event)
                }
            case .suppress:
                return nil
            case .passThrough:
                break
            }
        }

        if type == .keyDown {
            PhysicalKeyDelivery.shared.record(event)
        }
        return Unmanaged.passUnretained(event)
    }
    
    // MARK: - Helpers
    
    private func sanitizeModifierFlagsForHost(
        _ event: CGEvent,
        additionallyHiding hiddenKeyCode: Int64? = nil,
        normalizingModifierKeyCode: Int64? = nil
    ) {
        let sanitized = Self.hostVisibleModifierFlagsForTypingEvent(
            event.flags,
            pressedKeyCodes: modifierKeyState.hostVisiblePressedKeyCodes,
            hasSuppressedKeyCodes: modifierKeyState.hasSuppressedKeyCodes,
            additionallyHiding: hiddenKeyCode,
            normalizingModifierKeyCode: normalizingModifierKeyCode,
            // Hardware events use PID 0. Quartz-posted events retain their
            // source process, so their modifiers belong to the host shortcut.
            preservesSynthesizedModifiers: event.getIntegerValueField(
                .eventSourceUnixProcessID
            ) > 0
        )
        guard sanitized != event.flags else { return }
        event.flags = sanitized
        DebugLogger.event("input.suppressed_modifier_stripped")
    }

    static func hostVisibleModifierFlagsForTypingEvent(
        _ flags: CGEventFlags,
        pressedKeyCodes: Set<Int64>,
        hasSuppressedKeyCodes: Bool,
        additionallyHiding hiddenKeyCode: Int64?,
        normalizingModifierKeyCode: Int64?,
        preservesSynthesizedModifiers: Bool = false
    ) -> CGEventFlags {
        // Posted host shortcuts keep their modifiers even while a physical
        // toggle or suppressed modifier is being hidden from the host.
        if preservesSynthesizedModifiers {
            return flags
        }

        if hasSuppressedKeyCodes || hiddenKeyCode != nil {
            var hostVisibleKeyCodes = pressedKeyCodes
            if let hiddenKeyCode {
                hostVisibleKeyCodes.remove(hiddenKeyCode)
            }
            return hostVisibleModifierFlags(
                flags,
                pressedKeyCodes: hostVisibleKeyCodes
            )
        }

        guard let normalizingModifierKeyCode else { return flags }
        let familyKeyCodes = modifierFamilyKeyCodes(for: normalizingModifierKeyCode)
        guard !familyKeyCodes.isEmpty else { return flags }

        let familyRawMask = familyKeyCodes.reduce(UInt64(0)) {
            $0 | (modifierFlagBitsByKeyCode[$1] ?? 0)
        } | modifierMask(for: normalizingModifierKeyCode).rawValue
        var rawValue = flags.rawValue & ~familyRawMask
        // The incoming typing event can omit an aggregate modifier bit at the
        // handoff boundary. Restore every physically observed modifier while
        // still clearing stale bits only from the configured toggle family.
        for keyCode in pressedKeyCodes where trackedModifierKeyCodes.contains(keyCode) {
            rawValue |= modifierFlagBitsByKeyCode[keyCode] ?? 0
            rawValue |= modifierMask(for: keyCode).rawValue
        }
        return CGEventFlags(rawValue: rawValue)
    }

    static func hostVisibleModifierFlags(
        _ flags: CGEventFlags,
        pressedKeyCodes: Set<Int64>
    ) -> CGEventFlags {
        let trackedRawMask = modifierFlagBitsByKeyCode.values.reduce(UInt64(0), |)
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskShift.rawValue
        var rawValue = flags.rawValue & ~trackedRawMask

        for keyCode in pressedKeyCodes {
            rawValue |= modifierFlagBitsByKeyCode[keyCode] ?? 0
            rawValue |= modifierMask(for: keyCode).rawValue
        }
        return CGEventFlags(rawValue: rawValue)
    }

    private static let modifierFlagBitsByKeyCode: [Int64: UInt64] = [
        55: UInt64(NX_DEVICELCMDKEYMASK),
        54: UInt64(NX_DEVICERCMDKEYMASK),
        58: UInt64(NX_DEVICELALTKEYMASK),
        61: UInt64(NX_DEVICERALTKEYMASK),
        59: UInt64(NX_DEVICELCTLKEYMASK),
        62: UInt64(NX_DEVICERCTLKEYMASK),
        56: UInt64(NX_DEVICELSHIFTKEYMASK),
        60: UInt64(NX_DEVICERSHIFTKEYMASK)
    ]

    /// Get the CGEventFlags modifier mask for a given keyCode.
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
        case 58, 61: return [58, 61]
        case 59, 62: return [59, 62]
        case 56, 60: return [56, 60]
        default: return []
        }
    }

    static let trackedModifierKeyCodes: Set<Int64> = [54, 55, 61, 58, 62, 59, 56, 60]

    /// A `flagsChanged` event already carries the side-specific modifier state.
    /// Reading `CGEventSource.keyState` again inside the callback is unreliable for
    /// some external keyboards and HID remaps, where it can still report the old state.
    static func modifierKeyIsDown(keyCode: Int64, eventFlags: CGEventFlags) -> Bool {
        guard let sideFlag = modifierFlagBitsByKeyCode[keyCode] else { return false }
        return eventFlags.rawValue & sideFlag != 0
    }

    /// Local NSEvent monitors can omit side-specific NX flags. Prefer exact
    /// side state when present, then fall back to the aggregate modifier flag.
    static func modifierKeyIsDownForRecording(
        keyCode: Int64,
        eventFlags: CGEventFlags
    ) -> Bool {
        guard let sideFlag = modifierFlagBitsByKeyCode[keyCode] else { return false }
        let familyKeyCodes: [Int64]
        switch keyCode {
        case 54, 55: familyKeyCodes = [54, 55]
        case 58, 61: familyKeyCodes = [58, 61]
        case 59, 62: familyKeyCodes = [59, 62]
        case 56, 60: familyKeyCodes = [56, 60]
        default: return false
        }
        let familySideMask = familyKeyCodes.reduce(UInt64(0)) {
            $0 | (modifierFlagBitsByKeyCode[$1] ?? 0)
        }
        if eventFlags.rawValue & familySideMask != 0 {
            return eventFlags.rawValue & sideFlag != 0
        }
        return eventFlags.contains(modifierMask(for: keyCode))
    }

    static func physicallyPressedModifierKeyCodes(
        keyState: (Int64) -> Bool
    ) -> Set<Int64> {
        Set(trackedModifierKeyCodes.filter(keyState))
    }

    private static func modifierKeyIsPhysicallyDown(_ keyCode: Int64) -> Bool {
        guard trackedModifierKeyCodes.contains(keyCode) else { return false }
        return CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(keyCode)
        )
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
        PhysicalKeyDelivery.shared.reset()
        modifierKeyState.reset()
        modifierToggleState.reset()
        regularKeyState.reset()
        keyBindingRecorderState.reset()
        suppressedHanjaModifierKeyCode = nil
    }

    private func resynchronizeKeyState() {
        modifierToggleState.reset()
        Self.resynchronizeKeyState(
            modifierState: &modifierKeyState,
            regularState: &regularKeyState,
            modifierKeyState: { keyCode in
                Self.modifierKeyIsPhysicallyDown(keyCode)
            },
            regularKeyState: { keyCode in
                CGEventSource.keyState(
                    .combinedSessionState,
                    key: CGKeyCode(keyCode)
                )
            }
        )

        if let keyCode = suppressedHanjaModifierKeyCode,
           !modifierKeyState.isSuppressed(keyCode: keyCode) {
            suppressedHanjaModifierKeyCode = nil
        }
    }

    static func resynchronizeKeyState(
        modifierState: inout ModifierKeyPressState,
        regularState: inout RegularKeyPressState,
        modifierKeyState: (Int64) -> Bool,
        regularKeyState: (Int64) -> Bool
    ) {
        let physicallyPressedModifiers = physicallyPressedModifierKeyCodes(
            keyState: modifierKeyState
        )
        modifierState.resynchronize(pressedKeyCodes: physicallyPressedModifiers)

        let physicallyPressedRegularKeys = Set(
            regularState.trackedKeyCodes.filter(regularKeyState)
        )
        regularState.resynchronize(pressedKeyCodes: physicallyPressedRegularKeys)
    }

    private func triggerToggle(eventTimestamp: TimeInterval? = nil) {
        let callback = onToggle
        let trace = ToggleLatencyTrace.begin(source: .customKey)
        // Record the physical intent before the next keyDown can overtake a main-
        // queue hop. `InputModeCoordinator.requestToggle` only appends to its locked
        // queue here. Timestamped modifier intents wait for the corresponding
        // IMK flagsChanged/keyDown boundary, including when the main queue runs
        // before Chrome has delivered older keys.
        callback?(trace, eventTimestamp)
    }
    
    private func triggerHanjaLookup() {
        let callback = onHanjaLookup
        DispatchQueue.main.async {
            callback?()
        }
    }
}
