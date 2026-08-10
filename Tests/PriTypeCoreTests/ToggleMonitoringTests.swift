import CoreGraphics
import Testing
@testable import PriTypeCore

@Suite("Toggle monitoring ownership")
struct ToggleMonitoringOwnershipTests {
    @Test("Only one backend can own monitoring and handoff is idempotent")
    func exclusiveOwnershipAndHandoff() {
        let store = ToggleMonitorStatusStore()

        #expect(store.reserveStart(.eventTap))
        #expect(!store.reserveStart(.iokit))

        store.markRunning(.eventTap)
        #expect(store.status == .running(backend: .eventTap, limitations: []))
        store.markUnavailable(.iokit, issue: .iokitOpenFailed(-1))
        store.markStopped(.iokit)
        #expect(store.status == .running(backend: .eventTap, limitations: []))

        #expect(store.beginEventTapHandoff())
        #expect(!store.beginEventTapHandoff())
        #expect(store.status == .transitioning(from: .eventTap, to: .iokit))

        #expect(store.reserveStart(.iokit))
        store.markRunning(.iokit)
        #expect(store.status == .running(backend: .iokit, limitations: []))
        #expect(!store.reserveStart(.eventTap))
    }

    @Test("A failed backend start exposes its reason")
    func failedStartStatus() {
        let store = ToggleMonitorStatusStore()

        #expect(store.reserveStart(.iokit))
        store.failStart(.iokit, issue: .iokitOpenFailed(-1))

        #expect(store.status == .unavailable(.iokitOpenFailed(-1)))
    }
}

@Suite("CGEventTap failure handoff")
struct TapDisableTrackerTests {
    @Test("The third disable requests exactly one permanent handoff")
    func thirdDisableHandsOffOnce() {
        var tracker = TapDisableTracker(maximumRetryCount: 3, resetInterval: 60)

        #expect(tracker.recordDisable(at: 0) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 1) == .reenable(attempt: 2))
        #expect(tracker.recordDisable(at: 2) == .handoff)
        #expect(tracker.recordDisable(at: 3) == .ignore)
        #expect(tracker.disableCount == 3)
    }

    @Test("A stable interval resets the retry count")
    func stableIntervalResetsCount() {
        var tracker = TapDisableTracker(maximumRetryCount: 3, resetInterval: 60)

        #expect(tracker.recordDisable(at: 0) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 61) == .reenable(attempt: 1))
        #expect(tracker.disableCount == 1)
    }
}

@Suite("Suppressed key pairs")
struct SuppressedKeyPairTests {
    @Test("The event tap observes key-up for suppressed pairs")
    func eventTapIncludesKeyUp() {
        let keyUpMask = CGEventMask(1) << CGEventType.keyUp.rawValue
        #expect(RightCommandSuppressor.monitoredEventMask & keyUpMask != 0)
    }

    @Test("A regular binding triggers once and consumes repeat and key-up")
    func regularBindingPair() {
        var state = RegularKeyPressState()

        #expect(state.keyDown(keyCode: 105, isRepeat: false, matchesBinding: true) == .triggerAndSuppress)
        #expect(state.keyDown(keyCode: 105, isRepeat: true, matchesBinding: true) == .suppress)
        #expect(state.keyUp(keyCode: 105) == .suppress)
        #expect(state.keyUp(keyCode: 105) == .passThrough)
    }

    @Test("A repeat first observed mid-hold never triggers")
    func repeatWithoutInitialDown() {
        var state = RegularKeyPressState()

        #expect(state.keyDown(keyCode: 49, isRepeat: true, matchesBinding: true) == .suppress)
        #expect(state.keyUp(keyCode: 49) == .suppress)
    }

    @Test("Unbound down and up pass through")
    func unboundPairPassesThrough() {
        var state = RegularKeyPressState()

        #expect(state.keyDown(keyCode: 0, isRepeat: false, matchesBinding: false) == .passThrough)
        #expect(state.keyUp(keyCode: 0) == .passThrough)
    }

    @Test("Secure regular Hanja bindings pass through before the controller callback")
    func secureRegularHanjaBindingPassesThrough() {
        var state = RegularKeyPressState()
        let binding = KeyBinding(keyCode: 5, modifiers: 0, displayName: "G")
        let suppressionAllowed = HanjaShortcutSuppressionPolicy.allowsSuppression(
            binding: binding,
            sessionState: .secure
        )

        #expect(!suppressionAllowed)
        #expect(state.keyDown(
            keyCode: 5,
            isRepeat: false,
            matchesBinding: true,
            suppressionAllowed: suppressionAllowed
        ) == .passThrough)
        // A main-thread context refresh during the hold must not turn an already
        // passed-through down into a suppressed repeat/up pair.
        #expect(state.keyDown(
            keyCode: 5,
            isRepeat: true,
            matchesBinding: true,
            suppressionAllowed: true
        ) == .passThrough)
        #expect(state.keyUp(keyCode: 5) == .passThrough)
    }

    @Test("Unknown regular Hanja bindings fail open to the host")
    func unknownRegularHanjaBindingPassesThrough() {
        var state = RegularKeyPressState()
        let binding = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue, displayName: "Control + Space")

        #expect(state.keyDown(
            keyCode: binding.keyCode,
            isRepeat: false,
            matchesBinding: true,
            suppressionAllowed: HanjaShortcutSuppressionPolicy.allowsSuppression(
                binding: binding,
                sessionState: .unknown
            )
        ) == .passThrough)
        #expect(state.keyUp(keyCode: binding.keyCode) == .passThrough)
    }

    @Test("Known nonsecure regular Hanja bindings still trigger and suppress")
    func nonsecureRegularHanjaBindingSuppresses() {
        var state = RegularKeyPressState()
        let binding = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")

        #expect(state.keyDown(
            keyCode: binding.keyCode,
            isRepeat: false,
            matchesBinding: true,
            suppressionAllowed: HanjaShortcutSuppressionPolicy.allowsSuppression(
                binding: binding,
                sessionState: .nonsecure
            )
        ) == .triggerAndSuppress)
        #expect(state.keyDown(
            keyCode: binding.keyCode,
            isRepeat: true,
            matchesBinding: true,
            suppressionAllowed: true
        ) == .suppress)
        #expect(state.keyUp(keyCode: binding.keyCode) == .suppress)
    }

    @Test("Modifier-only Hanja bindings preserve their global shortcut contract")
    func modifierOnlyHanjaBindingAlwaysSuppresses() {
        #expect(HanjaShortcutSuppressionPolicy.allowsSuppression(
            binding: .defaultHanja,
            sessionState: .unknown
        ))
        #expect(HanjaShortcutSuppressionPolicy.allowsSuppression(
            binding: .defaultHanja,
            sessionState: .secure
        ))
    }

    @Test("Hanja shortcut state snapshots start unknown and apply every transition")
    func hanjaShortcutSessionStateStoreSnapshot() {
        let store = HanjaShortcutSessionStateStore()

        #expect(store.state == .unknown)
        store.update(.nonsecure)
        #expect(store.state == .nonsecure)
        store.update(.secure)
        #expect(store.state == .secure)
        store.update(.unknown)
        #expect(store.state == .unknown)
    }

    @Test("IOKit repeat cannot erase a chorded modifier state")
    func iokitRepeatPreservesChordedState() {
        var state = ReleaseTogglePressState()

        #expect(state.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .pressed)
        #expect(state.handle(usage: 0xE3, pressed: true, toggleUsage: 0xE7) == .chorded)
        #expect(state.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .repeatIgnored)
        #expect(state.handle(usage: 0xE7, pressed: false, toggleUsage: 0xE7) == .released(shouldToggle: false))

        #expect(state.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .pressed)
        #expect(state.handle(usage: 0xE7, pressed: false, toggleUsage: 0xE7) == .released(shouldToggle: true))
    }

    @Test("Changing a fallback binding clears an in-flight press")
    func iokitBindingChangeResetsPress() {
        var state = ReleaseTogglePressState()

        #expect(state.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .pressed)
        state.reset()
        #expect(state.handle(usage: 0xE7, pressed: false, toggleUsage: 0xE7) == .none)
    }

    @Test("IOKit trace spans physical down through a valid release")
    func iokitTraceSpansPress() {
        var pressState = ReleaseTogglePressState()
        var traceLifecycle = IOKitToggleTraceLifecycle()

        #expect(pressState.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .pressed)
        traceLifecycle.begin()
        #expect(traceLifecycle.hasPendingTrace)

        #expect(pressState.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .repeatIgnored)
        #expect(traceLifecycle.hasPendingTrace)

        #expect(pressState.handle(usage: 0xE7, pressed: false, toggleUsage: 0xE7) == .released(shouldToggle: true))
        guard case .some = traceLifecycle.finish() else {
            Issue.record("Physical-down trace must survive until the valid release")
            return
        }
        #expect(!traceLifecycle.hasPendingTrace)
    }

    @Test("Chord and reset cancel an in-flight IOKit trace")
    func iokitTraceCancellation() {
        var pressState = ReleaseTogglePressState()
        var traceLifecycle = IOKitToggleTraceLifecycle()

        #expect(pressState.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .pressed)
        traceLifecycle.begin()
        #expect(pressState.handle(usage: 0x04, pressed: true, toggleUsage: 0xE7) == .chorded)
        traceLifecycle.cancel()
        #expect(!traceLifecycle.hasPendingTrace)
        guard case .none = traceLifecycle.finish() else {
            Issue.record("A cancelled trace must not reach the toggle callback")
            return
        }

        pressState.reset()
        #expect(pressState.handle(usage: 0xE7, pressed: true, toggleUsage: 0xE7) == .pressed)
        traceLifecycle.begin()
        pressState.reset()
        traceLifecycle.cancel()
        #expect(!traceLifecycle.hasPendingTrace)
    }

    @Test("Opposite-side modifiers retain independent keyCode state")
    func oppositeSideModifierState() {
        var state = ModifierKeyPressState()

        #expect(state.observe(keyCode: 54, physicalKeyIsDown: true) == .down)
        state.suppressUntilRelease(keyCode: 54)
        #expect(state.observe(keyCode: 55, physicalKeyIsDown: true) == .down)
        #expect(state.hasPressedSibling(of: 54, sharingKeyCodes: [54, 55]))

        // Releasing Right Command while Left Command remains down still uses
        // its actual physical state instead of the aggregate Command flag.
        #expect(state.observe(keyCode: 54, physicalKeyIsDown: false) == .up)
        let consumedRelease = state.consumeSuppressedRelease(keyCode: 54)
        #expect(consumedRelease)
        #expect(!state.hasPressedSibling(of: 55, sharingKeyCodes: [54, 55]))
    }

    @Test("Startup resync classifies a missed-down release as up")
    func modifierStartupResync() {
        var state = ModifierKeyPressState()

        state.resynchronize(pressedKeyCodes: [54, 55])
        #expect(state.observe(keyCode: 54, physicalKeyIsDown: false) == .up)
        #expect(state.pressedKeyCodes == [55])

        // A release queued just before the snapshot is fail-closed even when
        // the sibling keeps the aggregate Command flag set.
        var queuedReleaseState = ModifierKeyPressState()
        queuedReleaseState.resynchronize(pressedKeyCodes: [55])
        #expect(queuedReleaseState.observe(keyCode: 54, physicalKeyIsDown: false) == .unknown)
        #expect(state.observe(keyCode: 55, physicalKeyIsDown: false) == .up)
        #expect(state.pressedKeyCodes.isEmpty)
    }

    @Test("Restart resync preserves only physically held suppressed releases")
    func modifierRestartResync() {
        var state = ModifierKeyPressState()

        #expect(state.observe(keyCode: 54, physicalKeyIsDown: true) == .down)
        state.suppressUntilRelease(keyCode: 54)
        #expect(state.observe(keyCode: 55, physicalKeyIsDown: true) == .down)
        state.resynchronize(pressedKeyCodes: [54])

        #expect(state.isSuppressed(keyCode: 54))
        #expect(state.observe(keyCode: 55, physicalKeyIsDown: false) == .unknown)
        #expect(state.observe(keyCode: 54, physicalKeyIsDown: false) == .up)
        let consumedRelease = state.consumeSuppressedRelease(keyCode: 54)
        #expect(consumedRelease)
    }

    @Test("Physical modifier snapshot keeps exact sides and excludes lock state")
    func physicalModifierSnapshot() {
        let physicallyDown: Set<Int64> = [54, 60, 57]
        let snapshot = RightCommandSuppressor.physicallyPressedModifierKeyCodes {
            physicallyDown.contains($0)
        }

        #expect(snapshot == [54, 60])
    }
}

@Suite("IOKit fallback capabilities")
struct IOKitFallbackCapabilityTests {
    @Test("Modifier-only bindings are supported without limitations")
    func modifierBindingsSupported() {
        let limitations = IOKitManager.bindingLimitations(
            toggleBinding: .defaultToggle,
            hanjaBinding: .defaultHanja,
            priTypeToggleEnabled: true
        )

        #expect(limitations.isEmpty)
    }

    @Test("Regular and combo bindings are exposed as unsupported")
    func regularBindingsUnsupported() {
        let controlSpace = KeyBinding(
            keyCode: 49,
            modifiers: CGEventFlags.maskControl.rawValue,
            displayName: "Control + Space"
        )
        let f13 = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")

        let limitations = IOKitManager.bindingLimitations(
            toggleBinding: controlSpace,
            hanjaBinding: f13,
            priTypeToggleEnabled: true
        )

        #expect(limitations == [
            .unsupportedIOKitToggleBinding("Control + Space"),
            .unsupportedIOKitHanjaBinding("F13")
        ])
    }

    @Test("Native Caps Lock mode does not report the unused custom toggle")
    func nativeCapsLockSkipsToggleLimitation() {
        let controlSpace = KeyBinding(
            keyCode: 49,
            modifiers: CGEventFlags.maskControl.rawValue,
            displayName: "Control + Space"
        )

        let limitations = IOKitManager.bindingLimitations(
            toggleBinding: controlSpace,
            hanjaBinding: .defaultHanja,
            priTypeToggleEnabled: false
        )

        #expect(limitations.isEmpty)
    }
}
