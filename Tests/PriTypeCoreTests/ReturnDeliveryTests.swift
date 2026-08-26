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
    private var scheduledReturn: UInt16?
    private(set) var scheduledReturnModifierFlags: UInt?
    var returnSchedulingSucceeds = true

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

    func tryScheduleHostKey(keyCode: UInt16, modifierFlags: UInt) -> Bool {
        guard returnSchedulingSucceeds else { return false }
        scheduledReturn = keyCode
        scheduledReturnModifierFlags = modifierFlags
        return true
    }

    func deliverScheduledReturn() {
        guard let keyCode = scheduledReturn else { return }
        scheduledReturn = nil
        scheduledReturnModifierFlags = nil
        guard keyCode == KeyCode.return || keyCode == KeyCode.numpadEnter else { return }
        defaultReturnActionCount += 1
        document.append("\n")
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
    var usesBlinkNativeTextClient = false

    private var deduplicator = KeyEventDeduplicator()

    @discardableResult
    func dispatch(_ event: NSEvent) -> Bool {
        let handled: Bool
        let route = deduplicator.route(KeyDownSnapshot(event: event))
        if let immediateHandledResult = route.immediateHandledResult {
            handled = immediateHandledResult
        } else {
            composer.markKeystroke(
                bundleId: bundleId,
                usesBlinkNativeTextClient: usesBlinkNativeTextClient
            )
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

    func typeBangSik(startingAt timestamp: TimeInterval = 1) {
        for (offset, input) in [
            (0.0, ("q", UInt16(12))), (1.0, ("k", UInt16(40))),
            (2.0, ("d", UInt16(2))), (3.0, ("t", UInt16(17))),
            (4.0, ("l", UInt16(37))), (5.0, ("r", UInt16(15)))
        ] {
            dispatch(TestEventFactory.keyEvent(
                char: input.0,
                keyCode: input.1,
                timestamp: timestamp + offset
            )!)
        }
    }

    /// A real second physical event is dispatched on a later main-queue turn. Host
    /// re-delivery happens before this boundary, even when it re-wraps NSEvent and
    /// changes the timestamp.
    func advanceDeliveryTurn() {
        deduplicator.endDeliveryTurn(generation: deduplicator.deliveryTurnGeneration)
    }
}

/// Models a Blink editor with committed text on both sides of the caret. The
/// marked syllable is rendered at the caret but is not part of the document until
/// PriType commits it.
private final class FakeForwardDeleteHost: HangulComposerDelegate {
    private(set) var document = "가나다라"
    private(set) var markedText = ""
    private(set) var caretOffset = 2
    private(set) var scheduledForwardDeleteCount = 0

    var renderedDocument: String {
        let caret = document.index(document.startIndex, offsetBy: caretOffset)
        return String(document[..<caret]) + markedText + String(document[caret...])
    }

    func insertText(_ text: String) {
        let caret = document.index(document.startIndex, offsetBy: caretOffset)
        document.insert(contentsOf: text, at: caret)
        caretOffset += text.count
        markedText = ""
    }

    func setMarkedText(_ text: String) {
        markedText = text
    }

    func textBeforeCursor(length: Int) -> String? {
        let available = min(length, caretOffset)
        let caret = document.index(document.startIndex, offsetBy: caretOffset)
        let start = document.index(caret, offsetBy: -available)
        return String(document[start..<caret])
    }

    func replaceTextBeforeCursor(length: Int, with text: String) {
        guard length <= caretOffset else { return }
        let caret = document.index(document.startIndex, offsetBy: caretOffset)
        let start = document.index(caret, offsetBy: -length)
        document.replaceSubrange(start..<caret, with: text)
        caretOffset += text.count - length
    }

    func tryScheduleHostKey(keyCode: UInt16, modifierFlags: UInt) -> Bool {
        guard keyCode == KeyCode.forwardDelete else { return false }
        scheduledForwardDeleteCount += 1
        return true
    }

    func deliverScheduledForwardDelete() {
        guard scheduledForwardDeleteCount > 0 else { return }
        guard caretOffset < document.count else { return }
        let target = document.index(document.startIndex, offsetBy: caretOffset)
        document.remove(at: target)
    }
}

private final class ManualHostKeyReplayDriver {
    private(set) var polls: [DeferredHostKeyPoll] = []
    private(set) var postedEventTypes: [CGEventType] = []
    private(set) var postedBoundaryCount = 0
    var onKeyDown: () -> Void = {}

    var environment: DeferredHostKeyReplayEnvironment {
        DeferredHostKeyReplayEnvironment(
            canReplay: { true },
            makeEvents: { keyCode, modifierFlags in
                DeferredHostKeyDelivery.makeEvents(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags
                )
            },
            scheduleInitial: { [weak self] poll in
                self?.polls.append(poll)
            },
            scheduleRetry: { [weak self] poll in
                self?.polls.append(poll)
            },
            postEvent: { [weak self] event in
                self?.postedEventTypes.append(event.type)
                if event.type == .keyDown {
                    self?.onKeyDown()
                }
            }
        )
    }

    func runNextPoll() throws {
        let poll = try #require(polls.first)
        polls.removeFirst()
        poll.run()
    }

    func recordBoundary(keyCode: UInt16) {
        guard keyCode == KeyCode.forwardDelete else { return }
        postedBoundaryCount += 1
    }
}

private final class DelayedBlinkForwardDeleteClient: FakeIMKTextInput {
    private let exposesLiveMarkedRange: Bool
    private let selectionTracksMarkedText: Bool
    private var markLocation = 2
    private var pendingCommittedText: String?

    init(
        exposesLiveMarkedRange: Bool,
        selectionTracksMarkedText: Bool = true
    ) {
        self.exposesLiveMarkedRange = exposesLiveMarkedRange
        self.selectionTracksMarkedText = selectionTracksMarkedText
        super.init()
        document = "가나다라"
        selectedRangeValue = NSRange(location: 2, length: 0)
    }

    override func insertText(_ string: Any!, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = string as? String ?? ""
        }
        insertCalls.append((text, replacementRange))
        pendingCommittedText = text
    }

    override func setMarkedText(
        _ string: Any!,
        selectionRange: NSRange,
        replacementRange: NSRange
    ) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = string as? String ?? ""
        }
        markCalls.append(text)
        markedText = text
        if text.isEmpty {
            markedRangeValue = NSRange(location: NSNotFound, length: 0)
        } else {
            if markedRangeValue.location == NSNotFound {
                markLocation = selectedRangeValue.location
            }
            markedRangeValue = NSRange(location: markLocation, length: text.utf16.count)
            if selectionTracksMarkedText {
                selectedRangeValue = NSRange(
                    location: markLocation + text.utf16.count,
                    length: 0
                )
            }
        }
    }

    override func markedRange() -> NSRange {
        exposesLiveMarkedRange
            ? markedRangeValue
            : NSRange(location: NSNotFound, length: 0)
    }

    override func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        if exposesLiveMarkedRange {
            return super.attributedSubstring(from: range)
        }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        guard range.location != NSNotFound,
              !overflow,
              end <= document.utf16.count else { return nil }
        let units = Array(document.utf16)[range.location..<end]
        return NSAttributedString(string: String(decoding: units, as: UTF16.self))
    }

    func promotePendingCommit() throws {
        let text = try #require(pendingCommittedText)
        var units = Array(document.utf16)
        units.insert(contentsOf: text.utf16, at: markLocation)
        document = String(decoding: units, as: UTF16.self)
        pendingCommittedText = nil
        selectedRangeValue = NSRange(
            location: markLocation + text.utf16.count,
            length: 0
        )
    }

    func retireMarkedText() {
        markedText = ""
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
    }

    func deleteForwardAtCaret() {
        guard selectedRangeValue.location < document.utf16.count else { return }
        var units = Array(document.utf16)
        units.remove(at: selectedRangeValue.location)
        document = String(decoding: units, as: UTF16.self)
    }
}

private final class RangeForwardDeleteClient: FakeIMKTextInput {
    private var markLocation = 2
    private(set) var orderedHostCalls: [String] = []

    init(followingText: String = "다") {
        super.init()
        document = "가나마\(followingText)라"
        markedText = "마"
        markedRangeValue = NSRange(location: markLocation, length: 1)
        selectedRangeValue = NSRange(location: markLocation + 1, length: 0)
    }

    override func insertText(_ string: Any!, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string
            ?? (string as? String)
            ?? ""
        if replacementRange.location != NSNotFound,
           replacementRange.length > 0 {
            orderedHostCalls.append(
                "delete:\(replacementRange.location):\(replacementRange.length)"
            )
            var units = Array(document.utf16)
            let end = min(
                units.count,
                replacementRange.location + replacementRange.length
            )
            units.removeSubrange(replacementRange.location..<end)
            document = String(decoding: units, as: UTF16.self)
            return
        }
        orderedHostCalls.append("insert:\(text)")
        var units = Array(document.utf16)
        units.replaceSubrange(
            markLocation..<(markLocation + markedRangeValue.length),
            with: text.utf16
        )
        document = String(decoding: units, as: UTF16.self)
        selectedRangeValue = NSRange(
            location: markLocation + text.utf16.count,
            length: 0
        )
        markedText = ""
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
    }
}

@Suite("Return exactly-once delivery")
struct ReturnDeliveryTests {
    @Test("Deferred host key waits for two stable unmarked observations")
    func hostKeyWaitsForStableRetirement() throws {
        var gate = try #require(DeferredCompositionRetirementGate(
            markedRange: NSRange(location: 2, length: 1)
        ))

        #expect(gate.observe(
            markedRange: NSRange(location: 2, length: 1),
            selectedRange: NSRange(location: 3, length: 0)
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .deliver)

    }

    @Test("Deferred host key cancels when its marked range or caret changes")
    func hostKeyCancelsChangedTarget() throws {
        var changedMark = try #require(DeferredCompositionRetirementGate(
            markedRange: NSRange(location: 2, length: 1)
        ))
        var movedCaret = try #require(DeferredCompositionRetirementGate(
            markedRange: NSRange(location: 2, length: 1)
        ))

        #expect(changedMark.observe(
            markedRange: NSRange(location: 4, length: 1),
            selectedRange: NSRange(location: 3, length: 0)
        ) == .cancel)
        #expect(movedCaret.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 4, length: 0)
        ) == .cancel)
    }

    @Test("Shift+Return waits until the last composed syllable is visible")
    func returnWaitsForDocumentPromotion() throws {
        var gate = try #require(DeferredCompositionRetirementGate(
            markedRange: NSRange(location: 2, length: 1),
            targetPolicy: .compositionOnly
        ))

        #expect(gate.committedTextVerificationRange(
            for: NSRange(location: NSNotFound, length: 0)
        ) == NSRange(location: 2, length: 1))
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: NSNotFound, length: 0),
            committedTextIsVisible: false
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 4, length: 0),
            committedTextIsVisible: false
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 4, length: 0),
            committedTextIsVisible: true
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 4, length: 0),
            committedTextIsVisible: true
        ) == .deliver)
    }

    @Test("Forward Delete waits until the committed syllable is visible in Blink")
    func forwardDeleteWaitsForDocumentPromotion() throws {
        var gate = try #require(DeferredCompositionRetirementGate(
            markedRange: NSRange(location: 2, length: 1),
            targetPolicy: .caretAnchored
        ))

        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: false
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .deliver)
    }

    @Test("Forward Delete uses the caret when Blink delays its marked range")
    func forwardDeleteUsesCaretFallbackForDelayedMarkedRange() throws {
        var gate = try #require(DeferredCompositionRetirementGate(
            unavailableMarkedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            expectedCommittedTextLength: 1,
            targetPolicy: .caretAnchored
        ))

        #expect(gate.committedTextVerificationRange(
            for: NSRange(location: 3, length: 0)
        ) == NSRange(location: 2, length: 1))
        #expect(gate.committedTextVerificationRange(
            for: NSRange(location: 4, length: 0)
        ) == NSRange(location: 3, length: 1))
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: false
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .deliver)

        #expect(DeferredCompositionRetirementGate(
            unavailableMarkedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: NSNotFound, length: 0),
            expectedCommittedTextLength: 1,
            targetPolicy: .caretAnchored
        ) == nil)

        let documentStartGate = try #require(DeferredCompositionRetirementGate(
            unavailableMarkedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 0, length: 0),
            expectedCommittedTextLength: 1,
            targetPolicy: .caretAnchored
        ))
        #expect(documentStartGate.committedTextVerificationRange(
            for: NSRange(location: 1, length: 0)
        ) == NSRange(location: 0, length: 1))

        var movedCaretGate = try #require(DeferredCompositionRetirementGate(
            unavailableMarkedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            expectedCommittedTextLength: 1,
            targetPolicy: .caretAnchored
        ))
        #expect(movedCaretGate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 5, length: 0),
            committedTextIsVisible: true
        ) == .cancel)
    }

    @Test("Shift+Return can prepare from the caret while Blink delays its marked range")
    func returnUsesCaretFallbackForDelayedMarkedRange() throws {
        var gate = try #require(DeferredCompositionRetirementGate(
            unavailableMarkedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            expectedCommittedTextLength: 1,
            targetPolicy: .compositionOnly
        ))

        #expect(gate.committedTextVerificationRange(
            for: NSRange(location: 3, length: 0)
        ) == NSRange(location: 2, length: 1))
        #expect(gate.requiresCaretAnchor)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: false
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .wait)
        #expect(gate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            committedTextIsVisible: true
        ) == .deliver)

        var movedCaretGate = try #require(DeferredCompositionRetirementGate(
            unavailableMarkedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0),
            expectedCommittedTextLength: 1,
            targetPolicy: .compositionOnly
        ))
        #expect(movedCaretGate.observe(
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 5, length: 0),
            committedTextIsVisible: true
        ) == .cancel)
    }

    @Test("Deferred host Return keeps its replay marker and key shape")
    func deferredReturnMarker() throws {
        let events = try #require(DeferredHostKeyDelivery.makeEvents(
            keyCode: KeyCode.return,
            modifierFlags: NSEvent.ModifierFlags([.shift, .numericPad]).rawValue
        ))
        let replayedKeyDown = try #require(NSEvent(cgEvent: events.keyDown))
        let physicalReturn = try #require(TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return
        ))

        #expect(DeferredHostKeyDelivery.isReplayedHostKey(replayedKeyDown))
        #expect(DeferredHostKeyDelivery.isReplayedHostKey(events.keyDown))
        #expect(replayedKeyDown.keyCode == KeyCode.return)
        #expect(replayedKeyDown.modifierFlags.contains(.shift))
        #expect(replayedKeyDown.modifierFlags.contains(.numericPad))
        #expect(!DeferredHostKeyDelivery.isReplayedHostKey(physicalReturn))
    }

    @Test("Deferred Forward Delete keeps its replay marker and key shape")
    func deferredForwardDeleteMarker() throws {
        let events = try #require(DeferredHostKeyDelivery.makeEvents(
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue
        ))
        let replayedKeyDown = try #require(NSEvent(cgEvent: events.keyDown))

        #expect(DeferredHostKeyDelivery.isReplayedHostKey(replayedKeyDown))
        #expect(replayedKeyDown.keyCode == KeyCode.forwardDelete)
        #expect(replayedKeyDown.modifierFlags.contains(.function))
    }

    @Test("Approved replay posts key down, key up, then the field boundary")
    func approvedReplayOrdering() throws {
        let events = try #require(DeferredHostKeyDelivery.makeEvents(
            keyCode: KeyCode.return,
            modifierFlags: 0
        ))
        var calls: [String] = []

        DeferredHostKeyDelivery.postApprovedReplay(
            events,
            keyCode: KeyCode.return,
            postEvent: { event in
                switch event.type {
                case .keyDown:
                    calls.append("keyDown")
                case .keyUp:
                    calls.append("keyUp")
                default:
                    calls.append("unexpected")
                }
            },
            didPost: { keyCode in
                calls.append("boundary:\(keyCode)")
            }
        )

        #expect(calls == ["keyDown", "keyUp", "boundary:\(KeyCode.return)"])
    }

    @Test("Blink Forward Delete keeps 마 and deletes the following 다")
    func blinkMidTextForwardDelete() throws {
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration()
        )
        let host = FakeForwardDeleteHost()
        composer.markKeystroke(
            bundleId: "com.google.Chrome",
            usesBlinkNativeTextClient: false
        )

        #expect(composer.handle(
            try #require(TestEventFactory.keyEvent(char: "a", keyCode: 0)),
            delegate: host
        ))
        #expect(composer.handle(
            try #require(TestEventFactory.keyEvent(char: "k", keyCode: 40)),
            delegate: host
        ))
        #expect(host.renderedDocument == "가나마다라")

        let handled = composer.handle(
            try #require(TestEventFactory.keyEvent(
                char: "\u{F728}",
                keyCode: KeyCode.forwardDelete,
                modifiers: [.function]
            )),
            delegate: host
        )

        #expect(handled)
        host.deliverScheduledForwardDelete()
        #expect(host.document == "가나마라")
        #expect(host.markedText.isEmpty)
        #expect(host.caretOffset == 3)
        #expect(host.scheduledForwardDeleteCount == 1)
    }

    @Test(
        "Fast Blink Forward Delete waits for document promotion before deleting 다",
        arguments: [true, false]
    )
    func blinkForwardDeleteWaitsAcrossMarkedRangeTiming(
        exposesLiveMarkedRange: Bool
    ) throws {
        let client = DelayedBlinkForwardDeleteClient(
            exposesLiveMarkedRange: exposesLiveMarkedRange
        )
        let driver = ManualHostKeyReplayDriver()
        driver.onKeyDown = client.deleteForwardAtCaret
        client.setMarkedText(
            "마",
            selectionRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        #expect(client.markedText == "마")

        let scheduled = HostKeyTransaction.schedule(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { true },
            didPost: driver.recordBoundary,
            expectedCommittedText: client.markedText,
            environment: driver.environment
        )
        client.insertText(
            "마",
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        #expect(scheduled)
        #expect(client.document == "가나다라")
        #expect(driver.postedEventTypes.isEmpty)

        try driver.runNextPoll()
        #expect(client.document == "가나다라")
        #expect(driver.postedEventTypes.isEmpty)

        try client.promotePendingCommit()
        try driver.runNextPoll()
        #expect(client.document == "가나마다라")
        #expect(driver.postedEventTypes.isEmpty)

        client.retireMarkedText()
        while driver.postedEventTypes.isEmpty {
            try driver.runNextPoll()
        }

        #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        #expect(driver.postedBoundaryCount == 1)
        #expect(client.document == "가나마라")
        #expect(client.markedText.isEmpty)
        #expect(client.selectedRangeValue == NSRange(location: 3, length: 0))
    }

    @Test(
        "Chrome, Codex, Slack Forward Delete survives a preedit-start caret",
        arguments: [
            "com.google.Chrome",
            "com.openai.codex",
            "com.tinyspeck.slackmacgap"
        ]
    )
    func blinkHostsForwardDeleteAfterLaggingCaret(bundleID: String) throws {
        let client = DelayedBlinkForwardDeleteClient(
            exposesLiveMarkedRange: false,
            selectionTracksMarkedText: false
        )
        client.bundleID = bundleID
        let driver = ManualHostKeyReplayDriver()
        driver.onKeyDown = client.deleteForwardAtCaret
        client.setMarkedText(
            "마",
            selectionRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        let scheduled = HostKeyTransaction.schedule(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { true },
            didPost: driver.recordBoundary,
            expectedCommittedText: client.markedText,
            environment: driver.environment
        )
        client.insertText(
            "마",
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        #expect(scheduled)
        try driver.runNextPoll()
        try client.promotePendingCommit()
        client.retireMarkedText()
        for _ in 0..<3 where driver.postedEventTypes.isEmpty {
            try driver.runNextPoll()
        }

        #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        #expect(driver.postedBoundaryCount == 1)
        #expect(client.document == "가나마라")
        #expect(client.selectedRangeValue == NSRange(location: 3, length: 0))
    }

    @Test(
        "Chrome, Codex, Slack commit and Forward Delete share one host range transaction",
        arguments: [
            "com.google.Chrome",
            "com.openai.codex",
            "com.tinyspeck.slackmacgap"
        ]
    )
    func blinkHostsUseAtomicForwardDeleteRange(bundleID: String) {
        let client = RangeForwardDeleteClient()
        client.bundleID = bundleID
        var boundaryCount = 0

        let handled = HostKeyTransaction.perform(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { true },
            didPost: { keyCode in
                if keyCode == KeyCode.forwardDelete { boundaryCount += 1 }
            },
            expectedCommittedText: "마",
            expectedMarkedRange: NSRange(location: 2, length: 1),
            commit: {
                client.insertText(
                    "마",
                    replacementRange: NSRange(
                        location: NSNotFound,
                        length: NSNotFound
                    )
                )
            }
        )

        #expect(handled)
        #expect(client.orderedHostCalls == [
            "insert:마",
            "delete:3:1"
        ])
        #expect(client.document == "가나마라")
        #expect(client.selectedRangeValue == NSRange(location: 3, length: 0))
        #expect(boundaryCount == 1)
    }

    @Test("Forward Delete removes one composed character after the committed mark")
    func forwardDeleteMeasuresFollowingComposedCharacter() {
        let client = RangeForwardDeleteClient(followingText: "😀")

        let handled = HostKeyTransaction.perform(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { true },
            didPost: { _ in },
            expectedCommittedText: "마",
            expectedMarkedRange: NSRange(location: 2, length: 1),
            commit: {
                client.insertText(
                    "마",
                    replacementRange: NSRange(
                        location: NSNotFound,
                        length: NSNotFound
                    )
                )
            }
        )

        #expect(handled)
        #expect(client.orderedHostCalls == ["insert:마", "delete:3:2"])
        #expect(client.document == "가나마라")
    }

    @Test("Forward Delete never mutates a field whose lease changed during commit")
    func forwardDeleteStopsAfterCommitReentry() {
        let client = RangeForwardDeleteClient()
        var clientWriteIsAllowed = true
        var boundaryCount = 0

        let handled = HostKeyTransaction.perform(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { clientWriteIsAllowed },
            didPost: { _ in boundaryCount += 1 },
            expectedCommittedText: "마",
            expectedMarkedRange: NSRange(location: 2, length: 1),
            commit: {
                client.insertText(
                    "마",
                    replacementRange: NSRange(
                        location: NSNotFound,
                        length: NSNotFound
                    )
                )
                clientWriteIsAllowed = false
            }
        )

        #expect(handled)
        #expect(client.orderedHostCalls == ["insert:마"])
        #expect(client.document == "가나마다라")
        #expect(boundaryCount == 0)
    }

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

    @Test("Blink browser web content consumes composed Return after one newline")
    func blinkWebContentComposedReturn() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.bundleId = "com.google.Chrome"
        pipeline.typeGa()
        let returnEvent = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10
        )!

        #expect(pipeline.dispatch(returnEvent))
        #expect(pipeline.host.document == "가")
        #expect(pipeline.host.defaultReturnActionCount == 0)
        pipeline.host.deliverScheduledReturn()
        #expect(pipeline.host.document == "가\n")
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }

    @Test("Codex composed Shift+Return preserves the last syllable and runs once")
    func codexComposedShiftReturn() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.bundleId = "com.openai.codex"
        pipeline.usesBlinkNativeTextClient = true
        pipeline.typeBangSik()
        let returnEvent = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            modifiers: [.shift],
            timestamp: 10
        )!

        #expect(pipeline.dispatch(returnEvent))
        #expect(pipeline.host.document == "방식")
        #expect(pipeline.host.defaultReturnActionCount == 0)
        #expect(
            NSEvent.ModifierFlags(rawValue: pipeline.host.scheduledReturnModifierFlags ?? 0)
                .contains(.shift)
        )
        pipeline.host.deliverScheduledReturn()
        #expect(pipeline.host.document == "방식\n")
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }

    @Test("Blink browser native fields keep the host Return")
    func blinkNativeFieldComposedReturn() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.bundleId = "com.google.Chrome"
        pipeline.usesBlinkNativeTextClient = true
        pipeline.typeGa()
        let returnEvent = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10
        )!

        #expect(!pipeline.dispatch(returnEvent))
        #expect(pipeline.host.document == "가\n")
        #expect(pipeline.host.defaultReturnActionCount == 1)
    }

    @Test("Blink web content keeps the original Return when replay is unavailable")
    func blinkWebContentReplayUnavailable() {
        let pipeline = ReturnDeliveryHarness()
        pipeline.bundleId = "com.google.Chrome"
        pipeline.host.returnSchedulingSucceeds = false
        pipeline.typeGa()
        let returnEvent = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10
        )!

        #expect(!pipeline.dispatch(returnEvent))
        #expect(pipeline.host.document == "가\n")
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
        let firstRepeatTick = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10.01,
            isARepeat: true
        )!
        let rewrappedFirstTick = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10.01,
            isARepeat: true
        )!
        let secondRepeatTick = TestEventFactory.keyEvent(
            char: "\r",
            keyCode: KeyCode.return,
            timestamp: 10.02,
            isARepeat: true
        )!

        #expect(!pipeline.dispatch(first))
        #expect(!pipeline.dispatch(firstRepeatTick))
        #expect(pipeline.dispatch(rewrappedFirstTick))
        #expect(!pipeline.dispatch(secondRepeatTick))
        #expect(pipeline.host.document == "\n\n\n")
        #expect(pipeline.host.defaultReturnActionCount == 3)
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
