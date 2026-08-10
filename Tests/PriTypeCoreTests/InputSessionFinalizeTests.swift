import Foundation
import Testing
@testable import PriTypeCore

@Suite("Input session finalize")
struct InputSessionFinalizeTests {
    private func context(
        bundleId: String,
        documentAccessSafe: Bool
    ) -> ClientContext {
        ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: documentAccessSafe
        )
    }

    private func makeDirectFallbackSession() -> (InputSession, HangulComposer, FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        client.bundleID = "com.nousresearch.hermes"
        client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )
        return (session, composer, client)
    }

    @Test("Direct insertion marked fallback commits through the marked path")
    func directFallbackCommitsMarkedText() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")

        #expect(session.finalize(reason: .modeTransition))
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.1.location == NSNotFound)
    }

    @Test("Owned marked fallback is cleared even when the engine is already empty")
    func emptyEngineReconcilesOwnedFallback() {
        let (session, composer, client) = makeDirectFallbackSession()

        session.adapter.setMarkedText("ㄱ")
        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(session.mouseCompositionState == .staleMarkedFallback)
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: client.markedRange(),
            state: session.mouseCompositionState
        ))

        #expect(session.finalize(reason: .mouseCommit))
        #expect(session.mouseCompositionState == .inactive)
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.0 == "")
        #expect(client.insertCalls.first?.1 == NSRange(location: 0, length: 1))
    }

    @Test("Changing from marked to direct delivery finalizes through the old adapter")
    func markedToDirectFinalizesBeforeAdapterReplacement() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.TextEdit"
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        #expect(session.adapter.deliveryMode == .markedText)
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")

        session.refreshContext(context(bundleId: "com.nousresearch.hermes", documentAccessSafe: true))

        #expect(session.adapter.deliveryMode == .directInsertion)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
    }

    @Test("Changing from direct to marked delivery preserves committed text")
    func directToMarkedFinalizesBeforeAdapterReplacement() {
        let (session, composer, client) = makeDirectFallbackSession()
        client.selectedRangeValue = NSRange(location: 0, length: 0)

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        #expect(session.adapter.deliveryMode == .directInsertion)
        #expect(composer.hasActiveComposition)
        #expect(client.document == "ㄱ")

        session.refreshContext(context(bundleId: client.bundleID, documentAccessSafe: false))

        #expect(session.adapter.deliveryMode == .markedText)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
    }
}

@Suite("Mouse composition policy")
struct MouseCompositionPolicyTests {
    @Test("Click outside marked range finalizes")
    func outsideFinalizes() {
        let marked = NSRange(location: 10, length: 2)
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 9, markedRange: marked, state: .active))
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 12, markedRange: marked, state: .active))
    }

    @Test("Click inside marked range keeps composition")
    func insideKeepsComposition() {
        let marked = NSRange(location: 10, length: 2)
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 10, markedRange: marked, state: .active))
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 11, markedRange: marked, state: .active))
    }

    @Test("Direct insertion without marked range finalizes on any click")
    func directInsertionFinalizes() {
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 42,
            markedRange: NSRange(location: NSNotFound, length: 0),
            state: .active
        ))
    }

    @Test("No active composition is a no-op")
    func inactiveNoOp() {
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: NSRange(location: NSNotFound, length: 0),
            state: .inactive
        ))
    }

    @Test("Malformed overflowing marked range fails closed to finalize")
    func malformedRangeFinalizes() {
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: NSRange(location: Int.max - 1, length: 4),
            state: .active
        ))
    }
}
