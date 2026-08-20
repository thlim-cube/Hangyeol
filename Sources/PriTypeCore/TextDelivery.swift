import Cocoa
import InputMethodKit

// MARK: - InputDeliveryMode

/// How composition output reaches the focused client.
enum InputDeliveryMode: Equatable {
    case immediate          // Finder desktop: defer, no marked window
    case directInsertion    // EXPERIMENTAL: real-text in-place rewrite
    case markedText         // Default: canonical marked-text composition
}

// MARK: - HostAdapterResolver

struct HostAdapterResolver {
    static func mode(for context: ClientContext) -> InputDeliveryMode {
        if context.hostSurface == .finderNonText {
            return .immediate
        }
        if context.hostSurface == .blinkNative,
           context.documentAccessSafe {
            return .directInsertion
        }
        if (ConfigurationManager.shared.experimentalDirectInsertion
            || ClientCompatibilityPolicy.prefersDirectInsertionForComposition(
                bundleId: context.bundleId
            )),
           context.documentAccessSafe,
           !ClientCompatibilityPolicy.directInsertionDenied(bundleId: context.bundleId) {
            return .directInsertion
        }
        return .markedText
    }

    static func makeAdapter(
        for client: IMKTextInput,
        context: ClientContext
    ) -> BaseClientAdapter {
        switch mode(for: context) {
        case .immediate:
            return ImmediateModeAdapter(client: client, bundleId: context.bundleId)
        case .directInsertion:
            DebugLogger.event("delivery.adapter_created", metadata: [
                .state("mode", "direct_insertion")
            ])
            return DirectInsertionAdapter(client: client, bundleId: context.bundleId)
        case .markedText:
            return MarkedTextAdapter(client: client, bundleId: context.bundleId)
        }
    }
}

// MARK: - TextDeliveryPolicy

/// Single decision point for how composition is delivered to a client.
///
/// Default is canonical marked text. Direct insertion (experimental) is attempted in
/// EVERY app when the flag is ON — there is no per-app allowlist. The only gate is the
/// activation probe `documentAccessSafe`: apps that neither advertise TSM document
/// access nor report a usable selection range physically cannot do in-place rewrites,
/// so they keep the marked-text path. Apps that pass the probe but misbehave at runtime degrade to
/// marked text via the adapter's caret-stability guard / bail path — so enabling it
/// everywhere never corrupts text, it just falls back where it can't work.
enum TextDeliveryPolicy {
    static func mode(for context: ClientContext) -> InputDeliveryMode {
        HostAdapterResolver.mode(for: context)
    }

    static func makeAdapter(for client: IMKTextInput, context: ClientContext) -> BaseClientAdapter {
        HostAdapterResolver.makeAdapter(for: client, context: context)
    }
}

// MARK: - MarkedTextPayload

/// Host-compatible payload for canonical marked-text composition.
///
/// ⚠️ TRANSPORT REALITY on macOS 26 (measured 2026-06 with an NSTextInputClient
/// probe on the live IMK path, enumerating every payload we can send): underline
/// style 0 + `.clear`, single + alpha-1/255, `NSMarkedClauseSegment` 1…9 (every
/// TSM hilite category incl. kNoHilite), and even an attribute-LESS string ALL
/// arrive at the client as the same regenerated pair `NSUnderline=2 + accent
/// blue`. The receiving framework discards IME-provided styling and synthesizes
/// the system marked-text style — distinct categories that carry distinct styles
/// in `IMKInputController.mark(forStyle:at:)` dictionaries (e.g. style 3 → gray
/// U=3, style 4 → gray U=1) arrive indistinguishable, so the channel is fully
/// dead, not merely quantized. On macOS 26 NO setMarkedText attributes can hide
/// the composition underline, for any IME (Apple's Korean IME draws the same
/// underline). The only underline-free composition is to not use marked text at
/// all — `DirectInsertionAdapter` via `experimentalDirectInsertion`.
///
/// On macOS 26, Chrome and Electron hosts can trap inside AppKit's
/// `_forceAttributedString` for attributed marked payloads (`CFEqual` receives a
/// null argument). Chromium web-content clients accept NSString directly. Native
/// Blink-host fields such as Chrome's omnibox use direct insertion instead and do
/// not enter this payload path.
enum MarkedTextPayload {
    static func value(_ text: String, forBundleId bundleId: String) -> Any {
        switch ClientCompatibilityPolicy.compositionRenderer(bundleId: bundleId) {
        case .blink:
            return text as NSString
        case .system:
            return NSAttributedString(
                string: text,
                attributes: [
                    .underlineStyle: 0,
                    .underlineColor: NSColor.clear
                ]
            )
        }
    }
}

// MARK: - BaseClientAdapter

/// Base adapter class with common IMKTextInput operations
/// Subclasses override setMarkedText for different behaviors
class BaseClientAdapter: NSObject, HangulComposerDelegate {
    let client: IMKTextInput
    private var clientWriteIsAllowed: () -> Bool = { true }
    private var deferredHostKeyBoundary = DeferredHostKeyBoundary()

    /// Host bundle id, for engine-tuned preedit styling.
    let bundleId: String

    /// The delivery mode this adapter implements. Used by `InputSession` to detect
    /// when the resolved policy no longer matches the live adapter (e.g. the
    /// experimental flag flipped mid-session) and the adapter must be rebuilt.
    var deliveryMode: InputDeliveryMode { .markedText }

    /// Exact marked text rendered by this adapter for a host-key transaction.
    /// Non-marked adapters do not expose a document-promotion proof.
    var hostTransactionMarkedText: String? { nil }

    init(client: IMKTextInput, bundleId: String) {
        self.client = client
        self.bundleId = bundleId
    }

    func setClientWriteValidator(_ validator: @escaping () -> Bool) {
        clientWriteIsAllowed = validator
    }

    func setDeferredHostKeyBoundaryHandler(
        _ handler: @escaping (UInt16) -> Void
    ) {
        deferredHostKeyBoundary = DeferredHostKeyBoundary(handler: handler)
    }

    func recordDeferredHostKeyPassedToHost(keyCode: UInt16) {
        deferredHostKeyBoundary.handler(keyCode)
    }

    final func canWriteToClient() -> Bool {
        clientWriteIsAllowed()
    }

    func insertText(_ text: String) {
        _ = tryInsertText(text)
    }

    func tryInsertText(_ text: String) -> Bool {
        guard !text.isEmpty, canWriteToClient() else { return false }
        // Canonical IMK commit: pass NSNotFound so the host replaces the current
        // marked text automatically. This matches Apple's own input methods and is
        // what native hosts (e.g. KakaoTalk) expect. Passing an explicit marked
        // range here desynced KakaoTalk's composition (stranded marked text +
        // missing commit on focus loss).
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        return true
    }

    func tryScheduleHostKey(keyCode: UInt16, modifierFlags: UInt) -> Bool {
        guard IOKitManager.hasAccessibilityPermission(),
              canWriteToClient(),
              let events = DeferredHostKeyDelivery.makeEvents(
                  keyCode: keyCode,
                  modifierFlags: modifierFlags
              ) else { return false }

        let replayAuthorization = DeferredClientWriteAuthorization(
            isAllowed: clientWriteIsAllowed
        )
        let replay = DeferredHostKeyReplay(
            client: client,
            keyCode: keyCode,
            events: events,
            authorization: replayAuthorization,
            postedBoundary: deferredHostKeyBoundary,
            expectedCommittedText: hostTransactionMarkedText
        )
        guard replay.isArmed else { return false }
        replay.schedule()
        return true
    }

    func setMarkedText(_ text: String) {
        // Default: no-op, subclasses override
    }

    func textBeforeCursor(length: Int) -> String? {
        let selRange = client.selectedRange()
        guard selRange.location != NSNotFound, selRange.location < 10000000 else { return nil } // Protect against Chromium garbage values

        let location = max(0, selRange.location - length)
        let actualLength = selRange.location - location
        guard actualLength > 0 else { return "" }

        let charRange = NSRange(location: location, length: actualLength)
        return client.attributedSubstring(from: charRange)?.string
    }

    func replaceTextBeforeCursor(length: Int, with text: String) {
        _ = tryReplaceTextBeforeCursor(length: length, with: text)
    }

    func tryReplaceTextBeforeCursor(length: Int, with text: String) -> Bool {
        let selRange = client.selectedRange()
        guard canWriteToClient(),
              selRange.location != NSNotFound,
              selRange.location < 10000000,
              selRange.location >= length else { return false }

        let replacementRange = NSRange(location: selRange.location - length, length: length)
        client.insertText(text, replacementRange: replacementRange)
        return true
    }
}

/// The adapter and its validator are main-thread-only. This box crosses only the
/// compiler's DispatchQueue sendability boundary; the closure still runs on main.
private final class DeferredClientWriteAuthorization: @unchecked Sendable {
    let isAllowed: () -> Bool

    init(isAllowed: @escaping () -> Bool) {
        self.isAllowed = isAllowed
    }
}

/// Main-thread callback captured by the deferred CGEvent delivery.
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

/// A host-owned key may leave Blink only after the exact marked range that was
/// committed has retired. Forward Delete additionally keeps the caret anchored
/// because it targets the character after that caret; Return does not.
struct DeferredCompositionRetirementGate {
    private static let maxReasonableLocation = 10_000_000

    private let originalMarkedRange: NSRange
    private let expectedCaretLocation: Int
    private let targetPolicy: DeferredHostKeyTargetPolicy
    private var stableUnmarkedObservations = 0

    var requiresCaretAnchor: Bool {
        targetPolicy == .caretAnchored
    }

    var committedTextVerificationRange: NSRange? {
        targetPolicy == .caretAnchored ? originalMarkedRange : nil
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
        expectedCaretLocation = end
        self.targetPolicy = targetPolicy
    }

    mutating func observe(
        markedRange: NSRange,
        selectedRange: NSRange,
        committedTextIsVisible: Bool? = nil
    ) -> DeferredCompositionRetirementDecision {
        if targetPolicy == .caretAnchored {
            guard selectedRange.location == expectedCaretLocation,
                  selectedRange.length == 0 else { return .cancel }
        }

        if markedRange.location != NSNotFound, markedRange.length > 0 {
            stableUnmarkedObservations = 0
            return markedRange == originalMarkedRange ? .wait : .cancel
        }

        if targetPolicy == .caretAnchored,
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
        self.expectedCommittedText = expectedCommittedText?
            .precomposedStringWithCanonicalMapping
        let targetPolicy: DeferredHostKeyTargetPolicy = keyCode == KeyCode.forwardDelete
            ? .caretAnchored
            : .compositionOnly
        retirementGate = DeferredCompositionRetirementGate(
            markedRange: client.markedRange(),
            targetPolicy: targetPolicy
        )
    }

    func schedule() {
        DispatchQueue.main.async { [self] in
            deliverWhenReady()
        }
    }

    private func deliverWhenReady() {
        guard authorization.isAllowed() else {
            DebugLogger.event("input.host_key_replay_skipped", metadata: [
                .state("reason", "stale_session")
            ])
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
                DebugLogger.event("input.host_key_replay_skipped", metadata: [
                    .state("reason", "host_key_target_changed")
                ])
                return
            case .wait:
                pollCount += 1
                guard pollCount < Self.maxRetirementPolls else {
                    DebugLogger.event("input.host_key_replay_skipped", metadata: [
                        .state("reason", "marked_text_not_retired")
                    ])
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
                    deliverWhenReady()
                }
                return
            }
        }

        guard authorization.isAllowed() else {
            DebugLogger.event("input.host_key_replay_skipped", metadata: [
                .state("reason", "stale_session")
            ])
            return
        }
        events.keyDown.post(tap: .cghidEventTap)
        events.keyUp.post(tap: .cghidEventTap)
        postedBoundary.handler(keyCode)
        DebugLogger.event("input.host_key_replay_delivered", metadata: [
            .count("retirement_polls", pollCount)
        ])
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
            event.setIntegerValueField(
                .eventSourceUserData,
                value: replayMarker
            )
        }
        return Events(keyDown: keyDown, keyUp: keyUp)
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

// MARK: - MarkedTextAdapter

/// Standard adapter for canonical marked-text composition display.
final class MarkedTextAdapter: BaseClientAdapter {
    private var renderedMarkedText = ""

    override var hostTransactionMarkedText: String? {
        renderedMarkedText.isEmpty ? nil : renderedMarkedText
    }

    override func tryInsertText(_ text: String) -> Bool {
        let didInsert = super.tryInsertText(text)
        if didInsert {
            renderedMarkedText = ""
        }
        return didInsert
    }

    override func setMarkedText(_ text: String) {
        guard canWriteToClient() else { return }
        renderedMarkedText = text
        // Canonical marked-text protocol, matching Apple's own input methods:
        // set the marked text directly with replacementRange = NSNotFound (an
        // empty string clears the composition). Blink web content receives a plain
        // NSString to avoid macOS 26's unstable attributed-string path; Blink-native
        // fields use DirectInsertionAdapter. Native/WebKit hosts retain clear-
        // underline attributes. The previous non-canonical path
        // (clearing via insertText("") over an explicit marked
        // range) left native hosts like KakaoTalk in an inconsistent composition
        // state — a stranded/underlined preedit that never committed on focus loss.
        client.setMarkedText(
            MarkedTextPayload.value(text, forBundleId: bundleId),
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }
}

// MARK: - ImmediateModeAdapter

/// Immediate mode adapter for non-text contexts (e.g., Finder desktop)
/// Skips setMarkedText to prevent floating composition window
final class ImmediateModeAdapter: BaseClientAdapter {
    override var deliveryMode: InputDeliveryMode { .immediate }
    // Inherits no-op setMarkedText from base class
}

// MARK: - DirectInsertionAdapter

/// EXPERIMENTAL (Phase 3): Windows-style direct insertion. There is no marked
/// text — the in-progress syllable is written as REAL text and rewritten in place
/// each keystroke. This isolates all direct-insertion state here so `HangulComposer`
/// stays unchanged: the composer keeps calling `insertText`/`setMarkedText` and this
/// adapter reinterprets them as in-place real-text rewrites.
///
/// Selected when `experimentalDirectInsertion` is ON (or a compatibility policy
/// explicitly prefers it), the activation probe found `documentAccessSafe`, and the
/// host is not denylisted. OFF by default. See Docs/KoreanWindowsInputFeasibility.md.
final class DirectInsertionAdapter: BaseClientAdapter {
    override var deliveryMode: InputDeliveryMode { .directInsertion }

    /// Whether this session currently renders its PriType-owned preedit through the
    /// canonical marked-text protocol after document access became unreliable.
    var usesMarkedTextFallback: Bool { fellBackToMarked }

    /// Exact marked text last rendered by this adapter. Lifecycle cleanup may touch
    /// the host only while the current marked range still contains this content.
    private(set) var markedTextFallbackContent = ""

    /// UTF-16 length of the live (in-progress) syllable currently sitting in the
    /// document as real text. 0 when there is no live preedit.
    private var livePreeditLength: Int = 0
    /// The exact string we last wrote as the live preedit. Used to VERIFY the live
    /// region is still where we think before deleting it (caret-stability guard).
    private var livePreeditText: String = ""
    /// Caret position we expect (UTF-16 offset) right after our last edit. When the
    /// host reports the SAME caret on the next keystroke, the live region is provably
    /// intact and we can SKIP the expensive attributedSubstring read-back (perf).
    private var expectedCaret: Int = NSNotFound
    /// Once the client proves it lacks reliable document access mid-composition,
    /// degrade to marked text for the rest of the session rather than strand text.
    private var fellBackToMarked = false
    /// An invalid selection after a real preedit was already inserted leaves no safe
    /// range for replacing that text. Preserve the last verified document state and
    /// suppress further composition writes until the engine ends; guessing a delete
    /// range or showing the full preedit as marked text would duplicate/corrupt text.
    private var preservingUnverifiedLivePreedit = false

    /// Clear live-preedit tracking. Called by the session whenever composition
    /// ends out-of-band (focus loss, mouse-click commit, secure passthrough). Also
    /// re-arms direct insertion: a clean finalize lets a host that momentarily
    /// returned a bad selectionRange try direct insertion again.
    func resetPreeditTracking() {
        livePreeditLength = 0
        livePreeditText = ""
        expectedCaret = NSNotFound
        fellBackToMarked = false
        markedTextFallbackContent = ""
        preservingUnverifiedLivePreedit = false
    }

    private func renderMarkedFallback(_ text: String) -> Bool {
        guard canWriteToClient() else { return false }
        markedTextFallbackContent = text
        client.setMarkedText(
            MarkedTextPayload.value(text, forBundleId: bundleId),
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        return true
    }

    /// Replace the live-preedit region (if any) with `text` as REAL text.
    /// `keepingLive` = true means `text` is the new live preedit; false means it is
    /// a finalized commit that becomes permanent (tracked length resets to 0).
    @discardableResult
    private func rewriteLivePreedit(with text: String, keepingLive: Bool) -> Bool {
        guard canWriteToClient() else { return false }
        if fellBackToMarked {
            return renderMarkedFallback(text)
        }

        if preservingUnverifiedLivePreedit {
            // Either an empty marked update or a finalized insert means the
            // composer ended the unsafe composition. The finalized text is still
            // unverified and must be dropped, but the next delivery belongs to a
            // new composition (or a following Space) and can try direct insertion.
            if !keepingLive || text.isEmpty {
                resetPreeditTracking()
            }
            return false
        }

        let tStart = CFAbsoluteTimeGetCurrent()
        let caret = client.selectedRange().location
        let tAfterSel = CFAbsoluteTimeGetCurrent()
        var readbackMs = 0.0
        let hasUsableCaret = caret != NSNotFound
            && caret >= 0
            && caret < DirectInsertionPlanner.maxReasonableLocation

        // A finalized insert with no live preedit does not need a document range:
        // canonical IMK insertion can commit it at the host-owned selection. Turning
        // permanent text (for example, Space) into marked fallback would let the next
        // preedit replace it when selectedRange remains unavailable.
        if livePreeditLength == 0, !keepingLive, !hasUsableCaret {
            let inserted = super.tryInsertText(text)
            expectedCaret = NSNotFound
            return inserted
        }

        // Once real preedit text exists, an unusable selection cannot safely be
        // converted to a full marked preedit: the host would later commit both the
        // old real text and the new marked text (for example, `ㄱ가`). Never guess
        // where to delete. Keep the last verified real text unchanged and let the
        // session's direct-finalize path discard the newer engine-only composition.
        if livePreeditLength > 0, !hasUsableCaret {
            livePreeditLength = 0
            livePreeditText = ""
            expectedCaret = NSNotFound
            preservingUnverifiedLivePreedit = true
            DebugLogger.event("delivery.fail_closed", metadata: [
                .state("reason", "invalid_selection_with_live_preedit")
            ])
            return false
        }

        // CARET-STABILITY GUARD — prevents the direct-insertion corruption class.
        // The live preedit is REAL text the user can click or arrow away from, and
        // because there is no marked range IMK does NOT notify us when the caret moves.
        //
        // FAST PATH: if the host reports the caret exactly where our last edit left it
        // (`caret == expectedCaret`), the live region is provably intact — skip the
        // expensive attributedSubstring read-back (one synchronous IPC per keystroke,
        // a real latency source in some native hosts). Only when the caret differs do
        // we pay for the read-back to verify before deleting; on any mismatch we
        // abandon tracking and insert fresh — never deleting text we cannot verify.
        if livePreeditLength > 0 && caret != expectedCaret {
            let tReadStart = CFAbsoluteTimeGetCurrent()
            let actual: String?
            if hasUsableCaret, caret >= livePreeditLength {
                let region = NSRange(location: caret - livePreeditLength, length: livePreeditLength)
                actual = client.attributedSubstring(from: region)?.string
            } else {
                actual = nil
            }
            readbackMs = (CFAbsoluteTimeGetCurrent() - tReadStart) * 1000
            let verified = DirectInsertionPlanner.liveRegionIsVerified(
                caret: caret,
                livePreeditLength: livePreeditLength,
                actualSubstring: actual,
                expectedText: livePreeditText
            )
            if !verified {
                livePreeditLength = 0
                livePreeditText = ""
                DebugLogger.event("delivery.preedit_tracking_abandoned")
            }
        }

        let plan = DirectInsertionPlanner.plan(
            cursorLocation: caret,
            livePreeditLength: livePreeditLength,
            textUTF16Count: text.utf16.count,
            keepingLive: keepingLive
        )
        if plan.bailed {
            // Document access unreliable: degrade to marked text to avoid stranding
            // a half-jamo. (Should be rare — probe + denylist gate this.)
            fellBackToMarked = true
            livePreeditLength = 0
            livePreeditText = ""
            expectedCaret = NSNotFound
            let rendered = renderMarkedFallback(text)
            DebugLogger.event("delivery.fallback", metadata: [
                .state("from", "direct_insertion"),
                .state("to", "marked_text"),
                .state("reason", "invalid_selection")
            ])
            return rendered
        }

        let tBeforeInsert = CFAbsoluteTimeGetCurrent()
        guard canWriteToClient() else { return false }
        client.insertText(text, replacementRange: plan.replaceRange)
        let tEnd = CFAbsoluteTimeGetCurrent()

        livePreeditLength = plan.newLivePreeditLength
        livePreeditText = keepingLive ? text : ""
        expectedCaret = plan.replaceRange.location + text.utf16.count

        // Instrumentation: surface a slow rewrite with a per-IPC breakdown so latency
        // ("렉") can be pinpointed. Only logs the slow ones to avoid spam.
        let totalMs = (tEnd - tStart) * 1000
        if totalMs > 8 {
            DebugLogger.event("delivery.direct_insert_slow", metadata: [
                .durationMicroseconds("total", UInt64(max(0, totalMs * 1_000))),
                .durationMicroseconds("selection", UInt64(max(0, (tAfterSel - tStart) * 1_000_000))),
                .durationMicroseconds("readback", UInt64(max(0, readbackMs * 1_000))),
                .durationMicroseconds("insert", UInt64(max(0, (tEnd - tBeforeInsert) * 1_000_000))),
                .count("live_preedit_length", livePreeditLength)
            ])
        }
        return true
    }

    override func tryInsertText(_ text: String) -> Bool {
        if fellBackToMarked {
            return super.tryInsertText(text)   // base: NSNotFound auto-replaces marked text
        }
        guard !text.isEmpty else { return false }
        // A finalized insert replaces the live preedit (if any) and becomes permanent.
        // This is also why a hard commit cannot double-insert: committing the live
        // syllable rewrites the same region it already occupies.
        return rewriteLivePreedit(with: text, keepingLive: false)
    }

    override func setMarkedText(_ text: String) {
        // No marked text in direct insertion: render the preedit as real text in place.
        rewriteLivePreedit(with: text, keepingLive: true)
    }

    override func tryReplaceTextBeforeCursor(length: Int, with text: String) -> Bool {
        guard !preservingUnverifiedLivePreedit else { return false }
        // Committed-text edit (e.g. double-space period); no live preedit involved.
        guard super.tryReplaceTextBeforeCursor(length: length, with: text) else {
            return false
        }
        livePreeditLength = 0
        return true
    }
}
