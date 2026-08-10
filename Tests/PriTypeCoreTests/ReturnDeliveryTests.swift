import Cocoa
import Testing
@testable import PriTypeCore

// MARK: - Return delivery harness

/// Models the complete result of one IMK keyDown: PriType gets first refusal and,
/// only when it returns false, the host performs its default Return action. This is
/// intentionally one layer above HangulComposerTests, which only observe callbacks
/// and cannot detect a duplicated pass-through Return.
private final class FakeReturnHost: HangulComposerDelegate {
    private(set) var document = ""
    private(set) var markedText = ""
    private(set) var defaultReturnActionCount = 0

    var renderedDocument: String {
        document + markedText
    }

    func insertText(_ text: String) {
        document.append(text)
        markedText = ""
    }

    func setMarkedText(_ text: String) {
        markedText = text
    }

    func beginBackspaceCompositionUpdate() {}
    func endBackspaceCompositionUpdate() {}
    func prepareForSystemBackspaceAfterClearingComposition() -> Bool { false }

    func textBeforeCursor(length: Int) -> String? {
        String(document.suffix(length))
    }

    func replaceTextBeforeCursor(length: Int, with text: String) {
        guard document.count >= length else { return }
        document.removeLast(length)
        document.append(text)
    }

    func performDefaultAction(for event: NSEvent) {
        guard event.keyCode == KeyCode.return || event.keyCode == KeyCode.numpadEnter else {
            return
        }
        defaultReturnActionCount += 1
        document.append("\n")
    }
}

private final class ReturnDeliveryHarness {
    let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
    let host = FakeReturnHost()
    var bundleId = "com.apple.TextEdit"

    private var deduplicator = KeyEventDeduplicator()

    @discardableResult
    func dispatch(_ event: NSEvent) -> Bool {
        let handled: Bool
        let route = deduplicator.route(KeyDownSnapshot(event: event))
        if let immediateHandledResult = route.immediateHandledResult {
            handled = immediateHandledResult
        } else {
            composer.markKeystroke(bundleId: bundleId)
            handled = composer.handle(event, delegate: host)
        }

        if !handled {
            host.performDefaultAction(for: event)
        }
        return handled
    }

    func typeGa(startingAt timestamp: TimeInterval = 1) {
        dispatch(TestEventFactory.keyEvent(char: "r", keyCode: 15, timestamp: timestamp)!)
        dispatch(TestEventFactory.keyEvent(char: "k", keyCode: 40, timestamp: timestamp + 1)!)
    }

    /// A real second physical event is dispatched on a later main-queue turn. Host
    /// re-delivery happens before this boundary, even when it re-wraps NSEvent and
    /// changes the timestamp.
    func advanceDeliveryTurn() {
        deduplicator.endDeliveryTurn(generation: deduplicator.deliveryTurnGeneration)
    }
}

@Suite("Return exactly-once delivery")
struct ReturnDeliveryTests {
    @Test("Fast later-turn Hangul double-tap keeps both physical keystrokes")
    func fastHangulDoubleTap() {
        let pipeline = ReturnDeliveryHarness()
        let first = TestEventFactory.keyEvent(char: "r", keyCode: 15, timestamp: 10)!
        let second = TestEventFactory.keyEvent(char: "r", keyCode: 15, timestamp: 10.02)!

        #expect(pipeline.dispatch(first))
        pipeline.advanceDeliveryTurn()
        #expect(pipeline.dispatch(second))
        #expect(pipeline.host.renderedDocument == "ㄱㄱ")
    }

    @Test("Composed Hangul and ordinary Return reach the final document once")
    func composedOrdinaryReturn() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.typeGa()
        let returnEvent = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10
        )!

        #expect(!pipeline.dispatch(returnEvent))
        #expect(pipeline.dispatch(returnEvent))
        #expect(pipeline.host.document == "가\n")
        #expect(pipeline.host.markedText.isEmpty)
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }

    @Test("Return without composition consumes a same-turn re-wrap with a changed timestamp")
    func ordinaryReturnWithoutComposition() {
        let pipeline = ReturnDeliveryHarness()
        let first = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return, timestamp: 10)!
        let rewrapped = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return, timestamp: 10.02)!

        #expect(!pipeline.dispatch(first))
        #expect(pipeline.dispatch(rewrapped))
        #expect(pipeline.host.document == "\n")
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }

    @Test("Numpad Enter commits Hangul and reaches the final document once")
    func numpadEnter() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.typeGa()
        let enterEvent = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.numpadEnter,
            timestamp: 10
        )!

        #expect(!pipeline.dispatch(enterEvent))
        #expect(pipeline.dispatch(enterEvent))
        #expect(pipeline.host.document == "가\n")
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }

    @Test("Empty-character Return still commits Hangul before host default action")
    func emptyCharactersReturn() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.typeGa()
        let returnEvent = TestEventFactory.keyEvent(
            char: "",
            keyCode: KeyCode.return,
            timestamp: 10
        )!

        #expect(!pipeline.dispatch(returnEvent))
        #expect(pipeline.dispatch(returnEvent))
        #expect(pipeline.host.document == "가\n")
        #expect(pipeline.host.markedText.isEmpty)
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }

    @Test("Fast physical Return double-tap is not mistaken for re-delivery")
    func fastDoubleTap() {
        let pipeline = ReturnDeliveryHarness()
        let first = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return, timestamp: 10)!
        let second = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return, timestamp: 10.02)!

        #expect(!pipeline.dispatch(first))
        pipeline.advanceDeliveryTurn()
        #expect(!pipeline.dispatch(second))
        #expect(pipeline.host.document == "\n\n")
        #expect(pipeline.host.defaultReturnActionCount == 2)
    }

    @Test("Hardware auto-repeat remains a real host action")
    func autoRepeat() {
        let pipeline = ReturnDeliveryHarness()
        let first = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return, timestamp: 10)!
        let repeated = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10,
            isARepeat: true
        )!

        #expect(!pipeline.dispatch(first))
        #expect(!pipeline.dispatch(repeated))
        #expect(pipeline.host.document == "\n\n")
        #expect(pipeline.host.defaultReturnActionCount == 2)
    }

    @Test("Modifier change distinguishes a new physical Return")
    func modifierDifference() {
        let pipeline = ReturnDeliveryHarness()
        let first = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return, timestamp: 10)!
        let shifted = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            modifiers: [.shift],
            timestamp: 10
        )!

        #expect(!pipeline.dispatch(first))
        #expect(!pipeline.dispatch(shifted))
        #expect(pipeline.host.document == "\n\n")
        #expect(pipeline.host.defaultReturnActionCount == 2)
    }

    @Test("GoodNotes direct newline remains exactly once")
    func goodNotesCompatibility() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.bundleId = "com.goodnotesapp.x"
        pipeline.typeGa()
        let returnEvent = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return, timestamp: 10)!

        #expect(pipeline.dispatch(returnEvent))
        #expect(pipeline.dispatch(returnEvent))
        #expect(pipeline.host.document == "가\n")
        #expect(pipeline.host.defaultReturnActionCount == 0)
    }

    @Test("Hermes composition Return remains consumed before the next physical Return")
    func hermesCompatibility() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.bundleId = "com.nousresearch.hermes"
        pipeline.typeGa()
        let compositionReturn = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10
        )!

        #expect(pipeline.dispatch(compositionReturn))
        #expect(pipeline.dispatch(compositionReturn))
        #expect(pipeline.host.document == "가")

        pipeline.advanceDeliveryTurn()
        let nextPhysicalReturn = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10.02
        )!
        #expect(!pipeline.dispatch(nextPhysicalReturn))
        #expect(pipeline.host.document == "가\n")
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }
}
