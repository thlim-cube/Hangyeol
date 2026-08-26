import Cocoa
import InputMethodKit

// Host delivery implementations. Adapter selection belongs to
// `HostAdapterResolver`; deferred host-owned keys belong to `HostKeyTransaction`.

// MARK: - BaseClientAdapter

/// Base adapter class with common IMKTextInput operations
/// Subclasses override setMarkedText for different behaviors
class BaseClientAdapter: NSObject, HangulComposerDelegate {
    let client: IMKTextInput
    private var clientWriteIsAllowed: () -> Bool = { true }
    private var deferredHostKeyBoundaryHandler: (UInt16) -> Void = { _ in }

    let hostSurface: HostSurface

    /// The delivery mode this adapter implements. Used by `InputSession` to detect
    /// when the resolved policy no longer matches the live adapter (e.g. the
    /// experimental flag flipped mid-session) and the adapter must be rebuilt.
    var deliveryMode: InputDeliveryMode { .markedText }

    /// Exact marked text rendered by this adapter for a host-key transaction.
    /// Non-marked adapters do not expose a document-promotion proof.
    var hostTransactionMarkedText: String? { nil }

    /// Hangyeol-owned marked range captured before the host can report a delayed
    /// or virtual caret. Only canonical marked-text adapters expose this range.
    var hostTransactionMarkedRange: NSRange? { nil }

    init(client: IMKTextInput, hostSurface: HostSurface) {
        self.client = client
        self.hostSurface = hostSurface
    }

    func setClientWriteValidator(_ validator: @escaping () -> Bool) {
        clientWriteIsAllowed = validator
    }

    func setDeferredHostKeyBoundaryHandler(
        _ handler: @escaping (UInt16) -> Void
    ) {
        deferredHostKeyBoundaryHandler = handler
    }

    func recordDeferredHostKeyPassedToHost(keyCode: UInt16) {
        deferredHostKeyBoundaryHandler(keyCode)
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
        HostKeyTransaction.schedule(
            client: client,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isClientWriteAllowed: clientWriteIsAllowed,
            didPost: deferredHostKeyBoundaryHandler,
            expectedCommittedText: hostTransactionMarkedText
        )
    }

    func tryPerformHostKeyTransaction(
        keyCode: UInt16,
        modifierFlags: UInt,
        commit: () -> Void
    ) -> Bool {
        HostKeyTransaction.perform(
            client: client,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isClientWriteAllowed: clientWriteIsAllowed,
            didPost: deferredHostKeyBoundaryHandler,
            expectedCommittedText: hostTransactionMarkedText,
            expectedMarkedRange: hostTransactionMarkedRange,
            commit: commit
        )
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

// MARK: - MarkedTextAdapter

/// Standard adapter for canonical marked-text composition display.
final class MarkedTextAdapter: BaseClientAdapter {
    private static let maxReasonableLocation = 10_000_000

    private var renderedMarkedText = ""
    private var renderedMarkedLocation = NSNotFound
    private var renderedMarkedLocationIsConfirmed = false

    override var hostTransactionMarkedText: String? {
        renderedMarkedText.isEmpty ? nil : renderedMarkedText
    }

    override var hostTransactionMarkedRange: NSRange? {
        recoverRenderedMarkedLocation(for: renderedMarkedText)
        guard renderedMarkedLocation != NSNotFound,
              renderedMarkedLocationIsConfirmed,
              !renderedMarkedText.isEmpty else { return nil }
        return NSRange(
            location: renderedMarkedLocation,
            length: renderedMarkedText.utf16.count
        )
    }

    override func tryInsertText(_ text: String) -> Bool {
        let didInsert = super.tryInsertText(text)
        if didInsert {
            renderedMarkedText = ""
            renderedMarkedLocation = NSNotFound
            renderedMarkedLocationIsConfirmed = false
        }
        return didInsert
    }

    override func setMarkedText(_ text: String) {
        guard canWriteToClient() else { return }
        recoverRenderedMarkedLocation(for: renderedMarkedText)
        if renderedMarkedText.isEmpty, !text.isEmpty {
            let selection = client.selectedRange()
            renderedMarkedLocation = selection.location != NSNotFound
                && selection.length == 0
                ? selection.location
                : NSNotFound
            renderedMarkedLocationIsConfirmed = false
        }
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
            MarkedTextPayload.value(text, for: hostSurface),
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        recoverRenderedMarkedLocation(for: text)
        if text.isEmpty {
            renderedMarkedLocation = NSNotFound
            renderedMarkedLocationIsConfirmed = false
        }
    }

    /// Blink can expose neither selection nor marked range on the first preedit
    /// update, then publish the owned range on a later jamo or Backspace update.
    /// Keep retrying while the start is not confirmed by a live range; its exact
    /// length proves that the location belongs to the text this adapter rendered.
    private func recoverRenderedMarkedLocation(for text: String) {
        guard !renderedMarkedLocationIsConfirmed,
              !text.isEmpty else { return }
        let liveRange = client.markedRange()
        let (rangeEnd, overflow) = liveRange.location.addingReportingOverflow(
            liveRange.length
        )
        guard liveRange.location != NSNotFound,
              liveRange.location >= 0,
              liveRange.location < Self.maxReasonableLocation,
              liveRange.length == text.utf16.count,
              !overflow,
              rangeEnd < Self.maxReasonableLocation else { return }
        renderedMarkedLocation = liveRange.location
        renderedMarkedLocationIsConfirmed = true
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
/// host is not denylisted. OFF by default.
final class DirectInsertionAdapter: BaseClientAdapter {
    override var deliveryMode: InputDeliveryMode { .directInsertion }

    /// Whether this session currently renders its Hangyeol-owned preedit through the
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
            MarkedTextPayload.value(text, for: hostSurface),
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
