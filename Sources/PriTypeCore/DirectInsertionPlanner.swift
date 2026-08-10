import Cocoa

// MARK: - KeyEventDedup
//
// Some hosts (observed: KakaoTalk) deliver the SAME physical keyDown to the IME twice,
// which makes each backspace decompose two jamo and each character double up. We drop
// only an exact re-delivery of the immediately-preceding event. A time window is not
// enough evidence: two fast physical taps may legitimately have the same keyCode.

struct KeyDownSnapshot: Equatable {
    /// Object identity catches a host re-entering IMK with the same NSEvent instance.
    /// It is nil for snapshots reconstructed in tests or from another event wrapper.
    let eventIdentity: ObjectIdentifier?
    let timestamp: TimeInterval
    let keyCode: UInt16
    let modifierFlags: UInt
    let windowNumber: Int
    let keyboardType: Int64
    let isARepeat: Bool

    init(
        eventIdentity: ObjectIdentifier? = nil,
        timestamp: TimeInterval,
        keyCode: UInt16,
        modifierFlags: UInt = 0,
        windowNumber: Int = 0,
        keyboardType: Int64 = 0,
        isARepeat: Bool = false
    ) {
        self.eventIdentity = eventIdentity
        self.timestamp = timestamp
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.windowNumber = windowNumber
        self.keyboardType = keyboardType
        self.isARepeat = isARepeat
    }

    init(event: NSEvent) {
        self.init(
            eventIdentity: ObjectIdentifier(event),
            timestamp: event.timestamp,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
            windowNumber: event.windowNumber,
            keyboardType: event.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType) ?? 0,
            isARepeat: event.isARepeat
        )
    }
}

enum KeyEventDedup {
    static func isDuplicate(_ event: KeyDownSnapshot, previous: KeyDownSnapshot?) -> Bool {
        guard let previous,
              !event.isARepeat, !previous.isARepeat else { return false }

        if let eventIdentity = event.eventIdentity,
           let previousIdentity = previous.eventIdentity,
           eventIdentity == previousIdentity,
           event.timestamp == previous.timestamp,
           event.keyCode == previous.keyCode,
           event.modifierFlags == previous.modifierFlags,
           event.windowNumber == previous.windowNumber,
           event.keyboardType == previous.keyboardType {
            return true
        }

        // Real hardware events have a monotonic, non-zero timestamp. Requiring an
        // exact full signature catches a re-wrapped delivery without guessing that a
        // nearby tap "must" be the same physical event. The zero guard also keeps
        // independently-created synthetic NSEvents from collapsing accidentally.
        guard event.timestamp > 0, previous.timestamp > 0 else { return false }
        return event.timestamp == previous.timestamp
            && event.keyCode == previous.keyCode
            && event.modifierFlags == previous.modifierFlags
            && event.windowNumber == previous.windowNumber
            && event.keyboardType == previous.keyboardType
    }

    /// A host may re-wrap the same keyDown before control returns to the main queue,
    /// changing its timestamp in the process. Delivery-turn identity replaces the old
    /// 50ms guess: a real fast `ㅋㅋ` double-tap arrives as two later turns, while an
    /// immediate IMK re-entry remains in the current turn.
    static func isSameDeliveryTurn(
        _ event: KeyDownSnapshot,
        previous: KeyDownSnapshot?
    ) -> Bool {
        guard let previous,
              !event.isARepeat, !previous.isARepeat else { return false }
        return event.keyCode == previous.keyCode
            && event.modifierFlags == previous.modifierFlags
            && event.windowNumber == previous.windowNumber
            && event.keyboardType == previous.keyboardType
    }
}

enum KeyDownRoute: Equatable {
    case process
    case consumeDuplicate

    /// A duplicate never reaches the composer or host. In particular, this must not
    /// replay a previous `false`, which would invoke the host default action twice.
    var immediateHandledResult: Bool? {
        switch self {
        case .process:
            nil
        case .consumeDuplicate:
            true
        }
    }
}

/// Stateful, immediately-previous-event deduplicator shared by production and the
/// host-behavior regression harness. A duplicate route is always consumed by IMK;
/// replaying the original `handled` result would pass a duplicated Return to the app.
struct KeyEventDeduplicator {
    private var previous: KeyDownSnapshot?
    private var eventInCurrentDeliveryTurn: KeyDownSnapshot?
    private(set) var deliveryTurnGeneration: UInt64 = 0

    mutating func route(_ event: KeyDownSnapshot) -> KeyDownRoute {
        let isDuplicate = KeyEventDedup.isDuplicate(event, previous: previous)
            || KeyEventDedup.isSameDeliveryTurn(
                event,
                previous: eventInCurrentDeliveryTurn
            )
        previous = event
        if isDuplicate {
            return .consumeDuplicate
        }

        if !event.isARepeat {
            deliveryTurnGeneration &+= 1
            eventInCurrentDeliveryTurn = event
        }
        return .process
    }

    /// Clear the timestamp-independent re-entry guard on the next main-queue turn.
    /// A generation prevents an older queued clear from removing a newer guard.
    mutating func endDeliveryTurn(generation: UInt64) {
        guard generation == deliveryTurnGeneration else { return }
        eventInCurrentDeliveryTurn = nil
    }
}

// MARK: - DirectInsertionPlanner
//
// Pure decision logic for the experimental Windows-style direct-insertion delivery
// (Phase 3 — see Docs/KoreanWindowsInputFeasibility.md). Extracted from the adapter
// so the read-modify-write math is unit-testable without a live IMKTextInput.
//
// In direct insertion there is NO marked text: the in-progress syllable is written
// into the document as REAL text and rewritten in place on each keystroke. The
// planner computes which range of already-inserted live-preedit text to replace, and
// what the new tracked live-preedit length becomes.

/// The plan for one in-place rewrite of the live preedit.
struct DirectInsertionPlan: Equatable {
    /// Range to pass to `insertText(_:replacementRange:)`. When `bailed` is true this
    /// is `{NSNotFound, 0}` (the adapter must NOT use it; it should fall back).
    let replaceRange: NSRange
    /// The new tracked UTF-16 length of the live preedit after the rewrite.
    let newLivePreeditLength: Int
    /// True when the client's selection range was unusable (no `TSMDocumentAccess`):
    /// the adapter must fall back to marked text rather than corrupt/strand text.
    let bailed: Bool
}

enum DirectInsertionPlanner {
    /// Same sanity ceiling used elsewhere to reject Chromium's garbage range values.
    static let maxReasonableLocation = 10_000_000

    /// Caret-stability guard. Decide whether the tracked live preedit can still be
    /// safely rewritten in place, given a read-back of the document at the expected
    /// region. The live preedit is REAL text the user can click/arrow away from, and
    /// IMK does NOT notify us of caret moves (there is no marked range), so we must
    /// verify before deleting. Returns false → the caller must abandon tracking and
    /// insert fresh, never deleting text it cannot verify.
    /// - Parameters:
    ///   - caret: `client.selectedRange().location`.
    ///   - livePreeditLength: tracked UTF-16 length of the live preedit (0 ⇒ nothing tracked).
    ///   - actualSubstring: the document text currently at `[caret-len, len]` (nil if unreadable).
    ///   - expectedText: the string we last wrote as the live preedit.
    static func liveRegionIsVerified(
        caret: Int,
        livePreeditLength: Int,
        actualSubstring: String?,
        expectedText: String
    ) -> Bool {
        guard livePreeditLength > 0 else { return true }   // nothing tracked → safe
        guard caret != NSNotFound,
              caret >= livePreeditLength,
              caret < maxReasonableLocation else { return false }
        return actualSubstring == expectedText
    }

    /// Compute the rewrite plan.
    /// - Parameters:
    ///   - cursorLocation: `client.selectedRange().location` (UTF-16 offset of caret).
    ///   - livePreeditLength: UTF-16 length of the live preedit currently in the document.
    ///   - textUTF16Count: UTF-16 length of the replacement text.
    ///   - keepingLive: true when the replacement text is itself a (new) live preedit
    ///     (`setMarkedText`); false when it is a finalized commit (`insertText`) that
    ///     becomes permanent and therefore tracks length 0.
    static func plan(
        cursorLocation: Int,
        livePreeditLength: Int,
        textUTF16Count: Int,
        keepingLive: Bool
    ) -> DirectInsertionPlan {
        let newLive = keepingLive ? textUTF16Count : 0

        let safe = cursorLocation != NSNotFound
            && cursorLocation < maxReasonableLocation
            && cursorLocation >= livePreeditLength

        guard safe else {
            return DirectInsertionPlan(
                replaceRange: NSRange(location: NSNotFound, length: 0),
                newLivePreeditLength: newLive,
                bailed: true
            )
        }

        return DirectInsertionPlan(
            replaceRange: NSRange(location: cursorLocation - livePreeditLength, length: livePreeditLength),
            newLivePreeditLength: newLive,
            bailed: false
        )
    }
}
