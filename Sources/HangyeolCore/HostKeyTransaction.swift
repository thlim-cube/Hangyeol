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

/// Exact document mutation for a host-owned Forward Delete. A provisional Blink
/// composition start never authorizes deletion on its own: the committed text,
/// document-length transition, caret, and following composed character must all
/// agree after commit before this mutation can run.
private struct PreparedForwardDeletion {
    private static let maxProbeLength = 64
    private static let maxReasonableLocation = 10_000_000

    private let client: IMKTextInput
    private let expectedCommittedText: String
    private let committedRange: NSRange
    private let deletionRange: NSRange?
    private let expectedFollowingText: String?
    private let expectedDocumentLength: Int

    static func prepare(
        client: IMKTextInput,
        expectedCommittedText: String,
        expectedMarkedRange: NSRange,
        expectedMarkedRangeIsConfirmed: Bool
    ) -> PreparedForwardDeletion? {
        let normalizedExpectedText = expectedCommittedText
            .precomposedStringWithCanonicalMapping
        let committedLength = normalizedExpectedText.utf16.count
        guard !normalizedExpectedText.isEmpty,
              expectedMarkedRange.location != NSNotFound,
              expectedMarkedRange.location >= 0,
              expectedMarkedRange.location < Self.maxReasonableLocation,
              expectedMarkedRange.length == committedLength else { return nil }

        let (postCommitCaret, caretOverflow) = expectedMarkedRange.location
            .addingReportingOverflow(committedLength)
        guard !caretOverflow else { return nil }

        let documentLength = client.length()
        guard documentLength >= 0,
              documentLength < Self.maxReasonableLocation else { return nil }
        let markedReadback = client
            .attributedSubstring(from: expectedMarkedRange)?
            .string
            .precomposedStringWithCanonicalMapping
        let selection = client.selectedRange()
        let provisionalMarkIsVisible = !expectedMarkedRangeIsConfirmed
            && selection == NSRange(location: postCommitCaret, length: 0)
        // Blink may expose the marked syllable through document APIs before it
        // publishes `markedRange`. In that state, matching text alone is not proof:
        // it could be an identical committed syllable under a still-virtual mark.
        // The caret at the provisional mark's exact visual end supplies the missing
        // independent signal. A preedit-start caret keeps the safer growth proof.
        let documentIncludesMarkedText = markedReadback == normalizedExpectedText
            && (expectedMarkedRangeIsConfirmed || provisionalMarkIsVisible)
        let followingSourceLocation = documentIncludesMarkedText
            ? postCommitCaret
            : expectedMarkedRange.location
        guard followingSourceLocation <= documentLength else { return nil }
        let expectedDocumentLength: Int
        if documentIncludesMarkedText {
            expectedDocumentLength = documentLength
        } else {
            let (lengthAfterCommit, overflow) = documentLength
                .addingReportingOverflow(committedLength)
            guard !overflow,
                  lengthAfterCommit < Self.maxReasonableLocation else { return nil }
            expectedDocumentLength = lengthAfterCommit
        }
        guard followingSourceLocation < documentLength else {
            return PreparedForwardDeletion(
                client: client,
                expectedCommittedText: normalizedExpectedText,
                committedRange: expectedMarkedRange,
                deletionRange: nil,
                expectedFollowingText: nil,
                expectedDocumentLength: expectedDocumentLength
            )
        }

        let probeLength = min(
            Self.maxProbeLength,
            documentLength - followingSourceLocation
        )
        guard probeLength > 0,
              let followingText = client.attributedSubstring(from: NSRange(
                  location: followingSourceLocation,
                  length: probeLength
              ))?.string,
              !followingText.isEmpty else { return nil }
        let composedRange = (followingText as NSString)
            .rangeOfComposedCharacterSequence(at: 0)
        guard composedRange.location == 0,
              composedRange.length > 0 else { return nil }

        return PreparedForwardDeletion(
            client: client,
            expectedCommittedText: normalizedExpectedText,
            committedRange: expectedMarkedRange,
            deletionRange: NSRange(
                location: postCommitCaret,
                length: composedRange.length
            ),
            expectedFollowingText: String(
                followingText[followingText.startIndex..<followingText.index(
                    followingText.startIndex,
                    offsetBy: 1
                )]
            ).precomposedStringWithCanonicalMapping,
            expectedDocumentLength: expectedDocumentLength
        )
    }

    func invokeIfReady(isClientWriteAllowed: () -> Bool) -> Bool {
        guard isClientWriteAllowed(),
              client.length() == expectedDocumentLength,
              client.markedRange().length == 0,
              client.selectedRange() == NSRange(
                  location: NSMaxRange(committedRange),
                  length: 0
              ),
              client.attributedSubstring(from: committedRange)?
                  .string
                  .precomposedStringWithCanonicalMapping == expectedCommittedText else {
            return false
        }
        guard let deletionRange else { return true }
        guard let expectedFollowingText,
              client.attributedSubstring(from: deletionRange)?
                  .string
                  .precomposedStringWithCanonicalMapping == expectedFollowingText,
              isClientWriteAllowed() else {
            return false
        }
        client.insertText("", replacementRange: deletionRange)
        return true
    }
}

private final class DeferredForwardDeletion: @unchecked Sendable {
    private static let maxPromotionPolls = 100

    private let prepared: PreparedForwardDeletion
    private let authorization: DeferredClientWriteAuthorization
    private let postedBoundary: DeferredHostKeyBoundary
    private let environment: DeferredHostKeyReplayEnvironment
    private var pollCount = 0

    init(
        prepared: PreparedForwardDeletion,
        authorization: DeferredClientWriteAuthorization,
        postedBoundary: DeferredHostKeyBoundary,
        environment: DeferredHostKeyReplayEnvironment
    ) {
        self.prepared = prepared
        self.authorization = authorization
        self.postedBoundary = postedBoundary
        self.environment = environment
    }

    func deliverOrSchedule() {
        if deliverIfReady() { return }
        environment.scheduleInitial(DeferredHostKeyPoll { [self] in
            poll()
        })
    }

    private func poll() {
        guard authorization.isAllowed() else {
            logSkip("stale_session")
            return
        }
        if deliverIfReady() { return }
        pollCount += 1
        guard pollCount < Self.maxPromotionPolls else {
            logSkip("document_promotion_unverified")
            return
        }
        environment.scheduleRetry(DeferredHostKeyPoll { [self] in
            poll()
        })
    }

    private func deliverIfReady() -> Bool {
        guard prepared.invokeIfReady(
            isClientWriteAllowed: authorization.isAllowed
        ) else { return false }
        postedBoundary.handler(KeyCode.forwardDelete)
        DebugLogger.event("input.host_key_range_delete_delivered", metadata: [
            .count("promotion_polls", pollCount)
        ])
        return true
    }

    private func logSkip(_ reason: StaticString) {
        DebugLogger.event("input.host_key_range_delete_skipped", metadata: [
            .state("reason", reason)
        ])
    }
}

/// Sendable wrapper used to hand one replay poll to either the live main queue or
/// a deterministic regression-test driver without exposing replay internals.
final class DeferredHostKeyPoll: @unchecked Sendable {
    let run: () -> Void

    init(run: @escaping () -> Void) {
        self.run = run
    }
}

/// Side-effect boundary for deferred replay. Production always uses `.live`;
/// tests replace only scheduling and event posting while exercising the same gate.
struct DeferredHostKeyReplayEnvironment: @unchecked Sendable {
    let canReplay: () -> Bool
    let makeEvents: (UInt16, UInt) -> DeferredHostKeyDelivery.Events?
    let scheduleInitial: (DeferredHostKeyPoll) -> Void
    let scheduleRetry: (DeferredHostKeyPoll) -> Void
    let postEvent: (CGEvent) -> Void

    static let live = DeferredHostKeyReplayEnvironment(
        canReplay: { IOKitManager.hasAccessibilityPermission() },
        makeEvents: { keyCode, modifierFlags in
            DeferredHostKeyDelivery.makeEvents(
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )
        },
        scheduleInitial: { poll in
            DispatchQueue.main.async {
                poll.run()
            }
        },
        scheduleRetry: { poll in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                poll.run()
            }
        },
        postEvent: { event in
            event.post(tap: .cghidEventTap)
        }
    )
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
/// Forward Delete accepts both caret shapes Blink reports around an active
/// preedit, then verifies which one contains the committed text.
struct DeferredCompositionRetirementGate {
    private static let maxReasonableLocation = 10_000_000

    private let originalMarkedRange: NSRange?
    private let caretTargets: [(location: Int, verificationRange: NSRange)]
    private let targetPolicy: DeferredHostKeyTargetPolicy
    private var stableUnmarkedObservations = 0

    var requiresCaretAnchor: Bool {
        targetPolicy == .caretAnchored || originalMarkedRange == nil
    }

    func committedTextVerificationRange(for selectedRange: NSRange) -> NSRange? {
        if targetPolicy == .compositionOnly,
           let originalMarkedRange {
            return originalMarkedRange
        }
        guard selectedRange.length == 0 else { return nil }
        return caretTargets.first {
            $0.location == selectedRange.location
        }?.verificationRange
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
        caretTargets = [(location: end, verificationRange: markedRange)]
        self.targetPolicy = targetPolicy
    }

    /// Some Blink clients expose a valid caret before they expose their live
    /// marked range. Depending on renderer timing, that caret can be either the
    /// preedit start or its visual end. Keep both candidates, then let document
    /// promotion prove the one that owns the committed text.
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
              !selectionOverflow,
              selectedRange.location < Self.maxReasonableLocation,
              selectionEnd < Self.maxReasonableLocation else { return nil }

        let (advancedCaret, advancedCaretOverflow) = selectedRange.location
            .addingReportingOverflow(expectedCommittedTextLength)
        guard !advancedCaretOverflow,
              advancedCaret < Self.maxReasonableLocation else { return nil }
        let advancedCaretRange = NSRange(
            location: selectedRange.location,
            length: expectedCommittedTextLength
        )
        var targets: [(location: Int, verificationRange: NSRange)] = []
        if selectedRange.location >= expectedCommittedTextLength {
            targets.append((
                location: selectedRange.location,
                verificationRange: NSRange(
                    location: selectedRange.location - expectedCommittedTextLength,
                    length: expectedCommittedTextLength
                )
            ))
        }
        targets.append((
            location: advancedCaret,
            verificationRange: advancedCaretRange
        ))
        originalMarkedRange = nil
        caretTargets = targets
        self.targetPolicy = targetPolicy
    }

    mutating func observe(
        markedRange: NSRange,
        selectedRange: NSRange,
        committedTextIsVisible: Bool? = nil
    ) -> DeferredCompositionRetirementDecision {
        // Blink can temporarily expose the owned preedit as a selection while
        // its markedRange is unavailable. This is not a moved caret: wait for
        // collapse and verified commit instead of cancelling the pending key.
        if let originalMarkedRange,
           selectedRange == originalMarkedRange,
           markedRange == originalMarkedRange
                || markedRange.location == NSNotFound || markedRange.length == 0 {
            stableUnmarkedObservations = 0
            return .wait
        }
        if requiresCaretAnchor {
            guard committedTextVerificationRange(for: selectedRange) != nil else {
                return .cancel
            }
        }

        if markedRange.location != NSNotFound, markedRange.length > 0 {
            stableUnmarkedObservations = 0
            let ownsMarkedRange = originalMarkedRange == markedRange
                || caretTargets.contains { $0.verificationRange == markedRange }
            return ownsMarkedRange ? .wait : .cancel
        }

        if committedTextVerificationRange(for: selectedRange) != nil,
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
    private let environment: DeferredHostKeyReplayEnvironment
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
        expectedCommittedText: String?,
        confirmedMarkedRange: NSRange? = nil,
        environment: DeferredHostKeyReplayEnvironment
    ) {
        self.client = client
        self.keyCode = keyCode
        self.events = events
        self.authorization = authorization
        self.postedBoundary = postedBoundary
        self.environment = environment
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
           let confirmedMarkedRange,
           confirmedMarkedRange.length == normalizedExpectedCommittedText?.utf16.count {
            retirementGate = DeferredCompositionRetirementGate(
                markedRange: confirmedMarkedRange,
                targetPolicy: targetPolicy
            )
        }
        // Blink may expose the live preedit only as a selected range. A
        // matching length alone is not ownership proof: read the exact text
        // rendered by this adapter and recheck the field authorization.
        if retirementGate == nil,
           let normalizedExpectedCommittedText,
           !normalizedExpectedCommittedText.isEmpty {
            let selected = client.selectedRange()
            if selected.location != NSNotFound, selected.location >= 0,
               selected.location < 10_000_000,
               selected.length == normalizedExpectedCommittedText.utf16.count,
               authorization.isAllowed(),
               client.attributedSubstring(from: selected)?.string
                    .precomposedStringWithCanonicalMapping == normalizedExpectedCommittedText,
               authorization.isAllowed() {
                retirementGate = DeferredCompositionRetirementGate(
                    markedRange: selected, targetPolicy: .caretAnchored
                )
            }
        }
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
        environment.scheduleInitial(DeferredHostKeyPoll { [self] in
            deliverWhenReady()
        })
    }

    private func deliverWhenReady() {
        guard authorization.isAllowed() else {
            logSkip("stale_session")
            return
        }

        if var gate = retirementGate {
            let markedRange = client.markedRange()
            // Return also replaces a selection in rich editors. Even when its
            // caret anchor is optional, it must observe the owned selection
            // collapsing before the original composition can be replaced safely.
            let selectedRange = client.selectedRange()
            let committedTextIsVisible: Bool?
            if let verificationRange = gate.committedTextVerificationRange(
                for: selectedRange
            ),
               markedRange.location == NSNotFound || markedRange.length == 0,
               let expectedCommittedText {
                committedTextIsVisible = client
                    .attributedSubstring(from: verificationRange)?
                    .string
                    .precomposedStringWithCanonicalMapping == expectedCommittedText
            } else {
                committedTextIsVisible = nil
            }
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
                environment.scheduleRetry(DeferredHostKeyPoll { [self] in
                    deliverWhenReady()
                })
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
            postEvent: environment.postEvent,
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
        expectedMarkedRange: NSRange? = nil,
        expectedMarkedRangeIsConfirmed: Bool = true,
        environment: DeferredHostKeyReplayEnvironment = .live,
        commit: () -> Void
    ) -> Bool {
        if keyCode == KeyCode.forwardDelete,
           let expectedCommittedText,
           !expectedCommittedText.isEmpty,
           let expectedMarkedRange,
           isClientWriteAllowed(),
           let deletion = PreparedForwardDeletion.prepare(
               client: client,
               expectedCommittedText: expectedCommittedText,
               expectedMarkedRange: expectedMarkedRange,
               expectedMarkedRangeIsConfirmed: expectedMarkedRangeIsConfirmed
           ) {
            let deferredDeletion = DeferredForwardDeletion(
                prepared: deletion,
                authorization: DeferredClientWriteAuthorization(
                    isAllowed: isClientWriteAllowed
                ),
                postedBoundary: DeferredHostKeyBoundary(handler: didPost),
                environment: environment
            )
            commit()
            deferredDeletion.deliverOrSchedule()
            return true
        }

        guard let replay = prepareReplay(
            client: client,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isClientWriteAllowed: isClientWriteAllowed,
            didPost: didPost,
            expectedCommittedText: expectedCommittedText,
            confirmedMarkedRange: expectedMarkedRangeIsConfirmed ? expectedMarkedRange : nil,
            environment: environment
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
        expectedCommittedText: String?,
        environment: DeferredHostKeyReplayEnvironment = .live
    ) -> Bool {
        guard let replay = prepareReplay(
            client: client,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isClientWriteAllowed: isClientWriteAllowed,
            didPost: didPost,
            expectedCommittedText: expectedCommittedText,
            environment: environment
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
        expectedCommittedText: String?,
        confirmedMarkedRange: NSRange? = nil,
        environment: DeferredHostKeyReplayEnvironment = .live
    ) -> DeferredHostKeyReplay? {
        guard environment.canReplay(),
              isClientWriteAllowed(),
              let events = environment.makeEvents(keyCode, modifierFlags) else { return nil }

        let replay = DeferredHostKeyReplay(
            client: client,
            keyCode: keyCode,
            events: events,
            authorization: DeferredClientWriteAuthorization(
                isAllowed: isClientWriteAllowed
            ),
            postedBoundary: DeferredHostKeyBoundary(handler: didPost),
            expectedCommittedText: expectedCommittedText,
            confirmedMarkedRange: confirmedMarkedRange,
            environment: environment
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
