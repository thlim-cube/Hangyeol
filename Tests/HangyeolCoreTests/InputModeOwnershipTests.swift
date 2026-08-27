import Cocoa
import Testing
@testable import HangyeolCore

@Suite("Input mode and composition ownership")
struct InputModeOwnershipTests {
    private func makeComposer(
        store: InputModeStore,
        statusBar: StatusBarUpdating = MockStatusBar()
    ) -> HangulComposer {
        HangulComposer(
            statusBar: statusBar,
            configuration: MockConfiguration(),
            inputModeStore: store
        )
    }

    @Test("Exact Hangyeol source ID is classified as Hangyeol")
    func exactHangyeolSourceIDClassification() {
        #expect(SelectedInputSourceClassifier.classify(
            inputSourceID: "com.thlim.inputmethod.Hangyeol",
            bundleID: nil
        ) == .hangyeol)
    }

    @Test("Alternate mode ID from the Hangyeol bundle is classified as Hangyeol")
    func alternateHangyeolModeIDClassification() {
        #expect(SelectedInputSourceClassifier.classify(
            inputSourceID: "com.thlim.inputmethod.Hangyeol.alternate",
            bundleID: "com.thlim.inputmethod.Hangyeol"
        ) == .hangyeol)
    }

    @Test("Alternate mode ID from another bundle remains other")
    func alternateModeIDFromAnotherBundleClassification() {
        #expect(SelectedInputSourceClassifier.classify(
            inputSourceID: "com.thlim.inputmethod.Hangyeol.alternate",
            bundleID: "com.example.inputmethod"
        ) == .other)
    }

    @Test("Sessions share mode without sharing libhangul composition")
    func sharedModeIsolatedComposition() {
        let store = InputModeStore()
        let first = makeComposer(store: store)
        let second = makeComposer(store: store)
        let firstDelegate = MockComposerDelegate()
        let secondDelegate = MockComposerDelegate()

        _ = first.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: firstDelegate)
        _ = first.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: firstDelegate)

        #expect(first.hasActiveComposition)
        #expect(firstDelegate.markedText == "가")
        #expect(!second.hasActiveComposition)
        #expect(secondDelegate.markedText.isEmpty)

        second.setInputMode(.english)
        #expect(first.inputMode == .english)
        #expect(second.inputMode == .english)
        #expect(first.hasActiveComposition, "Changing the shared mode must not flush another session")

        let committed = first.flushCommitString()
        #expect(committed == "가")
        #expect(!first.hasActiveComposition)
        #expect(!second.hasActiveComposition)
    }

    @Test("Standalone composers retain isolated mode stores")
    func standaloneComposerModeIsolation() {
        let first = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let second = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())

        first.setInputMode(.english)

        #expect(first.inputMode == .english)
        #expect(second.inputMode == .korean)
    }

    @Test("Initial, repeated, and Hangyeol-owned activations preserve mode")
    func nonSystemBoundariesPreserveMode() {
        for macOSOwnsSwitching in [false, true] {
            var tracker = InputModeOwnershipTracker()
            let snapshot = InputModeOwnershipSnapshot(
                macOSOwnsSwitching: macOSOwnsSwitching,
                selectedInputSource: .hangyeol
            )

            #expect(tracker.observe(snapshot) == nil)
            #expect(tracker.observe(snapshot) == nil)
            #expect(!tracker.hasPendingKoreanReconciliation)
        }

        var sourceTracker = InputModeOwnershipTracker()
        _ = sourceTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .other
        ))
        #expect(sourceTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .hangyeol
        )) == nil)
        #expect(!sourceTracker.hasPendingKoreanReconciliation)
    }

    @Test("macOS ownership requests Korean until ownership returns")
    func macOSOwnershipLifecycle() {
        var tracker = InputModeOwnershipTracker()
        _ = tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .hangyeol
        ))

        #expect(tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .hangyeol
        )) == .macOSOwnershipEnabled)
        #expect(tracker.hasPendingKoreanReconciliation)

        #expect(tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .hangyeol
        )) == nil)
        #expect(tracker.hasPendingKoreanReconciliation)
        #expect(tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .hangyeol
        )) == nil)
        #expect(!tracker.hasPendingKoreanReconciliation)
    }

    @Test("Source reselection and unavailable TIS state reconcile only after confirmation")
    func sourceReselectionAndUnavailableState() {
        var directTracker = InputModeOwnershipTracker()
        _ = directTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .other
        ))
        #expect(directTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .hangyeol
        )) == .hangyeolReselected)

        var ownershipTracker = InputModeOwnershipTracker()
        _ = ownershipTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .hangyeol
        ))
        #expect(ownershipTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .unavailable
        )) == nil)
        #expect(!ownershipTracker.hasPendingKoreanReconciliation)
        #expect(ownershipTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .hangyeol
        )) == .macOSOwnershipEnabled)

        var selectionTracker = InputModeOwnershipTracker()
        _ = selectionTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .other
        ))
        #expect(selectionTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .unavailable
        )) == nil)
        #expect(selectionTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .hangyeol
        )) == .hangyeolReselected)
    }

    @Test("System boundary transaction finalizes once and normalizes to Korean")
    func systemBoundaryTransactionFinalizesAndNormalizes() {
        let client = FakeIMKTextInput()
        let store = InputModeStore()
        let statusBar = MockStatusBar()
        let composer = makeComposer(store: store, statusBar: statusBar)
        let session = InputSession(
            client: client,
            context: ClientContext(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                isLikelyDesktopArea: false,
                documentAccessSafe: true
            ),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(composer.hasActiveComposition)
        makeComposer(store: store, statusBar: statusBar).setInputMode(.english)
        #expect(composer.inputMode == .english)
        #expect(composer.hasActiveComposition)
        #expect(statusBar.currentMode == .english)

        var didSyncLayout = false
        #expect(HangyeolInputController.applyMacOSOwnedInputSourceBoundary(to: session) {
            didSyncLayout = true
        })

        #expect(didSyncLayout)
        #expect(composer.inputMode == .korean)
        #expect(statusBar.currentMode == .korean)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.insertCalls.count == 1)
    }

    @Test("A reentrant ownership boundary aborts before layout and mode writes")
    func reentrantSystemBoundaryAbortsWrites() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let store = InputModeStore()
        let composer = makeComposer(store: store)
        let session = InputSession(
            client: client,
            context: ClientContext(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                isLikelyDesktopArea: false,
                documentAccessSafe: true
            ),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        makeComposer(store: store).setInputMode(.english)
        var didSyncLayout = false
        client.onInsertText = {
            client.onInsertText = nil
            session.markContextStaleForSameClientReactivation()
        }

        let reconciled = HangyeolInputController.applyMacOSOwnedInputSourceBoundary(
            to: session,
            syncRomanKeyboardLayout: {
                didSyncLayout = true
            }
        )
        #expect(!reconciled)
        #expect(!didSyncLayout)
        #expect(composer.inputMode == .english)
        #expect(session.contextNeedsRefresh)
    }

    @Test("Pending ownership reconciles before a nonsecure external Hanja lookup")
    func pendingOwnershipReconcilesBeforeExternalHanjaLookup() {
        let client = FakeIMKTextInput()
        let store = InputModeStore()
        let composer = makeComposer(store: store)
        let session = InputSession(
            client: client,
            context: ClientContext(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                isLikelyDesktopArea: false,
                documentAccessSafe: true
            ),
            composer: composer
        )
        composer.setInputMode(.english)
        var tracker = pendingOwnershipTracker()
        var modeAtLookup: InputMode?

        let routed = HangyeolInputController.routeExternalHanjaLookup(
            in: session,
            isSecureInput: false,
            reconcileOwnership: {
                guard tracker.hasPendingKoreanReconciliation else { return }
                if HangyeolInputController.applyMacOSOwnedInputSourceBoundary(
                    to: session,
                    syncRomanKeyboardLayout: {}
                ) {
                    tracker.markReconciled()
                }
            },
            performLookup: { lookupComposer in
                modeAtLookup = lookupComposer.inputMode
            }
        )

        #expect(routed)
        #expect(modeAtLookup == .korean)
        #expect(composer.inputMode == .korean)
        #expect(!tracker.hasPendingKoreanReconciliation)
    }

    @Test("Secure external Hanja keeps ownership pending without client writes")
    func secureExternalHanjaKeepsPendingOwnership() {
        let client = FakeIMKTextInput()
        let store = InputModeStore()
        let composer = makeComposer(store: store)
        let session = InputSession(
            client: client,
            context: ClientContext(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                isLikelyDesktopArea: false,
                documentAccessSafe: true
            ),
            composer: composer
        )
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        makeComposer(store: store).setInputMode(.english)
        var tracker = pendingOwnershipTracker()
        let insertCountBefore = client.insertCalls.count
        let markCountBefore = client.markCalls.count
        var didReconcile = false
        var didLookup = false

        let routed = HangyeolInputController.routeExternalHanjaLookup(
            in: session,
            isSecureInput: true,
            reconcileOwnership: {
                didReconcile = true
                guard tracker.hasPendingKoreanReconciliation else { return }
                if HangyeolInputController.applyMacOSOwnedInputSourceBoundary(
                    to: session,
                    syncRomanKeyboardLayout: {}
                ) {
                    tracker.markReconciled()
                }
            },
            performLookup: { _ in
                didLookup = true
            }
        )

        #expect(!routed)
        #expect(!didReconcile)
        #expect(!didLookup)
        #expect(tracker.hasPendingKoreanReconciliation)
        #expect(composer.inputMode == .english)
        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.count == insertCountBefore)
        #expect(client.markCalls.count == markCountBefore)
    }

    @Test("A toggle survives field handoff and applies before the first keyDown")
    @MainActor
    func toggleSurvivesFieldHandoffBeforeFirstKeyDown() {
        let coordinator = InputModeCoordinator(
            activeControllerProvider: { nil },
            capsLockOwnershipProvider: { false }
        )
        DispatchQueue.global().sync {
            coordinator.requestToggle(source: .customKey)
        }

        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let composer = makeComposer(store: InputModeStore())
        let session = InputSession(
            client: client,
            context: ClientContext(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                isLikelyDesktopArea: false,
                documentAccessSafe: true
            ),
            composer: composer
        )
        session.markContextStaleForSameClientReactivation()
        var analyzeCount = 0

        let applied = coordinator.reconcilePendingToggleIfNeeded { source, trace in
            var didApplyMode = false
            _ = HangyeolInputController.routeExternalModeTransition(
                in: session,
                source: source,
                trace: trace,
                analyzeContext: { _ in
                    analyzeCount += 1
                    return ClientContext(
                        bundleId: client.bundleID,
                        hasTextInputCapability: true,
                        isLikelyDesktopArea: false,
                        documentAccessSafe: true
                    )
                },
                shouldPassThroughSecureInput: { _, _ in false },
                syncRomanKeyboardLayout: { _, _ in },
                didApplyMode: {
                    didApplyMode = true
                }
            )
            return didApplyMode
        }

        #expect(applied)
        #expect(!coordinator.reconcilePendingToggleIfNeeded { _, _ in
            Issue.record("The applied toggle must be removed exactly once")
            return true
        })
        #expect(analyzeCount == 1)
        #expect(composer.inputMode == .english)

        let markCountBeforeInput = client.markCalls.count
        let firstKeyHandled = composer.handle(
            TestEventFactory.keyEvent(char: "a", keyCode: 0)!,
            delegate: session.adapter
        )
        #expect(!firstKeyHandled)
        #expect(client.markCalls.count == markCountBeforeInput)
    }

    @Test("Physical toggle delivery records intent before returning from monitor callback")
    @MainActor
    func physicalToggleIntentPrecedesMainQueueAndFirstKey() {
        let coordinator = InputModeCoordinator(
            activeControllerProvider: { nil },
            capsLockOwnershipProvider: { false }
        )
        let trace = ToggleLatencyTrace.begin(source: .customKey)

        DispatchQueue.global().sync {
            PhysicalToggleIntentDelivery.record(trace) { trace in
                coordinator.requestToggle(source: .customKey, trace: trace)
            }
        }

        var applied = false
        #expect(coordinator.reconcilePendingToggleIfNeeded { _, _ in
            applied = true
            return true
        })
        #expect(applied)
    }

    private func pendingOwnershipTracker() -> InputModeOwnershipTracker {
        var tracker = InputModeOwnershipTracker()
        _ = tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .other
        ))
        _ = tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .hangyeol
        ))
        return tracker
    }
}

@Suite("Process-wide input ownership")
struct ProcessWideInputOwnershipTests {
    private final class Owner {}

    @Test("Controller claims a delivered keyDown before resolving its input session")
    func controllerWiresKeyDownOwnershipBeforeSessionResolution() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerURL = repoRoot
            .appendingPathComponent("Sources/HangyeolCore/HangyeolInputController.swift")
        let source = try String(contentsOf: controllerURL, encoding: .utf8)
        let policyUse = try #require(source.range(of: "InputBoundaryOwnershipPolicy.requiresClaim("))
        let lateHandoff = try #require(source.range(of: "boundary: .lateKeyDown"))
        let sessionResolution = try #require(source.range(
            of: "guard let session = ensureSession(for: client) else { return false }"
        ))

        #expect(policyUse.lowerBound < sessionResolution.lowerBound)
        #expect(lateHandoff.lowerBound < sessionResolution.lowerBound)
        #expect(!source.contains("guard Self.sharedController == nil,"))
    }

    @Test("A first keyDown claims ownership even while the previous owner remains visible")
    func keyDownClaimsAcrossDelayedControllerHandoff() {
        let registry = ActiveOwnerHandoffRegistry<Owner>()
        let previous = Owner()
        let incoming = Owner()
        var retiredOwner: Owner?

        registry.claim(previous) { _ in }

        #expect(InputBoundaryOwnershipPolicy.requiresClaim(
            candidate: incoming,
            currentOwner: registry.owner
        ))
        let acquired = registry.claim(incoming) { retiring in
            retiredOwner = retiring
        }

        #expect(acquired)
        #expect(retiredOwner === previous)
        #expect(registry.owner === incoming)
        #expect(!InputBoundaryOwnershipPolicy.requiresClaim(
            candidate: incoming,
            currentOwner: registry.owner
        ))

        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration(),
            inputModeStore: InputModeStore(initialMode: .korean)
        )
        let delegate = MockComposerDelegate()
        let firstKeyDown = TestEventFactory.keyEvent(char: "r", keyCode: 15)!

        #expect(composer.handle(firstKeyDown, delegate: delegate))
        #expect(delegate.markedText == "ㄱ")
    }

    @Test("Claim retires the previous owner before publishing the next owner")
    func claimOrdersRetirementBeforeReplacement() {
        let registry = ActiveOwnerHandoffRegistry<Owner>()
        let first = Owner()
        let second = Owner()
        var retiredOwner: Owner?
        var ownerVisibleDuringRetirement: Owner?

        registry.claim(first) { _ in }
        registry.claim(second) { retiring in
            retiredOwner = retiring
            ownerVisibleDuringRetirement = registry.owner
        }

        #expect(retiredOwner === first)
        #expect(ownerVisibleDuringRetirement === first)
        #expect(registry.owner === second)

        registry.release(first)
        #expect(registry.owner === second)
        registry.release(second)
        #expect(registry.owner == nil)
    }

    @Test("A reentrant newer claim is not overwritten by the outer handoff")
    func reentrantClaimWinsOverOuterHandoff() {
        let registry = ActiveOwnerHandoffRegistry<Owner>()
        let first = Owner()
        let second = Owner()
        let third = Owner()
        var ownerAfterReentrantClaim: Owner?

        registry.claim(first) { _ in }
        let outerClaimAcquired = registry.claim(second) { _ in
            registry.claim(third) { _ in }
            ownerAfterReentrantClaim = registry.owner
        }

        #expect(!outerClaimAcquired)
        #expect(ownerAfterReentrantClaim === third)
        #expect(registry.owner === third)
    }

    @Test("Reclaiming the visible owner cancels an older in-flight handoff")
    func reentrantVisibleOwnerClaimWinsOverOuterHandoff() {
        let registry = ActiveOwnerHandoffRegistry<Owner>()
        let first = Owner()
        let second = Owner()

        registry.claim(first) { _ in }
        registry.claim(second) { _ in
            registry.claim(first) { _ in
                Issue.record("The visible owner must not be retired when it reclaims ownership")
            }
        }

        #expect(registry.owner === first)
    }

    @Test("Releasing an in-flight claimant cancels its outer publication")
    func reentrantReleaseCancelsInFlightClaim() {
        let registry = ActiveOwnerHandoffRegistry<Owner>()
        let first = Owner()
        let second = Owner()

        registry.claim(first) { _ in }
        registry.claim(second) { _ in
            registry.release(second)
        }

        #expect(registry.owner == nil)
    }
}
