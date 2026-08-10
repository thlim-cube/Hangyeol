import Cocoa
import Testing
@testable import PriTypeCore

private final class RecordingModePresentation: StatusBarUpdating, PendingInputModePresenting {
    private(set) var state: InputModePresentationState
    private(set) var pendingUpdates: [InputMode?] = []

    init(actualMode: InputMode = .korean) {
        state = InputModePresentationState(actualMode: actualMode)
    }

    func setMode(_ mode: InputMode) {
        state.setActualMode(mode)
    }

    func setPendingMode(_ mode: InputMode?) {
        pendingUpdates.append(mode)
        state.setPendingMode(mode)
    }
}

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

    @Test("Exact PriType source ID is classified as PriType")
    func exactPriTypeSourceIDClassification() {
        #expect(SelectedInputSourceClassifier.classify(
            inputSourceID: "com.pritype.inputmethod.v2",
            bundleID: nil
        ) == .priType)
    }

    @Test("Alternate mode ID from the PriType bundle is classified as PriType")
    func alternatePriTypeModeIDClassification() {
        #expect(SelectedInputSourceClassifier.classify(
            inputSourceID: "com.pritype.inputmethod.v2.v2",
            bundleID: "com.pritype.inputmethod.v2"
        ) == .priType)
    }

    @Test("Alternate mode ID from another bundle remains other")
    func alternateModeIDFromAnotherBundleClassification() {
        #expect(SelectedInputSourceClassifier.classify(
            inputSourceID: "com.pritype.inputmethod.v2.v2",
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

    @Test("Initial, repeated, and PriType-owned activations preserve mode")
    func nonSystemBoundariesPreserveMode() {
        for macOSOwnsSwitching in [false, true] {
            var tracker = InputModeOwnershipTracker()
            let snapshot = InputModeOwnershipSnapshot(
                macOSOwnsSwitching: macOSOwnsSwitching,
                selectedInputSource: .priType
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
            selectedInputSource: .priType
        )) == nil)
        #expect(!sourceTracker.hasPendingKoreanReconciliation)
    }

    @Test("Ownership boundaries update presentation without writing mode or client")
    @MainActor
    func pendingPresentationBeforeSecureGate() {
        let presentation = RecordingModePresentation(actualMode: .english)
        let coordinator = InputModeCoordinator(modePresentation: presentation)

        let priTypeOwnedSnapshot = InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .priType
        )
        coordinator.observe(priTypeOwnedSnapshot)
        coordinator.observe(priTypeOwnedSnapshot)

        #expect(presentation.state.pendingMode == nil)
        #expect(presentation.state.displayedMode == .english)
        #expect(presentation.pendingUpdates == [nil, nil])

        let macOSOwnedSnapshot = InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .priType
        )
        coordinator.observe(macOSOwnedSnapshot)
        coordinator.observe(macOSOwnedSnapshot)

        #expect(presentation.state.actualMode == .english)
        #expect(presentation.state.pendingMode == .korean)
        #expect(presentation.state.displayedMode == .korean)
        #expect(presentation.pendingUpdates == [nil, nil, .korean, .korean])

        coordinator.observe(priTypeOwnedSnapshot)

        #expect(presentation.state.pendingMode == nil)
        #expect(presentation.state.displayedMode == .english)
        #expect(presentation.pendingUpdates == [nil, nil, .korean, .korean, nil])
    }

    @Test("macOS ownership requests Korean until ownership returns")
    func macOSOwnershipLifecycle() {
        var tracker = InputModeOwnershipTracker()
        _ = tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .priType
        ))

        #expect(tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .priType
        )) == .macOSOwnershipEnabled)
        #expect(tracker.hasPendingKoreanReconciliation)

        #expect(tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .priType
        )) == nil)
        #expect(tracker.hasPendingKoreanReconciliation)
        #expect(tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .priType
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
            selectedInputSource: .priType
        )) == .priTypeReselected)

        var ownershipTracker = InputModeOwnershipTracker()
        _ = ownershipTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: false,
            selectedInputSource: .priType
        ))
        #expect(ownershipTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .unavailable
        )) == nil)
        #expect(!ownershipTracker.hasPendingKoreanReconciliation)
        #expect(ownershipTracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .priType
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
            selectedInputSource: .priType
        )) == .priTypeReselected)
    }

    @Test("System boundary transaction finalizes once and normalizes to Korean")
    func systemBoundaryTransactionFinalizesAndNormalizes() {
        let client = FakeIMKTextInput()
        let store = InputModeStore()
        let presentation = RecordingModePresentation()
        let composer = makeComposer(store: store, statusBar: presentation)
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
        makeComposer(store: store, statusBar: presentation).setInputMode(.english)
        #expect(composer.inputMode == .english)
        #expect(composer.hasActiveComposition)
        presentation.setPendingMode(.korean)
        #expect(presentation.state.actualMode == .english)
        #expect(presentation.state.displayedMode == .korean)

        var didSyncLayout = false
        PriTypeInputController.applyMacOSOwnedInputSourceBoundary(to: session) {
            didSyncLayout = true
        }

        #expect(didSyncLayout)
        #expect(composer.inputMode == .korean)
        #expect(presentation.state.actualMode == .korean)
        #expect(presentation.state.pendingMode == nil)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.insertCalls.count == 1)
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

        let routed = PriTypeInputController.routeExternalHanjaLookup(
            in: session,
            isSecureInput: false,
            reconcileOwnership: {
                guard tracker.hasPendingKoreanReconciliation else { return }
                PriTypeInputController.applyMacOSOwnedInputSourceBoundary(to: session) {}
                tracker.markReconciled()
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

        let routed = PriTypeInputController.routeExternalHanjaLookup(
            in: session,
            isSecureInput: true,
            reconcileOwnership: {
                didReconcile = true
                guard tracker.hasPendingKoreanReconciliation else { return }
                PriTypeInputController.applyMacOSOwnedInputSourceBoundary(to: session) {}
                tracker.markReconciled()
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

    private func pendingOwnershipTracker() -> InputModeOwnershipTracker {
        var tracker = InputModeOwnershipTracker()
        _ = tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .other
        ))
        _ = tracker.observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: true,
            selectedInputSource: .priType
        ))
        return tracker
    }
}

@Suite("Process-wide input ownership")
struct ProcessWideInputOwnershipTests {
    private final class Owner {}

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
        registry.claim(second) { _ in
            registry.claim(third) { _ in }
            ownerAfterReentrantClaim = registry.owner
        }

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
