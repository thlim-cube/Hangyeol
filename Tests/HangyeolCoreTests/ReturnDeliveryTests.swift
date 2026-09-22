import Cocoa
import Testing
@testable import HangyeolCore

@Suite("Session-authorized deferred host keys")
struct DeferredHostKeySessionTests {
    enum Boundary: CaseIterable {
        case unchanged, fieldChanged, secureThenNonSecure
    }

    @Test("Only a continuously authorized session delivers its queued host key",
          arguments: [KeyCode.return, KeyCode.forwardDelete, KeyCode.leftArrow], Boundary.allCases)
    func deferredKeyAfterSessionBoundary(keyCode: UInt16, boundary: Boundary) throws {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let context = ClientContext(
            bundleId: client.bundleID,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: true
        )
        let composer = HangulComposer(
            statusBar: MockStatusBar(), configuration: MockConfiguration()
        )
        let session = InputSession(client: client, context: context, composer: composer)
        session.prepareForNonSecureClientWrites()
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "a", keyCode: 0)!, delegate: session.adapter
        ))
        #expect(client.markedText == "ㅁ")
        let driver = ManualHostKeyReplayDriver()
        let captured = session.adapter.captureDeferredClientWriteValidator()
        #expect(HostKeyTransaction.schedule(
            client: client,
            keyCode: keyCode,
            modifierFlags: 0,
            isClientWriteAllowed: captured,
            didPost: { _ in },
            expectedCommittedText: client.markedText,
            environment: driver.environment
        ))
        composer.forceCommit(delegate: session.adapter)
        #expect(client.document == "ㅁ")
        #expect(driver.postedEventTypes.isEmpty)

        switch boundary {
        case .unchanged:
            break
        case .fieldChanged:
            session.markContextStale()
            session.refreshContext(context, fieldIdentityMayHaveChanged: true)
            session.prepareForNonSecureClientWrites()
        case .secureThenNonSecure:
            session.discardForSecureInput()
            session.prepareForNonSecureClientWrites()
        }
        #expect(session.adapter.canWriteToClient())
        #expect(session.adapter.captureDeferredClientWriteValidator()())

        for _ in 0..<3 where !driver.polls.isEmpty {
            try driver.runNextPoll()
        }
        #expect(driver.polls.isEmpty)
        #expect(driver.postedEventTypes == (
            boundary == .unchanged ? [.keyDown, .keyUp] : []
        ))
        // The driver records events only; no key is posted to a real application.
        #expect(client.document == "ㅁ")
    }
}

// MARK: - Return delivery harness

/// Models the complete result of one IMK keyDown: Hangyeol gets first refusal and,
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
/// Hangyeol commits it.
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
        performDefaultForwardDelete()
    }

    func performDefaultForwardDelete() {
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
    private(set) var rendererSettlementCount = 0
    private(set) var postedKeyCodes: [UInt16] = []
    private(set) var postedModifierFlags: [UInt64] = []

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
            scheduleRendererSettlement: { [weak self] poll in
                self?.rendererSettlementCount += 1
                self?.polls.append(poll)
            },
            postEvent: { [weak self] event in
                self?.postedEventTypes.append(event.type)
                self?.postedKeyCodes.append(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
                self?.postedModifierFlags.append(event.flags.rawValue)
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
    var delaysCanonicalCommits = true

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
        if !delaysCanonicalCommits {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = string as? String ?? ""
        }
        insertCalls.append((text, replacementRange))
        if replacementRange.location != NSNotFound,
           replacementRange.length > 0 {
            var units = Array(document.utf16)
            let end = min(
                units.count,
                replacementRange.location + replacementRange.length
            )
            units.removeSubrange(replacementRange.location..<end)
            document = String(decoding: units, as: UTF16.self)
            selectedRangeValue = NSRange(
                location: replacementRange.location,
                length: 0
            )
            return
        }
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

/// Uses the production marked-text adapter and retirement transaction, replacing
/// only event posting/scheduling with the existing deterministic driver.
private final class NavigationTransactionAdapter: HangulComposerDelegate {
    let adapter: MarkedTextAdapter
    let driver: ManualHostKeyReplayDriver
    var canSchedule = true

    init(client: FakeIMKTextInput, driver: ManualHostKeyReplayDriver) {
        adapter = MarkedTextAdapter(client: client, hostSurface: .blinkWeb)
        self.driver = driver
    }

    func insertText(_ text: String) { adapter.insertText(text) }
    func setMarkedText(_ text: String) { adapter.setMarkedText(text) }
    func textBeforeCursor(length: Int) -> String? { adapter.textBeforeCursor(length: length) }
    func replaceTextBeforeCursor(length: Int, with text: String) {
        adapter.replaceTextBeforeCursor(length: length, with: text)
    }

    func tryPerformHostKeyTransaction(
        keyCode: UInt16, modifierFlags: UInt, commit: () -> Void
    ) -> Bool {
        guard canSchedule else { return false }
        return HostKeyTransaction.perform(
            client: adapter.client, keyCode: keyCode, modifierFlags: modifierFlags,
            isClientWriteAllowed: adapter.captureDeferredClientWriteValidator(),
            didPost: { _ in }, expectedCommittedText: adapter.hostTransactionMarkedText,
            expectedMarkedRange: adapter.hostTransactionMarkedRange,
            environment: driver.environment, commit: commit
        )
    }
}

private final class RangeForwardDeleteClient: FakeIMKTextInput {
    private var markLocation = 2
    private(set) var orderedHostCalls: [String] = []
    var ignoresCanonicalCommits = false

    init(followingText: String = "다", initialMarkedText: String = "마") {
        super.init()
        document = "가나\(initialMarkedText)\(followingText)라"
        markedText = initialMarkedText
        markedRangeValue = NSRange(
            location: initialMarkedText.isEmpty ? NSNotFound : markLocation,
            length: initialMarkedText.utf16.count
        )
        selectedRangeValue = NSRange(
            location: markLocation + initialMarkedText.utf16.count, length: 0
        )
    }

    override func setMarkedText(
        _ string: Any!, selectionRange: NSRange, replacementRange: NSRange
    ) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let previousLength = markedRangeValue.location == NSNotFound ? 0 : markedRangeValue.length
        var units = Array(document.utf16)
        units.replaceSubrange(markLocation..<(markLocation + previousLength), with: text.utf16)
        document = String(decoding: units, as: UTF16.self)
        markedText = text
        markedRangeValue = NSRange(
            location: text.isEmpty ? NSNotFound : markLocation, length: text.utf16.count
        )
        selectedRangeValue = NSRange(location: markLocation + selectionRange.location, length: 0)
        markCalls.append(text)
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
        guard !ignoresCanonicalCommits else { return }
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

    /// The reported host behavior: a raw Delete cancels a still-live composition;
    /// once composition has ended, the same key deletes the following character.
    func performDefaultForwardDelete() {
        let range = markedRangeValue.location != NSNotFound
            ? markedRangeValue
            : NSRange(location: selectedRangeValue.location, length: 1)
        guard NSMaxRange(range) <= document.utf16.count else { return }
        var units = Array(document.utf16)
        units.removeSubrange(range.location..<NSMaxRange(range))
        document = String(decoding: units, as: UTF16.self)
        selectedRangeValue = NSRange(location: range.location, length: 0)
        markedText = ""
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
    }
}

/// Electron can read text while reporting zero document length, and ignores
/// an empty insertion even with an explicit replacement range.
private final class LengthlessForwardDeleteClient: FakeIMKTextInput {
    override func length() -> Int { 0 }
    override func insertText(_ string: Any!, replacementRange: NSRange) {
        if (string as? String) == "" { return }
        super.insertText(string, replacementRange: replacementRange)
        selectedRangeValue = NSRange(location: replacementRange.location + ((string as? String)?.utf16.count ?? 0), length: 0)
    }
}

@Suite("Return exactly-once delivery")
struct ReturnDeliveryTests {
    @Test("Navigation replay keeps native arrow characters, modifiers, and its recursion marker",
          arguments: [
              (KeyCode.leftArrow, UInt32(0xF702)),
              (KeyCode.rightArrow, UInt32(0xF703)),
              (KeyCode.upArrow, UInt32(0xF700)),
              (KeyCode.downArrow, UInt32(0xF701))
          ])
    func navigationReplayKeepsNativeEvent(keyCode: UInt16, scalar: UInt32) throws {
        let flags: NSEvent.ModifierFlags = [.option, .shift, .function, .numericPad]
        let pair = try #require(DeferredHostKeyDelivery.makeEvents(
            keyCode: keyCode, modifierFlags: flags.rawValue
        ))
        for event in [pair.keyDown, pair.keyUp] {
            let native = try #require(NSEvent(cgEvent: event))
            #expect(native.keyCode == keyCode)
            #expect(native.modifierFlags == flags)
            #expect(native.characters?.unicodeScalars.map(\.value) == [scalar])
            #expect(DeferredHostKeyDelivery.isReplayedHostKey(native))
        }
    }

    @Test("Navigation cannot schedule without owned marked text")
    func navigationRequiresOwnedMarkedText() {
        let client = FakeIMKTextInput()
        client.markedRangeValue = NSRange(location: 0, length: 1)
        client.selectedRangeValue = NSRange(location: 1, length: 0)
        let driver = ManualHostKeyReplayDriver()
        var commits = 0
        #expect(!HostKeyTransaction.perform(
            client: client, keyCode: KeyCode.leftArrow,
            modifierFlags: NSEvent.ModifierFlags.command.rawValue,
            isClientWriteAllowed: { true }, didPost: { _ in },
            expectedCommittedText: nil, environment: driver.environment,
            commit: { commits += 1 }
        ))
        #expect(commits == 0)
        #expect(driver.polls.isEmpty)
    }

    @Test("Blink navigation preserves the last marked syllable before forwarding the original shortcut",
          arguments: [
              (KeyCode.leftArrow, NSEvent.ModifierFlags.command),
              (KeyCode.leftArrow, .option),
              (KeyCode.leftArrow, NSEvent.ModifierFlags([.command, .shift])),
              (KeyCode.rightArrow, NSEvent.ModifierFlags([.option, .shift])),
              (KeyCode.home, NSEvent.ModifierFlags()),
              (KeyCode.end, .shift),
              (KeyCode.pageUp, NSEvent.ModifierFlags()),
              (KeyCode.pageDown, .shift)
          ], [true, false])
    func blinkNavigationWaitsForMarkedText(
        shortcut: (UInt16, NSEvent.ModifierFlags), selectionTracksMarkedText: Bool
    ) throws {
        let (keyCode, flags) = shortcut
        let client = DelayedBlinkForwardDeleteClient(
            exposesLiveMarkedRange: true, selectionTracksMarkedText: selectionTracksMarkedText
        )
        client.bundleID = "com.google.Chrome"
        client.document = ""
        client.selectedRangeValue = NSRange(location: 0, length: 0)
        client.delaysCanonicalCommits = false
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        composer.markKeystroke(bundleId: client.bundleID, usesBlinkNativeTextClient: false)
        let driver = ManualHostKeyReplayDriver()
        let adapter = NavigationTransactionAdapter(client: client, driver: driver)
        for (char, key) in [("d", 2), ("k", 40), ("s", 1), ("s", 1), ("u", 32), ("d", 2)] {
            #expect(composer.handle(try #require(TestEventFactory.keyEvent(
                char: char, keyCode: UInt16(key)
            )), delegate: adapter))
        }
        #expect(client.document == "안")
        #expect(client.markedText == "녕")
        client.delaysCanonicalCommits = true
        // Characterizes the user's reported corruption if a control-key payload
        // reaches the host before the last syllable retires. This is a model of
        // that report, not proof of Chrome's internal cause.
        driver.onKeyDown = {
            if !client.markedText.isEmpty { client.document = "안\u{001C}" }
            else { client.selectedRangeValue = NSRange(location: 0, length: 0) }
        }
        let handled = composer.handle(try #require(TestEventFactory.keyEvent(
            char: "\u{001C}", keyCode: keyCode, modifiers: flags
        )), delegate: adapter)
        if !handled { driver.onKeyDown() }
        #expect(handled)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "안")
        #expect(driver.postedEventTypes.isEmpty)
        try driver.runNextPoll()
        #expect(driver.postedEventTypes.isEmpty)
        try client.promotePendingCommit()
        try driver.runNextPoll()
        #expect(driver.postedEventTypes.isEmpty)
        client.retireMarkedText()
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(client.document == "안녕")
        #expect(client.selectedRangeValue == NSRange(location: 0, length: 0))
        #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        #expect(driver.postedKeyCodes == [keyCode, keyCode])
        #expect(driver.postedModifierFlags == [UInt64(flags.rawValue), UInt64(flags.rawValue)])
        #expect(driver.rendererSettlementCount == 0)
    }

    @Test("Navigation retires only a freshly authorized remaining mark after modifier finalization")
    func remainingMarkNavigationAfterFinalize() throws {
        let client = RangeForwardDeleteClient(followingText: "", initialMarkedText: "")
        client.bundleID = "com.google.Chrome"
        let context = ClientContext(bundleId: client.bundleID, hasTextInputCapability: true,
                                    isLikelyDesktopArea: false, documentAccessSafe: true)
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        composer.markKeystroke(bundleId: client.bundleID, usesBlinkNativeTextClient: false)
        let session = InputSession(client: client, context: context, composer: composer)
        session.prepareForNonSecureClientWrites()
        #expect(composer.handle(try #require(TestEventFactory.keyEvent(char: "a", keyCode: 0)),
                                delegate: session.adapter))
        client.ignoresCanonicalCommits = true
        #expect(session.finalize(reason: .hostShortcut))
        session.finishHostCommitBoundary()
        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㅁ")
        session.refreshContext(context, fieldIdentityMayHaveChanged: true)
        session.prepareForNonSecureClientWrites()
        client.ignoresCanonicalCommits = false
        let driver = ManualHostKeyReplayDriver()
        #expect(session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "\u{001C}", keyCode: KeyCode.leftArrow, modifiers: [.command, .shift]
        )), hostKeyEnvironment: driver.environment))
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(client.document == "가나ㅁ라")
        #expect(client.markedText.isEmpty)
        #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        #expect(driver.postedModifierFlags == Array(repeating: UInt64(
            NSEvent.ModifierFlags([.command, .shift]).rawValue), count: 2))
        #expect(driver.rendererSettlementCount == 0)
    }

    @Test("Queued navigation cancels when its caret or field changes",
          arguments: ["caret", "selection", "field"])
    func navigationCancelsChangedTarget(change: String) throws {
        let (session, client) = remainingMarkSession()
        let driver = ManualHostKeyReplayDriver()
        #expect(session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "", keyCode: KeyCode.leftArrow, modifiers: .option
        )), hostKeyEnvironment: driver.environment))
        if change == "field" { session.markContextStale() }
        else { client.selectedRangeValue = NSRange(location: 0, length: change == "selection" ? 1 : 0) }
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(client.document == "가나마다라")
        #expect(driver.postedEventTypes.isEmpty)
        #expect(driver.rendererSettlementCount == 0)
    }

    @Test("Native navigation and unavailable replay retain commit and host pass-through",
          arguments: ["native", "unavailable"])
    func navigationKeepsPassThroughWithoutTransaction(scenario: String) throws {
        let client = FakeIMKTextInput()
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        composer.markKeystroke(bundleId: scenario == "native" ? "com.apple.TextEdit" : "com.google.Chrome",
                               usesBlinkNativeTextClient: false)
        let driver = ManualHostKeyReplayDriver()
        let adapter = NavigationTransactionAdapter(client: client, driver: driver)
        adapter.canSchedule = scenario != "unavailable"
        #expect(composer.handle(try #require(TestEventFactory.keyEvent(char: "a", keyCode: 0)), delegate: adapter))
        #expect(!composer.handle(try #require(TestEventFactory.keyEvent(
            char: "\u{001C}", keyCode: KeyCode.leftArrow, modifiers: .command
        )), delegate: adapter))
        #expect(client.document == "ㅁ")
        #expect(client.markedText.isEmpty)
        #expect(driver.polls.isEmpty)
        #expect(driver.postedEventTypes.isEmpty)
    }

    @Test("Lengthless Electron deletes the following grapheme without replaying a destructive key",
          arguments: ["글", "", "👨‍👩‍👧‍👦", "e\u{301}"], [false, true])
    func lengthlessElectronForwardDelete(following: String, staleMark: Bool) throws {
        let client = LengthlessForwardDeleteClient()
        client.document = "한중" + following
        client.markedRangeValue = NSRange(location: staleMark ? 2 : 1, length: 1)
        client.markedText = "중"
        client.selectedRangeValue = NSRange(location: 1, length: 1)
        let driver = ManualHostKeyReplayDriver()
        driver.onKeyDown = {
            // Observed in Claude: IMK reports retirement, but a replayed Delete
            // still removes the preceding composition in the renderer.
            client.document = "한" + following
        }
        #expect(HostKeyTransaction.perform(
            client: client, keyCode: KeyCode.forwardDelete, modifierFlags: 0,
            isClientWriteAllowed: { true }, didPost: driver.recordBoundary,
            expectedCommittedText: "중", expectedMarkedRange: NSRange(location: 1, length: 1),
            environment: driver.environment,
            commit: {
                client.markedRangeValue = NSRange(location: NSNotFound, length: NSNotFound)
                client.selectedRangeValue = NSRange(location: 2, length: 0)
            }
        ))
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(client.document == "한중")
        #expect(client.selectedRangeValue == NSRange(location: 2, length: 0))
        #expect(driver.postedEventTypes.isEmpty)
    }

    @Test("Lengthless replacement stops when ownership, caret, or grapheme proof fails",
          arguments: ["revoked", "caret-moved", "oversized-grapheme"])
    func lengthlessReplacementRejectsUnverifiedTarget(reason: String) throws {
        let client = LengthlessForwardDeleteClient()
        let following = reason == "oversized-grapheme" ? "e" + String(repeating: "\u{301}", count: 70) : "글"
        let original = "한중" + following
        client.document = original
        client.markedText = "중"
        client.markedRangeValue = NSRange(location: 1, length: 1)
        client.selectedRangeValue = client.markedRangeValue
        let driver = ManualHostKeyReplayDriver()
        var allowed = true
        #expect(HostKeyTransaction.perform(
            client: client, keyCode: KeyCode.forwardDelete, modifierFlags: 0,
            isClientWriteAllowed: { allowed }, didPost: driver.recordBoundary,
            expectedCommittedText: "중", expectedMarkedRange: client.markedRangeValue,
            environment: driver.environment, commit: {
                client.markedRangeValue = NSRange(location: NSNotFound, length: NSNotFound)
                client.selectedRangeValue = NSRange(location: 2, length: 0)
            }
        ))
        var reads = 0
        client.onAttributedSubstring = {
            reads += 1
            // The first two reads prove retirement. Revoke during prefix probing.
            if reads == 3 {
                if reason == "revoked" { allowed = false }
                if reason == "caret-moved" { client.selectedRangeValue = NSRange(location: 0, length: 0) }
            }
        }
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(client.document == original)
        #expect(client.insertCalls.isEmpty)
        #expect(driver.postedEventTypes.isEmpty)
    }

    @Test("Codex composition survives fast host keys before selection collapse",
          arguments: ["return", "middle-delete", "end-delete"], ["confirmed", "provisional", "missing"])
    func selectedCompositionRemainsVisibleBeforeRetirement(scenario: String, rangeEvidence: String) throws {
        let client = FakeIMKTextInput()
        client.bundleID = "com.openai.codex"
        let deleting = scenario != "return"
        let original = scenario == "return" ? "한글" : scenario == "middle-delete" ? "한중글" : "하나"
        let expected = scenario == "return" ? "한글\n" : scenario == "middle-delete" ? "한중" : "하나"
        client.document = original
        let ownedRange = NSRange(location: 1, length: 1)
        client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
        client.selectedRangeValue = ownedRange
        let driver = ManualHostKeyReplayDriver()
        driver.onKeyDown = {
            let selection = client.selectedRangeValue
            if deleting && selection.length == 0 && selection.location == client.document.utf16.count { return }
            let range = selection.length > 0 ? selection
                : NSRange(location: selection.location, length: deleting ? 1 : 0)
            client.document = (client.document as NSString).replacingCharacters(
                in: range, with: deleting ? "" : "\n")
        }
        let handled = HostKeyTransaction.perform(
            client: client, keyCode: deleting ? KeyCode.forwardDelete : KeyCode.return,
            modifierFlags: deleting ? 0 : NSEvent.ModifierFlags.shift.rawValue,
            isClientWriteAllowed: { true }, didPost: { _ in },
            expectedCommittedText: String(original[original.index(after: original.startIndex)]),
            expectedMarkedRange: rangeEvidence == "missing" ? nil : ownedRange,
            expectedMarkedRangeIsConfirmed: rangeEvidence == "confirmed",
            environment: driver.environment,
            commit: {} // Host acknowledges commit; selection collapse is asynchronous.
        )
        #expect(handled)
        if !handled { driver.onKeyDown() } // The original host key would delete the selection.
        for _ in 0..<3 where !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(driver.postedEventTypes.isEmpty)
        #expect(client.document == original)
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        if !(deleting && rangeEvidence != "missing") {
            #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        }
        #expect(client.document == expected)
    }

    @Test("Selection-only composition needs matching readable text and continuous ownership",
          arguments: ["unreadable", "different-text", "different-length", "revoked"])
    func selectionOnlyCompositionRejectsUnverifiedText(reason: String) {
        let client = FakeIMKTextInput()
        client.document = reason == "different-text" ? "하가" : "하나"
        client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
        client.selectedRangeValue = NSRange(location: 1, length: reason == "different-length" ? 2 : 1)
        client.attributedSubstringUnavailable = reason == "unreadable"
        var allowed = true
        if reason == "revoked" { client.onAttributedSubstring = { allowed = false } }
        let driver = ManualHostKeyReplayDriver()
        var commits = 0
        #expect(!HostKeyTransaction.perform(
            client: client, keyCode: KeyCode.forwardDelete, modifierFlags: 0,
            isClientWriteAllowed: { allowed }, didPost: { _ in },
            expectedCommittedText: "나", environment: driver.environment,
            commit: { commits += 1 }
        ))
        #expect(commits == 0)
        #expect(driver.polls.isEmpty)
        #expect(driver.postedEventTypes.isEmpty)
    }

    @Test("Captured composition survives an unavailable live range before Shift+Return or Delete",
          arguments: [KeyCode.return, KeyCode.forwardDelete])
    func capturedRangeSurvivesRendererGap(keyCode: UInt16) throws {
        let client = FakeIMKTextInput()
        let deleting = keyCode == KeyCode.forwardDelete
        client.document = deleting ? "때이에" : "때에"
        let range = NSRange(location: 1, length: 1)
        client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
        client.selectedRangeValue = range // Blink exposes the preedit as selection.
        client.attributedSubstringUnavailable = true
        let driver = ManualHostKeyReplayDriver()
        var commits = 0
        var rendererStillComposing = true
        driver.onKeyDown = {
            let replacement = rendererStillComposing
                ? range
                : NSRange(location: client.selectedRangeValue.location, length: deleting ? 1 : 0)
            client.document = (client.document as NSString).replacingCharacters(
                in: replacement, with: deleting ? "" : "\n"
            )
        }
        let handled = HostKeyTransaction.perform(
            client: client, keyCode: keyCode,
            modifierFlags: deleting ? 0 : NSEvent.ModifierFlags.shift.rawValue,
            isClientWriteAllowed: { true }, didPost: { _ in },
            expectedCommittedText: deleting ? "이" : "에",
            expectedMarkedRange: range,
            environment: driver.environment,
            commit: { commits += 1 }
        )
        #expect(handled) // Never pass the original key into the live preedit.
        #expect(commits == 1)
        guard handled else { return }
        try driver.runNextPoll()
        #expect(driver.postedEventTypes.isEmpty)
        client.attributedSubstringUnavailable = false
        rendererStillComposing = false
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        #expect(client.document == (deleting ? "때이" : "때에\n"))
    }

    @Test("Captured range cannot authorize replay after lost ownership or changed text",
          arguments: ["unconfirmed", "revoked", "text_changed"])
    func capturedRangeRejectsUnprovenReplay(boundary: String) throws {
        let client = FakeIMKTextInput()
        client.document = "때이에"
        client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
        client.selectedRangeValue = NSRange(location: 1, length: 1)
        client.attributedSubstringUnavailable = true
        let driver = ManualHostKeyReplayDriver()
        var allowed = true
        var commits = 0
        let handled = HostKeyTransaction.perform(
            client: client, keyCode: KeyCode.forwardDelete, modifierFlags: 0,
            isClientWriteAllowed: { allowed }, didPost: { _ in },
            expectedCommittedText: "이", expectedMarkedRange: NSRange(location: 1, length: 1),
            expectedMarkedRangeIsConfirmed: boundary != "unconfirmed",
            environment: driver.environment, commit: { commits += 1 }
        )
        #expect(handled == (boundary != "unconfirmed"))
        #expect(commits == (boundary == "unconfirmed" ? 0 : 1))
        allowed = boundary != "revoked"
        client.attributedSubstringUnavailable = false
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        if boundary == "text_changed" { client.document = "때가에" }
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(driver.postedEventTypes.isEmpty)
    }

    @Test("Window round-trip Forward Delete keeps 마 and removes the following 다",
          arguments: [false, true], ["com.openai.codex", "com.google.Chrome", "com.tinyspeck.slackmacgap"])
    func forwardDeleteAfterWindowRoundTrip(ignoredFocusCommit: Bool, bundleID: String) throws {
        let client = RangeForwardDeleteClient(initialMarkedText: "")
        client.bundleID = bundleID
        let context = ClientContext(
            bundleId: client.bundleID,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: true
        )
        let composer = HangulComposer(
            statusBar: MockStatusBar(), configuration: MockConfiguration()
        )
        let session = InputSession(client: client, context: context, composer: composer)
        session.prepareForNonSecureClientWrites()
        composer.markKeystroke(bundleId: client.bundleID, hostSurface: context.hostSurface)
        #expect(client.document == "가나다라")
        #expect(client.selectedRangeValue == NSRange(location: 2, length: 0))
        for (key, code) in [("a", UInt16(0)), ("k", UInt16(40))] {
            #expect(session.handleKeyDown(try #require(
                TestEventFactory.keyEvent(char: key, keyCode: code)
            )))
        }
        #expect(client.document == "가나마다라")
        #expect(client.markedText == "마")
        #expect(client.markedRangeValue == NSRange(location: 2, length: 1))

        // IMK may have already lost the host when the deactivation commit arrives.
        client.ignoresCanonicalCommits = ignoredFocusCommit
        #expect(session.handleAppDeactivation())
        session.finalize(reason: .deactivateServer)
        session.finishHostCommitBoundary()
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "가나마다라")
        #expect(client.markedText == (ignoredFocusCommit ? "마" : ""))

        client.ignoresCanonicalCommits = false
        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextForInputBoundary { _ in context })
        session.prepareForNonSecureClientWrites()
        let driver = ManualHostKeyReplayDriver()
        let handled = session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "\u{F728}", keyCode: KeyCode.forwardDelete, modifiers: .function
        )), hostKeyEnvironment: driver.environment)
        if !handled { client.performDefaultForwardDelete() }
        #expect(client.document == "가나마라")
        #expect(client.markedText.isEmpty)
        #expect(client.selectedRangeValue == NSRange(location: 3, length: 0))
        #expect(handled == ignoredFocusCommit)
        #expect(driver.polls.isEmpty)
        #expect(driver.postedEventTypes.isEmpty)
    }

    private func remainingMarkSession(approved: Bool = true) -> (InputSession, RangeForwardDeleteClient) {
        let client = RangeForwardDeleteClient()
        client.bundleID = "com.openai.codex"
        let session = InputSession(
            client: client,
            context: ClientContext(
                bundleId: client.bundleID, hasTextInputCapability: true,
                isLikelyDesktopArea: false, documentAccessSafe: true
            ),
            composer: HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        )
        if approved { session.prepareForNonSecureClientWrites() }
        return (session, client)
    }

    @Test("Shift+Return preserves the host mark after the engine has been finalized")
    func remainingMarkShiftReturn() throws {
        let (session, client) = remainingMarkSession()
        let driver = ManualHostKeyReplayDriver()
        driver.onKeyDown = {
            let range = client.markedRangeValue.location == NSNotFound
                ? client.selectedRangeValue : client.markedRangeValue
            client.document = (client.document as NSString).replacingCharacters(in: range, with: "\n")
        }
        let handled = session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "\r", keyCode: KeyCode.return, modifiers: .shift
        )), hostKeyEnvironment: driver.environment)
        if !handled { driver.onKeyDown() }
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(handled)
        #expect(client.document == "가나마\n다라")
        #expect(driver.postedEventTypes == [.keyDown, .keyUp])
    }

    @Test("Remaining-mark host keys require a fresh nonsecure field and stable readable mark",
          arguments: ["unapproved", "secure", "stale", "unreadable", "mark_changed", "field_changed"],
          [KeyCode.return, KeyCode.forwardDelete, KeyCode.leftArrow])
    func remainingMarkDeleteRejectsUnprovenInput(boundary: String, keyCode: UInt16) throws {
        let (session, client) = remainingMarkSession(approved: boundary != "unapproved")
        var reads = 0
        client.onAttributedSubstring = {
            reads += 1
            client.onAttributedSubstring = nil
            if boundary == "mark_changed" {
                client.document = "가나바다라"
                client.markedText = "바"
            } else if boundary == "field_changed" {
                session.markContextStale()
                client.document = "other"
                client.markedText = ""
                client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
            }
        }
        switch boundary {
        case "secure": session.discardForSecureInput()
        case "stale": session.markContextStale()
        case "unreadable": client.attributedSubstringUnavailable = true
        default: break
        }
        let driver = ManualHostKeyReplayDriver()
        #expect(!session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "", keyCode: keyCode, modifiers: keyCode == KeyCode.return ? .shift : []
        )), hostKeyEnvironment: driver.environment))
        #expect(client.orderedHostCalls.isEmpty)
        #expect(driver.polls.isEmpty)
        #expect(driver.postedEventTypes.isEmpty)
        if ["unapproved", "secure", "stale"].contains(boundary) { #expect(reads == 0) }
        #expect(client.document == (
            boundary == "mark_changed" ? "가나바다라" : boundary == "field_changed" ? "other" : "가나마다라"
        ))
    }

    @Test("Remaining-mark Delete stops if field ownership changes during transaction preparation")
    func remainingMarkDeleteRejectsPreparationReentry() throws {
        let (session, client) = remainingMarkSession()
        client.onSelectedRange = {
            client.onSelectedRange = nil
            session.markContextStale()
        }
        let driver = ManualHostKeyReplayDriver()
        #expect(session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "\u{F728}", keyCode: KeyCode.forwardDelete
        )), hostKeyEnvironment: driver.environment))
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(client.orderedHostCalls.isEmpty)
        #expect(client.document == "가나마다라")
        #expect(client.markedText == "마")
        #expect(driver.postedEventTypes.isEmpty)
    }

    @Test("Remaining-mark recovery does not intercept Backspace or modified Delete",
          arguments: [
              (KeyCode.backspace, NSEvent.ModifierFlags()),
              (KeyCode.forwardDelete, .command), (KeyCode.forwardDelete, .control),
              (KeyCode.forwardDelete, .option), (KeyCode.forwardDelete, .shift)
          ])
    func remainingMarkDeletePreservesHostShortcuts(keyCode: UInt16, flags: NSEvent.ModifierFlags) throws {
        let (session, client) = remainingMarkSession()
        let driver = ManualHostKeyReplayDriver()
        #expect(!session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "", keyCode: keyCode, modifiers: flags
        )), hostKeyEnvironment: driver.environment))
        #expect(client.orderedHostCalls.isEmpty)
        #expect(client.document == "가나마다라")
        #expect(driver.polls.isEmpty)
    }

    @Test("Remaining-mark Delete commits the live host text, never stale adapter text")
    func remainingMarkDeleteUsesLiveHostText() throws {
        let (session, client) = remainingMarkSession()
        session.adapter.setMarkedText("예전")
        #expect(session.adapter.hostTransactionMarkedText == "예전")
        client.document = "가나바다라"
        client.markedText = "바"
        client.markedRangeValue = NSRange(location: 2, length: 1)
        client.selectedRangeValue = NSRange(location: 3, length: 0)
        let driver = ManualHostKeyReplayDriver()
        #expect(session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "\u{F728}", keyCode: KeyCode.forwardDelete
        )), hostKeyEnvironment: driver.environment))
        #expect(client.document == "가나바라")
        #expect(client.markedText.isEmpty)
        #expect(client.orderedHostCalls == ["insert:바", "delete:3:1"])
        #expect(driver.polls.isEmpty)
    }

    @Test("Remaining-mark recovery leaves English and native host delivery unchanged",
          arguments: [false, true])
    func remainingMarkDeleteKeepsPassThroughBoundaries(english: Bool) throws {
        let (session, client) = remainingMarkSession()
        if english {
            session.composer.setInputMode(.english)
        } else {
            session.refreshContext(ClientContext(
                bundleId: "com.apple.TextEdit", hasTextInputCapability: true,
                isLikelyDesktopArea: false, documentAccessSafe: true
            ), fieldIdentityMayHaveChanged: true)
            session.prepareForNonSecureClientWrites()
            session.ensureAdapterMatchesPolicy()
        }
        let driver = ManualHostKeyReplayDriver()
        #expect(!session.handleKeyDown(try #require(TestEventFactory.keyEvent(
            char: "\u{F728}", keyCode: KeyCode.forwardDelete
        )), hostKeyEnvironment: driver.environment))
        #expect(client.orderedHostCalls.isEmpty)
        #expect(client.document == "가나마다라")
        #expect(driver.polls.isEmpty)
    }

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

    @Test("Chrome Return does not replace a syllable after IMK retires ahead of the editor",
          arguments: [KeyCode.return, KeyCode.numpadEnter], [false, true])
    func chromeReturnWaitsForRenderer(keyCode: UInt16, shift: Bool) throws {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        client.document = "한글"
        client.markedRangeValue = NSRange(location: 1, length: 1)
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        let driver = ManualHostKeyReplayDriver()
        var rendererReady = false
        driver.onKeyDown = {
            client.document = rendererReady ? "한글\n" : "한\n"
        }
        #expect(HostKeyTransaction.perform(
            client: client, keyCode: keyCode,
            modifierFlags: shift ? NSEvent.ModifierFlags.shift.rawValue : 0,
            isClientWriteAllowed: { true }, didPost: { _ in },
            expectedCommittedText: "글", environment: driver.environment,
            commit: { client.markedRangeValue = NSRange(location: NSNotFound, length: 0) }
        ))
        try driver.runNextPoll()
        try driver.runNextPoll()
        // Real Jira failed even after the mark disappeared and the caret collapsed.
        #expect(driver.postedEventTypes.isEmpty)
        #expect(client.document == "한글")
        #expect(driver.rendererSettlementCount == 1)
        rendererReady = true
        while !driver.polls.isEmpty { try driver.runNextPoll() }
        #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        #expect(client.document == "한글\n")
    }

    @Test("Chrome settlement rechecks authorization and composition before replay",
          arguments: ["revoked", "new-composition", "text-changed", "caret-moved", "mark-reappeared"])
    func chromeSettlementRevalidatesTarget(change: String) throws {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        client.document = "한글"
        let range = NSRange(location: 1, length: 1)
        client.markedRangeValue = range
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        var allowed = true
        let driver = ManualHostKeyReplayDriver()
        #expect(HostKeyTransaction.perform(
            client: client, keyCode: KeyCode.return, modifierFlags: 0,
            isClientWriteAllowed: { allowed }, didPost: { _ in },
            expectedCommittedText: "글", environment: driver.environment,
            commit: { client.markedRangeValue = NSRange(location: NSNotFound, length: 0) }
        ))
        try driver.runNextPoll()
        try driver.runNextPoll()
        #expect(driver.rendererSettlementCount == 1)
        #expect(driver.postedEventTypes.isEmpty)
        switch change {
        case "revoked": allowed = false
        case "new-composition": client.markedRangeValue = NSRange(location: 2, length: 1)
        case "text-changed": client.document = "한가"
        case "caret-moved": client.selectedRangeValue = NSRange(location: 0, length: 0)
        default: client.markedRangeValue = range
        }
        try driver.runNextPoll()
        #expect(driver.postedEventTypes.isEmpty)
        if change == "mark-reappeared" {
            client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
            try driver.runNextPoll()
            try driver.runNextPoll()
            #expect(driver.rendererSettlementCount == 2)
            #expect(driver.postedEventTypes.isEmpty)
            try driver.runNextPoll()
            #expect(driver.postedEventTypes == [.keyDown, .keyUp])
        } else {
            while !driver.polls.isEmpty { try driver.runNextPoll() }
            #expect(driver.postedEventTypes.isEmpty)
        }
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

    @Test("Blink Forward Delete keeps 마 and deletes the following 다",
          arguments: ["com.google.Chrome", "com.openai.codex"])
    func blinkMidTextForwardDelete(bundleID: String) throws {
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration()
        )
        let host = FakeForwardDeleteHost()
        composer.markKeystroke(
            bundleId: bundleID,
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

        #expect(handled == (bundleID != "com.google.Chrome"))
        if !handled { host.performDefaultForwardDelete() }
        host.deliverScheduledForwardDelete()
        #expect(host.document == "가나마라")
        #expect(host.markedText.isEmpty)
        #expect(host.caretOffset == 3)
        #expect(host.scheduledForwardDeleteCount == (bundleID == "com.google.Chrome" ? 0 : 1))
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

    @Test(
        "Chrome, Codex, Slack accept a visible provisional mark with an end caret",
        arguments: [
            "com.google.Chrome",
            "com.openai.codex",
            "com.tinyspeck.slackmacgap"
        ]
    )
    func blinkHostsUseVisibleProvisionalForwardDeleteRange(bundleID: String) {
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
            expectedMarkedRangeIsConfirmed: false,
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

    @Test(
        "Chrome, Codex, Slack verify a provisional mark before delayed range deletion",
        arguments: [
            "com.google.Chrome",
            "com.openai.codex",
            "com.tinyspeck.slackmacgap"
        ]
    )
    func blinkHostsVerifyDelayedForwardDeleteRange(bundleID: String) throws {
        let client = DelayedBlinkForwardDeleteClient(
            exposesLiveMarkedRange: false,
            selectionTracksMarkedText: false
        )
        client.bundleID = bundleID
        let driver = ManualHostKeyReplayDriver()
        client.setMarkedText(
            "마",
            selectionRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        let handled = HostKeyTransaction.perform(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { true },
            didPost: driver.recordBoundary,
            expectedCommittedText: "마",
            expectedMarkedRange: NSRange(location: 2, length: 1),
            expectedMarkedRangeIsConfirmed: false,
            environment: driver.environment,
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
        #expect(client.document == "가나다라")
        #expect(driver.postedEventTypes.isEmpty)
        #expect(driver.postedBoundaryCount == 0)

        try driver.runNextPoll()
        #expect(client.document == "가나다라")
        try client.promotePendingCommit()
        client.retireMarkedText()
        try driver.runNextPoll()

        #expect(client.document == "가나마라")
        #expect(client.selectedRangeValue == NSRange(location: 3, length: 0))
        #expect(driver.postedEventTypes.isEmpty)
        #expect(driver.postedBoundaryCount == 1)
    }

    @Test("A provisional mark cannot match an identical following syllable early")
    func provisionalForwardDeleteRequiresDocumentPromotion() throws {
        let client = DelayedBlinkForwardDeleteClient(
            exposesLiveMarkedRange: false,
            selectionTracksMarkedText: false
        )
        client.document = "가나마라"
        let driver = ManualHostKeyReplayDriver()
        client.setMarkedText(
            "마",
            selectionRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        let handled = HostKeyTransaction.perform(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { true },
            didPost: driver.recordBoundary,
            expectedCommittedText: "마",
            expectedMarkedRange: NSRange(location: 2, length: 1),
            expectedMarkedRangeIsConfirmed: false,
            environment: driver.environment,
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
        try driver.runNextPoll()
        #expect(client.document == "가나마라")
        #expect(driver.postedBoundaryCount == 0)

        try client.promotePendingCommit()
        client.retireMarkedText()
        try driver.runNextPoll()
        #expect(client.document == "가나마라")
        #expect(driver.postedBoundaryCount == 1)
    }

    @Test("A delayed Forward Delete never writes after its field lease expires")
    func delayedForwardDeleteStopsAfterLeaseChange() throws {
        let client = DelayedBlinkForwardDeleteClient(
            exposesLiveMarkedRange: false,
            selectionTracksMarkedText: false
        )
        let driver = ManualHostKeyReplayDriver()
        var clientWriteIsAllowed = true
        client.setMarkedText(
            "마",
            selectionRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        let handled = HostKeyTransaction.perform(
            client: client,
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isClientWriteAllowed: { clientWriteIsAllowed },
            didPost: driver.recordBoundary,
            expectedCommittedText: "마",
            expectedMarkedRange: NSRange(location: 2, length: 1),
            expectedMarkedRangeIsConfirmed: false,
            environment: driver.environment,
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
        try client.promotePendingCommit()
        client.retireMarkedText()
        clientWriteIsAllowed = false
        try driver.runNextPoll()

        #expect(client.document == "가나마다라")
        #expect(driver.postedBoundaryCount == 0)
        #expect(driver.polls.isEmpty)
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

    // User-observed Jira editor: both plain Return and Shift+Return can remove
    // the final syllable. Commit must precede one host-owned line-break action.
    @Test("Chrome rich-editor Return waits for composition and delivers once",
          arguments: [KeyCode.return, KeyCode.numpadEnter], [false, true])
    func chromeRichEditorReturnWaitsForComposition(keyCode: UInt16, shift: Bool) {
        let pipeline = ReturnDeliveryHarness()
        pipeline.bundleId = "com.google.Chrome"
        pipeline.typeBangSik()
        let modifiers: NSEvent.ModifierFlags = shift ? [.shift] : []
        let event = TestEventFactory.keyEvent(
            char: "\r", keyCode: keyCode, modifiers: modifiers, timestamp: 10
        )!
        #expect(pipeline.dispatch(event))
        #expect(pipeline.host.document == "방식")
        #expect(pipeline.host.defaultReturnActionCount == 0)
        #expect(pipeline.host.scheduledReturnModifierFlags == modifiers.rawValue)
        pipeline.host.deliverScheduledReturn()
        #expect(pipeline.host.document == "방식\n")
        #expect(pipeline.host.defaultReturnActionCount == 1)
        #expect(pipeline.dispatch(event))
        pipeline.host.deliverScheduledReturn()
        #expect(pipeline.host.document == "방식\n")
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
