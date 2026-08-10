import Foundation
import Testing
@testable import PriTypeCore

@Suite("Input session finalize")
struct InputSessionFinalizeTests {
    private func makeDirectFallbackSession() -> (InputSession, HangulComposer, FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        client.bundleID = "com.nousresearch.hermes"
        client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
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

        #expect(session.finalize(reason: .mouseCommit))
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.0 == "")
        #expect(client.insertCalls.first?.1 == NSRange(location: 0, length: 1))
    }
}

@Suite("Mouse composition policy")
struct MouseCompositionPolicyTests {
    @Test("Click outside marked range finalizes")
    func outsideFinalizes() {
        let marked = NSRange(location: 10, length: 2)
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 9, markedRange: marked, hasActiveComposition: true))
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 12, markedRange: marked, hasActiveComposition: true))
    }

    @Test("Click inside marked range keeps composition")
    func insideKeepsComposition() {
        let marked = NSRange(location: 10, length: 2)
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 10, markedRange: marked, hasActiveComposition: true))
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 11, markedRange: marked, hasActiveComposition: true))
    }

    @Test("Direct insertion without marked range finalizes on any click")
    func directInsertionFinalizes() {
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 42,
            markedRange: NSRange(location: NSNotFound, length: 0),
            hasActiveComposition: true
        ))
    }

    @Test("No active composition is a no-op")
    func inactiveNoOp() {
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: NSRange(location: NSNotFound, length: 0),
            hasActiveComposition: false
        ))
    }

    @Test("Malformed overflowing marked range fails closed to finalize")
    func malformedRangeFinalizes() {
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: NSRange(location: Int.max - 1, length: 4),
            hasActiveComposition: true
        ))
    }
}
