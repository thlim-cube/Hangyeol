import Cocoa
import InputMethodKit

// MARK: - CompositionFinalizeReason

/// Why a composition is being finalized. Diagnostics only — every reason takes the
/// SAME single code path (`InputSession.finalize`), which is the whole point: the
/// KakaoTalk stranded-preedit class of bugs came from different session-ending events
/// each having their own slightly different commit sequence.
enum CompositionFinalizeReason: String {
    case appDeactivate          // NSWorkspace deactivation (earliest, host still accepts insertText)
    case deactivateServer       // IMK deactivateServer (fallback; native hosts may already ignore)
    case mouseCommit            // IMK commitComposition (click outside the composition)
    case modeTransition         // PriType custom toggle key (한/영)
    case inputSourceOwnership   // macOS took ownership or reselected PriType
    case keyboardLayoutChange   // 두벌식/세벌식 layout switch mid-composition
    case sessionReplacement     // a different IMK client became active first
    case deliveryModeChange     // marked/direct policy changed while the session stayed active

    var diagnosticLabel: StaticString {
        switch self {
        case .appDeactivate: "app_deactivate"
        case .deactivateServer: "deactivate_server"
        case .mouseCommit: "mouse_commit"
        case .modeTransition: "mode_transition"
        case .inputSourceOwnership: "input_source_ownership"
        case .keyboardLayoutChange: "keyboard_layout_change"
        case .sessionReplacement: "session_replacement"
        case .deliveryModeChange: "delivery_mode_change"
        }
    }
}

// MARK: - InputSession

/// One live text-input session: a client, its analyzed context, the delivery adapter,
/// duplicate-keyDown state, and the focus-loss safety net — owned together so they can
/// never drift apart.
///
/// Lifecycle: created in `activateServer` (or on a client change observed in
/// `handle()`), kept across `deactivateServer` so an early `handle()` can refresh
/// its context, and replaced when a different client appears.
///
/// INVARIANT: `finalize(reason:)` is the ONLY way an in-progress composition ends
/// against this session's client. It is idempotent (no-op without active composition)
/// and host-agnostic — no bundle-ID special cases.
final class InputSession: @unchecked Sendable {
    struct FocusLossActivation: Equatable {
        fileprivate let generation: UInt64
    }

    struct ContextStateLease {
        fileprivate let revision: UInt64
        fileprivate let generation: UInt64
    }

    private enum ContextRefreshRequirement: Equatable {
        case none
        case sameClientReactivation
        case fieldIdentityMayHaveChanged
    }

    private struct DeferredMarkedTextCleanupToken {
        let generation: UInt64
        let normalizedContent: String
    }

    let client: IMKTextInput
    private(set) var context: ClientContext
    private(set) var adapter: BaseClientAdapter
    let composer: HangulComposer

    /// The next input boundary may need fresh client analysis. Repeated activation is
    /// provisional until the live marked range proves the canonical marked preedit is
    /// still owned; explicit navigation/lifecycle boundaries remain stronger.
    private var contextRefreshRequirement: ContextRefreshRequirement = .none
    var contextNeedsRefresh: Bool {
        contextRefreshRequirement != .none
    }

    /// Commits the composition early on app-focus-loss (see `armFocusLossFinalizer`).
    private var focusLossObserver: Any?

    /// Identifies the activation that installed `focusLossObserver`. A client insert
    /// performed by the observer can synchronously reactivate the same IMK session;
    /// the older callback must not disarm or retire that newer activation.
    private var focusLossFinalizerGeneration: UInt64 = 0

    // Duplicate-keyDown suppression (some hosts, e.g. KakaoTalk, deliver the same
    // physical keyDown twice — double-processing input, notably one backspace
    // decomposing TWO jamo). Applies to every delivery mode; the duplicate is a
    // property of the host's event delivery, not of how we render composition.
    private var keyEventDeduplicator = KeyEventDeduplicator()

    /// Disposition of the previous deduplication chain. Exact full-signature
    /// duplicates remain recognizable after the same-turn guard expires, so retain
    /// this until a real `.process` event replaces `KeyEventDeduplicator.previous`.
    /// A Hanja candidate panel or a client compatibility path can consume a field
    /// boundary key; its duplicate must not be mistaken for host navigation.
    private var previousHostFieldBoundaryPassedToHost = false

    /// Increments whenever a re-analysis may refer to a different field. InputMethodKit
    /// can reuse one client object across fields, so object identity alone cannot prove
    /// that a later marked range still belongs to PriType's previous preedit.
    private var contextGeneration: UInt64 = 0

    /// Changes whenever a synchronous client callback can invalidate an in-flight
    /// context analysis. This is separate from the field generation because merely
    /// marking a field unknown must revoke the outer analysis before a replacement
    /// field has been classified.
    private var contextStateRevision: UInt64 = 0

    /// The most recent generation that explicitly passed the nonsecure gate. A new
    /// session remains unclassified until the controller authorizes it at an input
    /// boundary; lifecycle callbacks can never grant this permission themselves.
    private var lastNonSecureGeneration: UInt64?

    /// Exact marked preedit owned when a write-free discard became necessary.
    /// Cleanup requires both the same field generation and the same normalized text.
    private var deferredMarkedTextCleanupToken: DeferredMarkedTextCleanupToken?

    /// A newly activated or still-unclassified field must not receive
    /// `overrideKeyboardWithKeyboardNamed:`. Its first nonsecure input boundary
    /// synchronizes the Roman layout before the selected mode handles a key.
    private var needsDeferredRomanKeyboardLayoutSync = true
    #if DEBUG
    private var deferredRomanKeyboardLayoutTrace: ToggleLatencyTrace?
    #endif

    /// Invalidates the event-tap Hanja snapshot through the owning controller. The
    /// controller verifies process-wide ownership before publishing, so a late
    /// lifecycle callback from an older session cannot overwrite the active state.
    private let invalidateHanjaShortcutSessionState: () -> Void

    /// Releases the process-active controller only when this session still belongs to
    /// it. Injected by the controller so focus-loss behavior remains session-testable.
    private let retireActiveControllerAfterFocusLoss: (InputSession) -> Void

    init(
        client: IMKTextInput,
        context: ClientContext,
        composer: HangulComposer,
        invalidateHanjaShortcutSessionState: @escaping () -> Void = {},
        retireActiveControllerAfterFocusLoss: @escaping (InputSession) -> Void = { _ in }
    ) {
        self.client = client
        self.context = context
        self.composer = composer
        self.invalidateHanjaShortcutSessionState = invalidateHanjaShortcutSessionState
        self.retireActiveControllerAfterFocusLoss = retireActiveControllerAfterFocusLoss
        self.adapter = TextDeliveryPolicy.makeAdapter(for: client, context: context)
        configureClientWriteValidator(on: adapter)
    }

    deinit {
        cancelDeferredRomanKeyboardLayoutSync()
        disarmFocusLossFinalizer()
    }

    func matches(_ candidate: IMKTextInput) -> Bool {
        client === candidate
    }

    // MARK: Context lifecycle

    /// Replace the analyzed context for the same client. Delivery-policy changes are
    /// applied separately, after the controller classifies the refreshed field as
    /// secure or nonsecure; rebuilding here could finalize into a password field.
    /// Re-arms the focus-loss finalizer when the owning app changed.
    func refreshContext(
        _ newContext: ClientContext,
        fieldIdentityMayHaveChanged: Bool = false
    ) {
        contextStateRevision &+= 1
        invalidateHanjaShortcutSessionState()
        let oldBundleId = context.bundleId
        context = newContext
        if fieldIdentityMayHaveChanged {
            composer.clearLocalBuffer()
            CursorRectResolver.invalidateCache()
            contextGeneration &+= 1
        }
        contextRefreshRequirement = .none
        if focusLossObserver != nil, newContext.bundleId != oldBundleId {
            armFocusLossFinalizer()
        }
    }

    func markContextStale() {
        contextStateRevision &+= 1
        invalidateHanjaShortcutSessionState()
        composer.resetTextConvenienceState()
        contextRefreshRequirement = .fieldIdentityMayHaveChanged
    }

    /// Repeated `activateServer` can be an Electron/Chromium quirk or a real
    /// programmatic field move. Defer that distinction until fresh context and the
    /// client's live marked range can be checked together. Never downgrade a proven
    /// Tab, commit, deactivate, mouse, or controller-handoff boundary.
    func markContextStaleForSameClientReactivation() {
        contextStateRevision &+= 1
        invalidateHanjaShortcutSessionState()
        guard contextRefreshRequirement == .none else { return }
        contextRefreshRequirement = .sameClientReactivation
    }

    /// Activation has not passed the current field's secure-input gate yet. A
    /// layout mismatch must therefore drop old composition without using its
    /// retained delegate, then rebuild the engine for the configured layout.
    func refreshKeyboardLayoutForStaleActivation(id: String) {
        guard contextNeedsRefresh, composer.keyboardLayoutId != id else { return }
        discardCompositionWithoutClientWrite(rebuildAdapter: false)
        composer.updateKeyboardLayout(id: id)
    }

    /// Refresh a reactivated session before any operation that depends on the current
    /// field's identity or delivery policy. Key input and external Hanja shortcuts use
    /// the same gate so a shortcut arriving before the first keyDown cannot capture a
    /// snapshot-less candidate interaction.
    @discardableResult
    func refreshContextIfNeeded(
        using analyze: (IMKTextInput) -> ClientContext
    ) -> Bool {
        guard contextRefreshRequirement != .none else { return false }
        let revision = contextStateRevision
        let refreshRequirement = contextRefreshRequirement
        let newContext = analyze(client)
        guard contextStateRevision == revision,
              contextRefreshRequirement == refreshRequirement else {
            return false
        }
        let fieldIdentityMayHaveChanged: Bool
        switch contextRefreshRequirement {
        case .none:
            return false
        case .sameClientReactivation:
            fieldIdentityMayHaveChanged = !canPreserveMarkedComposition(in: newContext)
        case .fieldIdentityMayHaveChanged:
            fieldIdentityMayHaveChanged = true
        }
        guard contextStateRevision == revision,
              contextRefreshRequirement == refreshRequirement else {
            return false
        }
        refreshContext(
            newContext,
            fieldIdentityMayHaveChanged: fieldIdentityMayHaveChanged
        )
        return true
    }

    /// Same client identity is not enough: web views can move focus between normal
    /// fields without Tab/deactivate callbacks. Preserve only a canonical marked
    /// composition whose live range and input policy still match exactly. Direct and
    /// immediate delivery deliberately fail closed because they have no marked-range
    /// ownership proof at this boundary.
    private func canPreserveMarkedComposition(in newContext: ClientContext) -> Bool {
        guard context.bundleId == newContext.bundleId,
              context.hasTextInputCapability == newContext.hasTextInputCapability,
              context.isLikelyDesktopArea == newContext.isLikelyDesktopArea,
              context.isLightweight == newContext.isLightweight,
              context.documentAccessSafe == newContext.documentAccessSafe,
              context.usesBlinkNativeTextClient == newContext.usesBlinkNativeTextClient,
              adapter.deliveryMode == .markedText,
              TextDeliveryPolicy.mode(for: newContext) == .markedText,
              lastNonSecureGeneration == contextGeneration,
              deferredMarkedTextCleanupToken == nil,
              composer.hasActiveComposition else {
            return false
        }

        let expectedPreedit = composer.activePreeditForDisplay
        let expectedLength = expectedPreedit.utf16.count
        let markedRange = client.markedRange()
        guard markedRange.length == expectedLength,
              Self.isReasonableMarkedRange(markedRange) else {
            return false
        }

        return client.attributedSubstring(from: markedRange)?.string == expectedPreedit
    }

    /// Refresh the current field at a key or external-action boundary. Finder's
    /// activation snapshot is intentionally lightweight, so refresh it even when the
    /// session was not explicitly marked stale.
    @discardableResult
    func refreshContextForInputBoundary(
        using analyze: (IMKTextInput) -> ClientContext
    ) -> Bool {
        if refreshContextIfNeeded(using: analyze) {
            armFocusLossFinalizer()
            return true
        }
        guard context.isLightweight, context.isFinder else { return false }
        let revision = contextStateRevision
        let newContext = analyze(client)
        guard contextStateRevision == revision else { return false }
        refreshContext(newContext, fieldIdentityMayHaveChanged: true)
        return true
    }

    /// Rebuild the adapter if the delivery policy no longer matches it (e.g. the
    /// experimental direct-insertion flag flipped mid-session). Cheap — two enum
    /// compares on the hot path. This may finalize into the client, so production
    /// callers must first pass the current field's secure-input gate.
    func ensureAdapterMatchesPolicy() {
        let resolved = TextDeliveryPolicy.mode(for: context)
        guard adapter.deliveryMode != resolved else { return }
        // The old adapter owns the currently rendered preedit. Finalize through it
        // before replacing the adapter, otherwise marked text or direct-insertion
        // tracking can be stranded when the experimental setting changes at runtime.
        finalize(reason: .deliveryModeChange)
        let replacement = TextDeliveryPolicy.makeAdapter(for: client, context: context)
        configureClientWriteValidator(on: replacement)
        adapter = replacement
    }

    /// Client writes are safe only for the same analyzed field generation that
    /// explicitly passed the nonsecure gate.
    private var clientWritesAreConfirmedSafe: Bool {
        !contextNeedsRefresh && lastNonSecureGeneration == contextGeneration
    }

    var clientWriteGeneration: UInt64? {
        clientWritesAreConfirmedSafe ? contextGeneration : nil
    }

    func captureContextStateLease() -> ContextStateLease? {
        guard !contextNeedsRefresh else { return nil }
        return ContextStateLease(
            revision: contextStateRevision,
            generation: contextGeneration
        )
    }

    func isCurrent(_ lease: ContextStateLease) -> Bool {
        !contextNeedsRefresh
            && contextStateRevision == lease.revision
            && contextGeneration == lease.generation
    }

    func captureOwnedTextBeforeCursor(
        expectedText: String
    ) -> (generation: UInt64, selectionLocation: Int)? {
        guard let generation = clientWriteGeneration,
              let range = ownedTextRangeBeforeCursor(
                expectedText: expectedText,
                generation: generation,
                expectedSelectionLocation: nil
              ) else {
            return nil
        }
        return (generation, NSMaxRange(range))
    }

    /// Replace the exact PriType-owned text immediately before the caret. A client
    /// object can outlive its focused field, so generation, caret shape, bounds, and
    /// current content must all still match at the moment of the write.
    @discardableResult
    func replaceOwnedTextBeforeCursor(
        expectedText: String,
        replacement: String,
        generation: UInt64,
        expectedSelectionLocation: Int,
        isStillOwned: () -> Bool
    ) -> Bool {
        guard let replacementRange = ownedTextRangeBeforeCursor(
            expectedText: expectedText,
            generation: generation,
            expectedSelectionLocation: expectedSelectionLocation
        ),
              isStillOwned(),
              clientWriteGeneration == generation,
              client.selectedRange() == NSRange(
                location: expectedSelectionLocation,
                length: 0
              ),
              clientWriteGeneration == generation else {
            return false
        }

        client.insertText(replacement, replacementRange: replacementRange)
        return true
    }

    private func ownedTextRangeBeforeCursor(
        expectedText: String,
        generation: UInt64,
        expectedSelectionLocation: Int?
    ) -> NSRange? {
        guard clientWriteGeneration == generation else { return nil }

        let expectedLength = expectedText.utf16.count
        let selection = client.selectedRange()
        guard expectedLength > 0,
              selection.location != NSNotFound,
              selection.location >= expectedLength,
              selection.location < DirectInsertionPlanner.maxReasonableLocation,
              selection.length == 0,
              expectedSelectionLocation.map({ $0 == selection.location }) ?? true else {
            return nil
        }

        let replacementRange = NSRange(
            location: selection.location - expectedLength,
            length: expectedLength
        )
        guard let currentText = client.attributedSubstring(from: replacementRange)?.string,
              currentText.utf16.count == replacementRange.length,
              currentText.precomposedStringWithCanonicalMapping
                == expectedText.precomposedStringWithCanonicalMapping,
              client.selectedRange() == selection,
              clientWriteGeneration == generation else {
            return nil
        }
        return replacementRange
    }
    /// Mouse clicks inside a live marked composition keep composing. A marked-text
    /// fallback left behind after the engine emptied has nothing left to keep, so any
    /// click must reconcile it through `finalize`.
    var mouseCompositionState: MouseCompositionState {
        if composer.hasActiveComposition {
            return .active
        }
        if (adapter as? DirectInsertionAdapter)?.usesMarkedTextFallback == true {
            return .staleMarkedFallback
        }
        return .inactive
    }

    /// Reconcile every click owned by this session, regardless of whether there is
    /// still engine composition to finalize. Opening a Hanja panel commits preedit,
    /// which makes `mouseCompositionState` inactive while the panel, selection
    /// callback, cursor cache, and local context are still live. Those interaction
    /// artifacts therefore must not be guarded by the composition-only policy.
    ///
    /// A click inside a live marked range still keeps the composition itself intact;
    /// only the click-scoped Hanja/context state is invalidated.
    @discardableResult
    func reconcileMouseDown(characterIndex: Int, markedRange: NSRange) -> Bool {
        let state = mouseCompositionState
        let shouldFinalize = MouseCompositionPolicy.shouldFinalize(
            characterIndex: characterIndex,
            markedRange: markedRange,
            state: state
        )
        let didFinalize = shouldFinalize && finalize(reason: .mouseCommit)

        // A click inside PriType's live marked range is proof that focus stayed in
        // the same field. Every other click can move focus while reusing the client.
        if state != .active || shouldFinalize {
            markContextStale()
        }

        composer.dismissHanjaCandidates()
        CursorRectResolver.invalidateCache()
        composer.clearLocalBuffer()
        return didFinalize
    }

    /// Finish a proven IMK field boundary after `finalize` has had its early chance
    /// to commit into the old field. Host-driven commit and `deactivateServer` can
    /// both reuse this client for a different field, so field-local Hanja/cursor
    /// context and external-shortcut classification become untrusted together.
    func finishHostCommitBoundary() {
        composer.dismissHanjaCandidates()
        CursorRectResolver.invalidateCache()
        composer.clearLocalBuffer()
        markContextStale()
    }

    /// Tab and host-passed Enter keys can move focus or submit into another field.
    /// IMK does not guarantee a deactivate or mouse callback before that field reuses
    /// the same client.
    func observeHostFieldBoundaryKeyDown(keyCode: UInt16, passedToHost: Bool) {
        guard passedToHost,
              keyCode == KeyCode.tab
                || keyCode == KeyCode.return
                || keyCode == KeyCode.numpadEnter else {
            return
        }
        previousHostFieldBoundaryPassedToHost = true
        CursorRectResolver.invalidateCache()
        markContextStale()
    }

    // MARK: Duplicate keyDown suppression

    /// Route the keyDown as new input or an exact re-delivery of the immediately
    /// previous physical event. Duplicate events must be consumed by IMK even when
    /// the original event returned false for host default handling.
    func registerKeyDown(_ snapshot: KeyDownSnapshot) -> KeyDownRoute {
        let route = keyEventDeduplicator.route(snapshot)
        if route == .process {
            previousHostFieldBoundaryPassedToHost = false
        } else if previousHostFieldBoundaryPassedToHost {
            // `handle` refreshes stale context before duplicate detection. A field
            // boundary re-delivery can therefore restore the old field's
            // classification before the host applies its action. Reassert the
            // boundary so the next real key classifies the field that received it.
            observeHostFieldBoundaryKeyDown(keyCode: snapshot.keyCode, passedToHost: true)
        }
        if route == .process, !snapshot.isARepeat {
            let generation = keyEventDeduplicator.deliveryTurnGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.keyEventDeduplicator.deliveryTurnGeneration == generation else {
                    return
                }
                self.keyEventDeduplicator.endDeliveryTurn(generation: generation)
            }
        }
        return route
    }

    // MARK: Focus-loss safety net

    func captureFocusLossActivation() -> FocusLossActivation {
        FocusLossActivation(generation: focusLossFinalizerGeneration)
    }

    func isSameFocusLossActivation(_ activation: FocusLossActivation) -> Bool {
        focusLossFinalizerGeneration == activation.generation
    }

    /// Testable body of the app-deactivation observer.
    @discardableResult
    func handleAppDeactivation(expectedFocusLossGeneration: UInt64? = nil) -> Bool {
        let observedGeneration = expectedFocusLossGeneration ?? focusLossFinalizerGeneration
        invalidateHanjaShortcutSessionState()
        let didFinalize = finalize(reason: .appDeactivate)

        // `finalize` must run while the old host still accepts its marked commit.
        // Only then retire every non-text artifact and revoke this field generation.
        composer.dismissHanjaCandidates()
        composer.clearLocalBuffer()
        markContextStale()

        // `insertText` can synchronously cause activateServer to re-arm this session.
        // Keep the newly installed observer and controller ownership in that case.
        guard focusLossFinalizerGeneration == observedGeneration else {
            return didFinalize
        }
        disarmFocusLossFinalizer()
        retireActiveControllerAfterFocusLoss(self)
        return didFinalize
    }

    /// Observe the focused app's deactivation and finalize the composition THEN — early
    /// enough that the host (e.g. KakaoTalk) still accepts the insertText. By the time
    /// IMK's deactivateServer runs, native hosts have already resigned and drop it,
    /// leaving a stranded/underlined preedit. Host-agnostic; the bundle ID compared is
    /// the session's own, never a hardcoded list.
    func armFocusLossFinalizer() {
        disarmFocusLossFinalizer()
        let bundleId = context.bundleId
        guard !bundleId.isEmpty else { return }
        let generation = focusLossFinalizerGeneration
        focusLossObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == bundleId else {
                return
            }
            self.handleAppDeactivation(expectedFocusLossGeneration: generation)
        }
    }

    /// Stop watching for focus loss when this session stops being active. Each
    /// session owns its composer, so a late callback cannot flush another session's
    /// preedit, but disarming still prevents a redundant commit to an inactive host.
    func disarmFocusLossFinalizer() {
        focusLossFinalizerGeneration &+= 1
        if let observer = focusLossObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            focusLossObserver = nil
        }
    }

    /// Retire this session before another IMK controller becomes process-active.
    /// This runs at the new controller's activation boundary, which is earlier than
    /// the old controller's potentially late `deactivateServer` callback.
    func prepareForControllerHandoff(fieldIdentityMayHaveChanged: Bool) {
        composer.dismissHanjaCandidates()
        if fieldIdentityMayHaveChanged {
            markContextStale()
        }
        finalize(reason: .sessionReplacement)
    }

    func finishControllerHandoff() {
        disarmFocusLossFinalizer()
        markContextStale()
    }

    func retireForControllerHandoff(fieldIdentityMayHaveChanged: Bool) {
        prepareForControllerHandoff(fieldIdentityMayHaveChanged: fieldIdentityMayHaveChanged)
        finishControllerHandoff()
    }

    // MARK: Finalize (the single composition-ending path)

    /// Finalize the in-progress composition into this session's client in a SINGLE
    /// operation: insert the committed string with `replacementRange = NSNotFound`, so
    /// the host converts its OWN marked text to committed text (composition-end).
    ///
    /// One op — not commit + separate clear — is load-bearing: an explicit marked-range
    /// edit makes hosts re-run text detection (KakaoTalk re-fires its emoticon popup, a
    /// visible flicker) and a separate `setMarkedText("")` after the host resigned
    /// strands the preedit. Idempotent — no-op when there is no active composition, so
    /// every session-ending event can call it unconditionally.
    @discardableResult
    func finalize(reason: CompositionFinalizeReason) -> Bool {
        guard clientWritesAreConfirmedSafe else {
            let hadComposition = composer.hasActiveComposition
                || (adapter as? DirectInsertionAdapter)?.usesMarkedTextFallback == true
            discardCompositionWithoutClientWrite(rebuildAdapter: false)
            if hadComposition {
                DebugLogger.event("composition.discarded", metadata: [
                    .state("reason", reason.diagnosticLabel),
                    .state("cause", "client_write_unconfirmed")
                ])
            }
            return hadComposition
        }

        guard composer.hasActiveComposition else {
            if let direct = adapter as? DirectInsertionAdapter,
               direct.usesMarkedTextFallback {
                // The engine can become empty before a host clears the fallback
                // marked range. Reconcile only while the current host content still
                // matches the exact fallback this adapter rendered.
                let markedRange = client.markedRange()
                if Self.confirmedMarkedTextMatch(
                    in: client,
                    range: markedRange,
                    expectedText: direct.markedTextFallbackContent
                ) == true,
                   clientWritesAreConfirmedSafe {
                    client.insertText("", replacementRange: markedRange)
                    direct.resetPreeditTracking()
                    DebugLogger.event("composition.marked_fallback_cleared", metadata: [
                        .state("reason", reason.diagnosticLabel)
                    ])
                    return true
                }
                direct.resetPreeditTracking()
                DebugLogger.event("composition.marked_fallback_abandoned", metadata: [
                    .state("reason", reason.diagnosticLabel),
                    .state("cause", "marked_text_changed")
                ])
                return false
            }
            // Nothing to commit, but the session-ending event (e.g. a mouse click)
            // likely moved the caret — stale direct-insertion tracking must never
            // survive it, or the next keystroke could rewrite unrelated text.
            (adapter as? DirectInsertionAdapter)?.resetPreeditTracking()
            return false
        }

        // EXPERIMENTAL direct insertion: the in-progress syllable is ALREADY real text
        // in the document. If document access failed after that write, the adapter also
        // deliberately preserved the last verified real preedit instead of guessing a
        // delete range. Re-inserting the engine's newer preedit in either case would
        // duplicate/corrupt text. End the engine and clear adapter tracking only.
        if let direct = adapter as? DirectInsertionAdapter,
           !direct.usesMarkedTextFallback {
            _ = composer.flushCommitString()   // flush engine + update buffer; do NOT insert
            direct.resetPreeditTracking()
            DebugLogger.event("composition.finalized", metadata: [
                .state("reason", reason.diagnosticLabel),
                .state("delivery", "direct_insertion"),
                .flag("inserted", false)
            ])
            return true
        }

        let expectedMarkedText = composer.activePreeditForDisplay
        let markedRange = client.markedRange()
        let markedTextMatch = Self.confirmedMarkedTextMatch(
            in: client,
            range: markedRange,
            expectedText: expectedMarkedText
        )
        if markedTextMatch == false,
           !Self.allowsLaggingMarkedTextCommit(
               reason: reason,
               range: markedRange,
               expectedText: expectedMarkedText
           ) {
            discardCompositionWithoutClientWrite(rebuildAdapter: false)
            DebugLogger.event("composition.discarded", metadata: [
                .state("reason", reason.diagnosticLabel),
                .state("cause", "marked_text_changed")
            ])
            return true
        }
        guard clientWritesAreConfirmedSafe else {
            discardCompositionWithoutClientWrite(rebuildAdapter: false)
            DebugLogger.event("composition.discarded", metadata: [
                .state("reason", reason.diagnosticLabel),
                .state("cause", "client_write_revoked")
            ])
            return true
        }

        Self.finalizeMarkedComposition(
            composer: composer,
            client: client,
            markedRange: markedRange,
            reason: reason
        )
        (adapter as? DirectInsertionAdapter)?.resetPreeditTracking()
        return true
    }

    /// AppKit can briefly expose the previous same-length marked snapshot when a
    /// custom toggle immediately follows the final jamo. The toggle path has already
    /// refreshed the field, passed the Secure Input gate, and authorized this
    /// generation, so a structurally identical marked range can use the canonical
    /// commit without waiting for document readback to catch up. Other lifecycle
    /// finalizers and structurally different ranges remain fail-closed.
    private static func allowsLaggingMarkedTextCommit(
        reason: CompositionFinalizeReason,
        range: NSRange,
        expectedText: String
    ) -> Bool {
        reason == .modeTransition
            && isReasonableMarkedRange(range)
            && range.length == expectedText.utf16.count
    }

    /// Confirm that the current generation passed the nonsecure gate, then clear
    /// PriType-owned marked text only when it was created in that same generation.
    /// Generic lifecycle callbacks cannot establish either condition.
    @discardableResult
    func prepareForNonSecureClientWrites() -> Bool {
        guard !contextNeedsRefresh else { return false }

        // A preedit created before a possible field transition cannot be committed
        // into the newly analyzed field, even when that new field is nonsecure.
        if lastNonSecureGeneration != contextGeneration,
           composer.hasActiveComposition
            || (adapter as? DirectInsertionAdapter)?.usesMarkedTextFallback == true {
            discardCompositionWithoutClientWrite(rebuildAdapter: false)
        }
        lastNonSecureGeneration = contextGeneration

        guard let token = deferredMarkedTextCleanupToken else {
            return false
        }
        deferredMarkedTextCleanupToken = nil

        guard token.generation == contextGeneration else {
            DebugLogger.event("composition.deferred_marked_fallback_abandoned", metadata: [
                .state("reason", "context_changed")
            ])
            return false
        }

        let markedRange = client.markedRange()
        guard Self.isReasonableMarkedRange(markedRange) else {
            DebugLogger.event("composition.deferred_marked_fallback_abandoned", metadata: [
                .state("reason", "marked_range_invalid")
            ])
            return false
        }

        guard Self.confirmedMarkedTextMatch(
            in: client,
            range: markedRange,
            expectedText: token.normalizedContent
        ) == true else {
            DebugLogger.event("composition.deferred_marked_fallback_abandoned", metadata: [
                .state("reason", "marked_text_unverified")
            ])
            return false
        }
        guard clientWriteGeneration == token.generation else {
            DebugLogger.event("composition.deferred_marked_fallback_abandoned", metadata: [
                .state("reason", "client_write_revoked")
            ])
            return false
        }

        client.insertText("", replacementRange: markedRange)
        DebugLogger.event("composition.deferred_marked_fallback_cleared")
        return true
    }

    /// Remember that a client keyboard-layout sync must wait until the current field
    /// passes the nonsecure gate. Repeated requests collapse to the latest trace.
    func deferRomanKeyboardLayoutSync(trace: ToggleLatencyTrace? = nil) {
        #if DEBUG
        deferredRomanKeyboardLayoutTrace?.mark(.superseded)
        deferredRomanKeyboardLayoutTrace = trace
        #endif
        needsDeferredRomanKeyboardLayoutSync = true
    }

    /// Apply a deferred layout sync only after the current field has passed the
    /// nonsecure gate. Clear state before the callback so a reentrant request cannot
    /// be overwritten by the older request completing.
    @discardableResult
    func reconcileDeferredRomanKeyboardLayoutSync(
        using synchronize: (IMKTextInput, InputMode) -> Void
    ) -> Bool {
        guard needsDeferredRomanKeyboardLayoutSync,
              let contextLease = captureContextStateLease() else { return false }
        needsDeferredRomanKeyboardLayoutSync = false
        #if DEBUG
        let trace = deferredRomanKeyboardLayoutTrace
        deferredRomanKeyboardLayoutTrace = nil
        #endif

        synchronize(client, composer.inputMode)
        #if DEBUG
        trace?.mark(.keyboardOverride)
        #endif
        guard isCurrent(contextLease) else {
            if !needsDeferredRomanKeyboardLayoutSync {
                needsDeferredRomanKeyboardLayoutSync = true
                #if DEBUG
                deferredRomanKeyboardLayoutTrace = trace
                #endif
            }
            return false
        }
        return true
    }

    /// A forced layout sync supersedes any work deferred while the field was
    /// unclassified or secure.
    func cancelDeferredRomanKeyboardLayoutSync() {
        guard needsDeferredRomanKeyboardLayoutSync else { return }
        needsDeferredRomanKeyboardLayoutSync = false
        #if DEBUG
        let trace = deferredRomanKeyboardLayoutTrace
        deferredRomanKeyboardLayoutTrace = nil
        trace?.mark(.superseded)
        #endif
    }

    /// Capture marked-text ownership before dropping the engine, then invalidate all
    /// direct-insertion tracking without touching the current client.
    private func discardCompositionWithoutClientWrite(rebuildAdapter: Bool) {
        let direct = adapter as? DirectInsertionAdapter
        let ownsMarkedText = direct?.usesMarkedTextFallback == true
            || (adapter.deliveryMode == .markedText && composer.hasActiveComposition)
        let normalizedOwnedContent = composer.activePreeditForDisplay
        if deferredMarkedTextCleanupToken == nil,
           ownsMarkedText,
           let ownerGeneration = lastNonSecureGeneration,
           !normalizedOwnedContent.isEmpty {
            deferredMarkedTextCleanupToken = DeferredMarkedTextCleanupToken(
                generation: ownerGeneration,
                normalizedContent: normalizedOwnedContent
            )
        }

        composer.dismissHanjaCandidates()
        composer.discardCompositionForPassThrough()
        direct?.resetPreeditTracking()
        lastNonSecureGeneration = nil

        guard rebuildAdapter else { return }
        let resolved = TextDeliveryPolicy.mode(for: context)
        if adapter.deliveryMode != resolved {
            let replacement = TextDeliveryPolicy.makeAdapter(for: client, context: context)
            configureClientWriteValidator(on: replacement)
            adapter = replacement
        }
    }

    private func configureClientWriteValidator(on adapter: BaseClientAdapter) {
        adapter.setClientWriteValidator { [weak self] in
            self?.clientWritesAreConfirmedSafe == true
        }
    }

    /// The marked-text finalize, callable against any client. `PriTypeInputController`
    /// uses this directly when IMK hands it a sender that is not this session's client.
    static func finalizeMarkedComposition(
        composer: HangulComposer,
        client: IMKTextInput,
        markedRange: NSRange,
        reason: CompositionFinalizeReason
    ) {
        let committed = composer.flushCommitString()
        DebugLogger.event("composition.finalized", metadata: [
            .state("reason", reason.diagnosticLabel),
            .state("delivery", "marked_text"),
            .flag("had_marked_range", markedRange.location != NSNotFound && markedRange.length > 0),
            .count("committed_length", committed.count)
        ])
        if !committed.isEmpty {
            // Canonical finalize: NSNotFound asks the host to convert its OWN marked
            // text to committed (composition-end), rather than an explicit marked-range
            // edit. (Done at app-deactivate-observer timing, the host still accepts it.)
            client.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        } else if markedRange.location != NSNotFound, markedRange.length > 0 {
            client.insertText("", replacementRange: markedRange)
        }
    }

    private static func isReasonableMarkedRange(_ range: NSRange) -> Bool {
        let (rangeEnd, overflow) = range.location.addingReportingOverflow(range.length)
        return range.location != NSNotFound
            && range.location >= 0
            && range.location < DirectInsertionPlanner.maxReasonableLocation
            && range.length > 0
            && !overflow
            && rangeEnd < DirectInsertionPlanner.maxReasonableLocation
    }

    /// `nil` means the host cannot expose marked content, where canonical
    /// `NSNotFound` commit remains the compatibility fallback. Readable content must
    /// stay identical across a second range/content snapshot before it is touched.
    private static func confirmedMarkedTextMatch(
        in client: IMKTextInput,
        range: NSRange,
        expectedText: String
    ) -> Bool? {
        guard isReasonableMarkedRange(range) else { return false }
        guard let first = client.attributedSubstring(from: range)?.string else {
            return range.length == expectedText.utf16.count ? nil : false
        }
        guard first.utf16.count == range.length else { return false }
        let normalizedExpected = expectedText.precomposedStringWithCanonicalMapping
        guard first.precomposedStringWithCanonicalMapping == normalizedExpected else {
            return false
        }

        let confirmedRange = client.markedRange()
        guard confirmedRange == range,
              let confirmed = client.attributedSubstring(from: confirmedRange)?.string,
              confirmed.utf16.count == confirmedRange.length,
              confirmed.precomposedStringWithCanonicalMapping == normalizedExpected else {
            return false
        }
        return true
    }

    /// Secure text fields must receive raw key events. Drop the engine's composition
    /// WITHOUT touching the client (no insertText/setMarkedText — those can trigger
    /// host warning beeps in password fields), and clear direct-insertion tracking so
    /// a stale live-preedit length can never delete real text on the next keystroke.
    /// If direct insertion had degraded to marked text, preserve only PriType's
    /// cleanup ownership; the client write itself remains deferred until a later
    /// nonsecure gate explicitly allows it.
    func discardForSecureInput() {
        // A stale same-client refresh can change the resolved policy before the
        // secure gate runs. Rebuild only after the engine is discarded, without the
        // normal finalize step that would write into the password client.
        discardCompositionWithoutClientWrite(rebuildAdapter: true)
    }
}
