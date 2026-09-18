import Cocoa
import Testing
@testable import HangyeolCore

@Suite("First input during a mode transition")
struct FirstInputModeRegressionTests {
    @Test("Queued modifier toggles cannot overtake older keys or collapse around an English key")
    @MainActor
    func delayedKeysRespectPhysicalToggleOrder() {
        let coordinator = InputModeCoordinator(
            activeControllerProvider: { nil },
            capsLockOwnershipProvider: { false }
        )
        // Both physical presses reach the event tap while IMK is still processing
        // the preceding Korean text. The key at 11 must see English, even though
        // the second toggle at 12 has already arrived on the monitoring thread.
        for timestamp in [10.0, 12.0] {
            coordinator.requestToggle(source: .customKey,
                                      trace: .begin(source: .customKey),
                                      eventTimestamp: timestamp)
        }
        var mode = InputMode.korean
        var commits = 0
        func apply(_: InputModeCoordinator.ToggleSource, _: ToggleLatencyTrace) -> Bool {
            commits += 1
            mode = mode.toggled
            return true
        }
        #expect(!coordinator.reconcilePendingToggleIfNeeded(perform: apply))
        #expect(!coordinator.reconcilePendingToggleIfNeeded(through: 9, perform: apply))
        #expect(mode == .korean)
        #expect(commits == 0)
        #expect(coordinator.reconcilePendingToggleIfNeeded(through: 10, perform: apply))
        #expect(mode == .english)
        #expect(!coordinator.reconcilePendingToggleIfNeeded(through: 11, perform: apply))
        #expect(mode == .english)
        #expect(coordinator.reconcilePendingToggleIfNeeded(through: 12, perform: apply))
        #expect(mode == .korean)
        #expect(commits == 2)
        #expect(!coordinator.reconcilePendingToggleIfNeeded(through: 13, perform: apply))
    }

    @Test("A key reentering from keyboard override uses the requested language",
          arguments: [InputMode.korean, .english])
    @MainActor
    func firstKeyDuringKeyboardOverride(initialMode: InputMode) {
        let coordinator = InputModeCoordinator(
            activeControllerProvider: { nil },
            capsLockOwnershipProvider: { false }
        )
        DispatchQueue.global().sync {
            coordinator.requestToggle(source: .customKey)
        }
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration(),
            inputModeStore: InputModeStore(initialMode: initialMode)
        )
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let context = ClientContext(
            bundleId: client.bundleID,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: true
        )
        let session = InputSession(client: client, context: context, composer: composer)
        _ = session.prepareForNonSecureClientWrites()
        let requestedMode = initialMode.toggled
        var observedMode: InputMode?
        var firstKeyHandled: Bool?
        var firstMarkedText: String?
        var transitionCount = 0

        let applied = coordinator.reconcilePendingToggleIfNeeded { source, trace in
            var didApply = false
            _ = HangyeolInputController.routeExternalModeTransition(
                in: session,
                source: source,
                trace: trace,
                analyzeContext: { _ in context },
                shouldPassThroughSecureInput: { _, _ in false },
                syncRomanKeyboardLayout: { _, mode in
                    #expect(mode == requestedMode)
                    // IMK client IPC may synchronously deliver another key. Its
                    // pending-toggle drain is guarded against applying twice.
                    #expect(!coordinator.reconcilePendingToggleIfNeeded { _, _ in
                        Issue.record("A nested key must not apply the toggle again")
                        return true
                    })
                    observedMode = composer.inputMode
                    firstKeyHandled = composer.handle(
                        TestEventFactory.keyEvent(char: "a", keyCode: 0)!,
                        delegate: session.adapter
                    )
                    firstMarkedText = client.markedText
                },
                didApplyMode: {
                    didApply = true
                    transitionCount += 1
                }
            )
            return didApply
        }

        #expect(applied)
        #expect(transitionCount == 1)
        #expect(observedMode == requestedMode)
        #expect(firstKeyHandled == (requestedMode == .korean))
        #expect(firstMarkedText == (requestedMode == .korean ? "ㅁ" : ""))
        #expect(composer.inputMode == requestedMode)
        #expect(client.markedText == firstMarkedText)
        #expect(composer.hasActiveComposition == (requestedMode == .korean))
        #expect(!coordinator.reconcilePendingToggleIfNeeded { _, _ in
            Issue.record("The completed toggle must not survive to the following key")
            return true
        })
    }

    @Test("A newer mode written during layout IPC survives the outer return")
    @MainActor
    func newerReentrantModeDuringLayoutIPCIsPreserved() {
        let coordinator = InputModeCoordinator(
            activeControllerProvider: { nil },
            capsLockOwnershipProvider: { false }
        )
        DispatchQueue.global().sync {
            coordinator.requestToggle(source: .customKey)
        }
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration(),
            inputModeStore: InputModeStore(initialMode: .korean)
        )
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let context = ClientContext(
            bundleId: client.bundleID,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: true
        )
        let session = InputSession(client: client, context: context, composer: composer)
        _ = session.prepareForNonSecureClientWrites()
        var nestedTransitionRan = false

        let applied = coordinator.reconcilePendingToggleIfNeeded { source, trace in
            var didApply = false
            _ = HangyeolInputController.routeExternalModeTransition(
                in: session,
                source: source,
                trace: trace,
                analyzeContext: { _ in context },
                shouldPassThroughSecureInput: { _, _ in false },
                syncRomanKeyboardLayout: { _, mode in
                    #expect(mode == .english)
                    #expect(composer.inputMode == .english)
                    nestedTransitionRan = HangyeolInputController.routeExternalModeTransition(
                        in: session,
                        source: .customKey,
                        trace: .begin(source: .customKey),
                        analyzeContext: { _ in context },
                        shouldPassThroughSecureInput: { _, _ in false },
                        syncRomanKeyboardLayout: { _, nestedMode in
                            #expect(nestedMode == .korean)
                        }
                    )
                    #expect(composer.inputMode == .korean)
                },
                didApplyMode: {
                    didApply = true
                }
            )
            return didApply
        }

        #expect(applied)
        #expect(nestedTransitionRan)
        #expect(composer.inputMode == .korean)
        #expect(!coordinator.reconcilePendingToggleIfNeeded { _, _ in
            Issue.record("The completed toggle must not survive to the following key")
            return true
        })
    }
}
