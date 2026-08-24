import Cocoa
import InputMethodKit

/// Authorization captured by an asynchronous host-key replay.
private final class DeferredClientWriteAuthorization: @unchecked Sendable {
    let isAllowed: () -> Bool

    init(isAllowed: @escaping () -> Bool) {
        self.isAllowed = isAllowed
    }
}

/// Field-boundary callback captured by the deferred CGEvent delivery.
private final class DeferredHostKeyBoundary: @unchecked Sendable {
    let handler: (UInt16) -> Void

    init(handler: @escaping (UInt16) -> Void = { _ in }) {
        self.handler = handler
    }
}

enum DeferredCompositionRetirementDecision: Equatable {
    case wait
    case deliver
    case cancel
}

enum DeferredHostKeyTargetPolicy {
    case compositionOnly
    case caretAnchored
}

/// Waits until the exact composition targeted by a host-owned key has retired.
/// Forward Delete additionally pins the caret and verifies document promotion.
struct DeferredCompositionRetirementGate {
    private static let maxReasonableLocation = 10_000_000

    private let originalMarkedRange: NSRange?
    private let verificationRange: NSRange?
    private let expectedCaretLocation: Int
    private let targetPolicy: DeferredHostKeyTargetPolicy
    private var stableUnmarkedObservations = 0

    var requiresCaretAnchor: Bool {
        targetPolicy == .caretAnchored || originalMarkedRange == nil
    }

    var committedTextVerificationRange: NSRange? {
        targetPolicy == .caretAnchored || originalMarkedRange == nil
            ? verificationRange
            : nil
    }

    init?(
        markedRange: NSRange,
        targetPolicy: DeferredHostKeyTargetPolicy = .caretAnchored
    ) {
        let (end, overflow) = markedRange.location.addingReportingOverflow(markedRange.length)
        guard markedRange.location != NSNotFound,
              markedRange.length > 0,
              !overflow,
              markedRange.location < Self.maxReasonableLocation,
              end < Self.maxReasonableLocation else { return nil }
        originalMarkedRange = markedRange
        verificationRange = markedRange
        expectedCaretLocation = end
        self.targetPolicy = targetPolicy
    }

    /// Some Blink clients expose a valid caret before they expose their live
    /// marked range. A deferred host key can still target the committed preedit
    /// precisely: it must appear immediately before that unchanged caret.
    init?(
        unavailableMarkedRange markedRange: NSRange,
        selectedRange: NSRange,
        expectedCommittedTextLength: Int,
        targetPolicy: DeferredHostKeyTargetPolicy = .caretAnchored
    ) {
        let (selectionEnd, selectionOverflow) = selectedRange.location
            .addingReportingOverflow(selectedRange.length)
        guard markedRange.location == NSNotFound || markedRange.length == 0,
              selectedRange.location != NSNotFound,
              selectedRange.length == 0,
              expectedCommittedTextLength > 0,
              selectedRange.location >= expectedCommittedTextLength,
              !selectionOverflow,
              selectedRange.location < Self.maxReasonableLocation,
              selectionEnd < Self.maxReasonableLocation else { return nil }

        let verificationRange = NSRange(
            location: selectedRange.location - expectedCommittedTextLength,
            length: expectedCommittedTextLength
        )
        originalMarkedRange = nil
        self.verificationRange = verificationRange
        expectedCaretLocation = selectedRange.location
        self.targetPolicy = targetPolicy
    }

    mutating func observe(
        markedRange: NSRange,
        selectedRange: NSRange,
        committedTextIsVisible: Bool? = nil
    ) -> DeferredCompositionRetirementDecision {
        if requiresCaretAnchor {
            guard selectedRange.location == expectedCaretLocation,
                  selectedRange.length == 0 else { return .cancel }
        }

        if markedRange.location != NSNotFound, markedRange.length > 0 {
            stableUnmarkedObservations = 0
            let ownedRange = originalMarkedRange ?? verificationRange
            return markedRange == ownedRange ? .wait : .cancel
        }

        if committedTextVerificationRange != nil,
           committedTextIsVisible != true {
            stableUnmarkedObservations = 0
            return .wait
        }

        stableUnmarkedObservations += 1
        return stableUnmarkedObservations >= 2 ? .deliver : .wait
    }
}

private final class DeferredHostKeyReplay: @unchecked Sendable {
    private static let maxRetirementPolls = 100

    private let client: IMKTextInput
    private let keyCode: UInt16
    private let events: DeferredHostKeyDelivery.Events
    private let authorization: DeferredClientWriteAuthorization
    private let postedBoundary: DeferredHostKeyBoundary
    private let expectedCommittedText: String?
    private var retirementGate: DeferredCompositionRetirementGate?
    private var pollCount = 0

    var isArmed: Bool {
        guard retirementGate != nil else { return false }
        return keyCode != KeyCode.forwardDelete || expectedCommittedText != nil
    }

    init(
        client: IMKTextInput,
        keyCode: UInt16,
        events: DeferredHostKeyDelivery.Events,
        authorization: DeferredClientWriteAuthorization,
        postedBoundary: DeferredHostKeyBoundary,
        expectedCommittedText: String?
    ) {
        self.client = client
        self.keyCode = keyCode
        self.events = events
        self.authorization = authorization
        self.postedBoundary = postedBoundary
        let normalizedExpectedCommittedText = expectedCommittedText?
            .precomposedStringWithCanonicalMapping
        self.expectedCommittedText = normalizedExpectedCommittedText
        let targetPolicy: DeferredHostKeyTargetPolicy = keyCode == KeyCode.forwardDelete
            ? .caretAnchored
            : .compositionOnly
        let initialMarkedRange = client.markedRange()
        retirementGate = DeferredCompositionRetirementGate(
            markedRange: initialMarkedRange,
            targetPolicy: targetPolicy
        )
        if retirementGate == nil,
           let normalizedExpectedCommittedText,
           !normalizedExpectedCommittedText.isEmpty {
            retirementGate = DeferredCompositionRetirementGate(
                unavailableMarkedRange: initialMarkedRange,
                selectedRange: client.selectedRange(),
                expectedCommittedTextLength: normalizedExpectedCommittedText.utf16.count,
                targetPolicy: targetPolicy
            )
        }
    }

    func schedule() {
        DispatchQueue.main.async { [self] in
            deliverWhenReady()
        }
    }

    private func deliverWhenReady() {
        guard authorization.isAllowed() else {
            logSkip("stale_session")
            return
        }

        if var gate = retirementGate {
            let markedRange = client.markedRange()
            let committedTextIsVisible: Bool?
            if let verificationRange = gate.committedTextVerificationRange,
               markedRange.location == NSNotFound || markedRange.length == 0,
               let expectedCommittedText {
                committedTextIsVisible = client
                    .attributedSubstring(from: verificationRange)?
                    .string
                    .precomposedStringWithCanonicalMapping == expectedCommittedText
            } else {
                committedTextIsVisible = nil
            }
            let selectedRange = gate.requiresCaretAnchor
                ? client.selectedRange()
                : NSRange(location: NSNotFound, length: 0)
            let decision = gate.observe(
                markedRange: markedRange,
                selectedRange: selectedRange,
                committedTextIsVisible: committedTextIsVisible
            )
            retirementGate = gate
            switch decision {
            case .deliver:
                break
            case .cancel:
                logSkip("host_key_target_changed")
                return
            case .wait:
                pollCount += 1
                guard pollCount < Self.maxRetirementPolls else {
                    logSkip("marked_text_not_retired")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
                    deliverWhenReady()
                }
                return
            }
        }

        guard authorization.isAllowed() else {
            logSkip("stale_session")
            return
        }
        DeferredHostKeyDelivery.postApprovedReplay(
            events,
            keyCode: keyCode,
            didPost: postedBoundary.handler
        )
        DebugLogger.event("input.host_key_replay_delivered", metadata: [
            .count("retirement_polls", pollCount)
        ])
    }

    private func logSkip(_ reason: StaticString) {
        DebugLogger.event("input.host_key_replay_skipped", metadata: [
            .state("reason", reason)
        ])
    }
}

/// Starts one host-owned key transaction while keeping its asynchronous replay
/// machinery private to this file.
enum HostKeyTransaction {
    /// Captures the live Blink composition, commits it canonically, and only then
    /// starts asynchronous retirement observation. Sending an empty marked-text
    /// update before `insertText` can make Chromium discard that following commit.
    static func perform(
        client: IMKTextInput,
        keyCode: UInt16,
        modifierFlags: UInt,
        isClientWriteAllowed: @escaping () -> Bool,
        didPost: @escaping (UInt16) -> Void,
        expectedCommittedText: String?,
        commit: () -> Void
    ) -> Bool {
        guard let replay = prepareReplay(
            client: client,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isClientWriteAllowed: isClientWriteAllowed,
            didPost: didPost,
            expectedCommittedText: expectedCommittedText
        ) else { return false }
        commit()
        replay.schedule()
        return true
    }

    static func schedule(
        client: IMKTextInput,
        keyCode: UInt16,
        modifierFlags: UInt,
        isClientWriteAllowed: @escaping () -> Bool,
        didPost: @escaping (UInt16) -> Void,
        expectedCommittedText: String?
    ) -> Bool {
        guard let replay = prepareReplay(
            client: client,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isClientWriteAllowed: isClientWriteAllowed,
            didPost: didPost,
            expectedCommittedText: expectedCommittedText
        ) else { return false }
        replay.schedule()
        return true
    }

    private static func prepareReplay(
        client: IMKTextInput,
        keyCode: UInt16,
        modifierFlags: UInt,
        isClientWriteAllowed: @escaping () -> Bool,
        didPost: @escaping (UInt16) -> Void,
        expectedCommittedText: String?
    ) -> DeferredHostKeyReplay? {
        guard IOKitManager.hasAccessibilityPermission(),
              isClientWriteAllowed(),
              let events = DeferredHostKeyDelivery.makeEvents(
                  keyCode: keyCode,
                  modifierFlags: modifierFlags
              ) else { return nil }

        let replay = DeferredHostKeyReplay(
            client: client,
            keyCode: keyCode,
            events: events,
            authorization: DeferredClientWriteAuthorization(
                isAllowed: isClientWriteAllowed
            ),
            postedBoundary: DeferredHostKeyBoundary(handler: didPost),
            expectedCommittedText: expectedCommittedText
        )
        return replay.isArmed ? replay : nil
    }
}

enum DeferredHostKeyDelivery {
    struct Events {
        let keyDown: CGEvent
        let keyUp: CGEvent
    }

    private static let replayMarker: Int64 = 0x5052_5459_5045_5254

    private static func supportsReplay(_ keyCode: UInt16) -> Bool {
        keyCode == KeyCode.return
            || keyCode == KeyCode.numpadEnter
            || keyCode == KeyCode.forwardDelete
    }

    static func makeEvents(
        keyCode: UInt16,
        modifierFlags: UInt
    ) -> Events? {
        guard supportsReplay(keyCode),
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(keyCode),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(keyCode),
                  keyDown: false
              ) else { return nil }

        let flags = CGEventFlags(rawValue: UInt64(modifierFlags))
        for event in [keyDown, keyUp] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
        }
        return Events(keyDown: keyDown, keyUp: keyUp)
    }

    /// Posts one already-authorized host key pair, then publishes its field boundary.
    /// Keep this synchronous ordering in one testable operation: reversing either
    /// edge can leave the host's physical key state or field ownership stranded.
    static func postApprovedReplay(
        _ events: Events,
        keyCode: UInt16,
        postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        didPost: (UInt16) -> Void
    ) {
        postEvent(events.keyDown)
        postEvent(events.keyUp)
        didPost(keyCode)
    }

    static func isReplayedHostKey(_ event: NSEvent) -> Bool {
        guard supportsReplay(event.keyCode),
              let cgEvent = event.cgEvent else { return false }
        return isReplayedHostKey(cgEvent)
    }

    static func isReplayedHostKey(_ event: CGEvent) -> Bool {
        let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard rawKeyCode >= 0,
              rawKeyCode <= Int64(UInt16.max),
              supportsReplay(UInt16(rawKeyCode)) else { return false }
        return event.getIntegerValueField(.eventSourceUserData) == replayMarker
    }
}
