import Cocoa
import InputMethodKit
import LibHangul
import Carbon.HIToolbox

/// Thin IMK edge of the input pipeline.
///
/// The controller owns nothing but the IMK lifecycle. Everything session-scoped —
/// client, analyzed context, delivery adapter, duplicate-keyDown state, focus-loss
/// safety net — lives in a single `InputSession`, and EVERY composition-ending event
/// (app deactivate, deactivateServer, mouse commit, custom toggle, macOS ownership,
/// keyboard-layout change) funnels into `InputSession.finalize(reason:)`, the
/// one host-agnostic commit path.
///
/// ```
/// keyDown ──► handle() ──► ensureSession ──► dedup ──► secure gate ──► HangulComposer
///                                                                          │
///                  TextDeliveryAdapter (marked / direct / immediate) ◄─────┘
///
/// toggle key / macOS ownership ──► InputModeCoordinator ──► controller ─┐
/// app deactivate / deactivateServer / mouse commit / layout change ────┴─► session.finalize
/// ```
@objc(PriTypeInputController)
public class PriTypeInputController: IMKInputController, @unchecked Sendable {
    private static let forcedRomanKeyboardLayoutID = resolveForcedRomanKeyboardLayoutID()
    private static let romanKeyboardLayoutCandidates = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US"
    ]

    // MARK: - Shared State
    //
    // THREAD SAFETY INVARIANTS:
    // These static properties use `nonisolated(unsafe)` for Swift 6 strict concurrency compliance.
    //
    // WHY NOT @MainActor?
    // IMKInputController callbacks (handle, activateServer, etc.) are NOT @MainActor-isolated.
    // Swift 6 compiler would reject @MainActor property access from these callbacks.
    //
    // IMK guarantees main thread execution by design:
    // 1. `sharedInputModeStore`: Process-wide Korean/English choice only
    // 2. `sharedController`: Read/written only in activateServer/deactivateServer
    //
    // This is a documented limitation of integrating Swift 6 strict concurrency with
    // legacy Objective-C frameworks like InputMethodKit.

    /// The user's Korean/English choice survives input sessions. libhangul
    /// composition state does not: every `InputSession` owns a separate composer.
    private static let sharedInputModeStore = InputModeStore()

    /// Process-wide active controller for external toggle and Hanja access.
    private static let activeControllerRegistry = ActiveOwnerHandoffRegistry<PriTypeInputController>()
    public static var sharedController: PriTypeInputController? {
        activeControllerRegistry.owner
    }

    /// The live input session (client + context + adapter + dedup + focus-loss net).
    /// Kept across deactivateServer so a `handle()` arriving before the next
    /// activateServer can refresh its context, and replaced when a different client appears.
    private var session: InputSession?

    /// Non-nil while retiring a session can synchronously re-enter `activateServer`
    /// through the retiring client's final `insertText`.
    private var sessionRetirementInProgress: SessionRetirementSnapshot?

    /// Session-derived views for collaborators (Hanja lookup in `HangulComposer`).
    public var currentAdapter: (any HangulComposerDelegate)? { session?.adapter }
    public var cachedContext: ClientContext? { session?.context }
    var activeSessionIdentifier: ObjectIdentifier? {
        guard let session, !session.contextNeedsRefresh else { return nil }
        return ObjectIdentifier(session)
    }
    var activeSessionClient: IMKTextInput? {
        guard let session, !session.contextNeedsRefresh else { return nil }
        return session.client
    }

    #if DEBUG
    private var debugHandleLogCount = 0
    nonisolated(unsafe) private static var pendingToggleTrace: ToggleLatencyTrace?
    #endif
    private var lastKeyboardOverrideClientID: ObjectIdentifier?
    private var lastKeyboardOverrideTime: CFAbsoluteTime = 0

    deinit {
        // The selector-based `.keyboardLayoutChanged` observer is auto-removed on
        // modern macOS, but remove it explicitly to be safe. The session's block-based
        // NSWorkspace observer is NOT auto-removed; the session disarms it in deinit,
        // but do it eagerly here too.
        session?.disarmFocusLossFinalizer()
        NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .romanKeyboardLayoutPreferenceChanged, object: nil)
    }

    // MARK: - Session Management

    final class SessionRetirementSnapshot {
        let session: InputSession
        fileprivate let focusLossActivation: InputSession.FocusLossActivation
        private var didPrepareForReentrantActivation = false

        fileprivate init(session: InputSession) {
            self.session = session
            self.focusLossActivation = session.captureFocusLossActivation()
        }

        fileprivate func consumeReentrantActivationPreparation() -> Bool {
            guard !didPrepareForReentrantActivation else { return false }
            didPrepareForReentrantActivation = true
            return true
        }
    }

    private func makeComposer() -> HangulComposer {
        HangulComposer(
            statusBar: StatusBarManager.shared,
            configuration: ConfigurationManager.shared,
            inputModeStore: Self.sharedInputModeStore
        )
    }

    private func replaceSession(client: IMKTextInput, context: ClientContext) -> InputSession? {
        publishHanjaShortcutSessionState(.unknown)
        if let previous = session {
            let retirement = Self.captureSessionRetirementSnapshot(session: previous)
            let enclosingRetirement = sessionRetirementInProgress
            sessionRetirementInProgress = retirement
            defer {
                if sessionRetirementInProgress === retirement {
                    sessionRetirementInProgress = enclosingRetirement
                }
            }
            previous.composer.dismissHanjaCandidates()
            previous.finalize(reason: .sessionReplacement)
            guard Self.finishSessionRetirement(
                retirement,
                currentSession: session,
                retire: previous.disarmFocusLossFinalizer
            ) else {
                return nil
            }
        }
        CursorRectResolver.invalidateCache()

        let newSession = InputSession(
            client: client,
            context: context,
            composer: makeComposer(),
            invalidateHanjaShortcutSessionState: { [weak self] in
                self?.publishHanjaShortcutSessionState(.unknown)
            },
            retireActiveControllerAfterFocusLoss: { [weak self] retiredSession in
                self?.retireAfterAppFocusLoss(retiredSession)
            }
        )
        newSession.composer.updateKeyboardLayout(id: ConfigurationManager.shared.keyboardId)
        session = newSession
        newSession.armFocusLossFinalizer()
        return newSession
    }

    static func captureSessionRetirementSnapshot(
        session: InputSession?
    ) -> SessionRetirementSnapshot? {
        session.map(SessionRetirementSnapshot.init)
    }

    static func captureDeactivationSnapshot(
        session: InputSession?,
        sender: Any?
    ) -> SessionRetirementSnapshot? {
        guard let session else { return nil }
        if let senderClient = sender as? IMKTextInput,
           !session.matches(senderClient) {
            DebugLogger.event("composition.finalize_ignored", metadata: [
                .state("reason", CompositionFinalizeReason.deactivateServer.diagnosticLabel),
                .state("cause", "stale_client")
            ])
            return nil
        }
        return SessionRetirementSnapshot(session: session)
    }

    /// A reentrant activation is the earliest safe point to discard the old field's
    /// Hanja/cursor context. The outer retirement must later leave the new activation
    /// itself untouched.
    static func prepareForActivationDuringSessionRetirement(
        _ snapshot: SessionRetirementSnapshot?
    ) {
        guard let snapshot,
              snapshot.consumeReentrantActivationPreparation() else { return }
        snapshot.session.finishHostCommitBoundary()
    }

    @discardableResult
    static func finishSessionRetirement(
        _ snapshot: SessionRetirementSnapshot?,
        currentSession: InputSession?,
        retire: () -> Void
    ) -> Bool {
        guard let snapshot,
              currentSession === snapshot.session,
              snapshot.session.isSameFocusLossActivation(snapshot.focusLossActivation) else {
            return false
        }

        retire()
        return true
    }

    @discardableResult
    static func finishDeactivation(
        _ snapshot: SessionRetirementSnapshot?,
        currentSession: InputSession?,
        retireController: () -> Void
    ) -> Bool {
        guard let snapshot else { return false }
        return finishSessionRetirement(snapshot, currentSession: currentSession) {
            snapshot.session.finishHostCommitBoundary()
            snapshot.session.disarmFocusLossFinalizer()
            retireController()
        }
    }

    @discardableResult
    static func retireSessionForControllerHandoff(
        _ snapshot: SessionRetirementSnapshot?,
        currentSession: () -> InputSession?,
        fieldIdentityMayHaveChanged: Bool,
        retireController: () -> Void
    ) -> Bool {
        guard let snapshot else { return false }
        snapshot.session.prepareForControllerHandoff(
            fieldIdentityMayHaveChanged: fieldIdentityMayHaveChanged
        )
        return finishSessionRetirement(
            snapshot,
            currentSession: currentSession()
        ) {
            snapshot.session.finishControllerHandoff()
            retireController()
        }
    }

    /// Complete process-wide retirement only if a reentrant activation did not
    /// replace the session while the old host accepted its focus-loss commit.
    private func retireAfterAppFocusLoss(_ retiredSession: InputSession) {
        guard session === retiredSession else { return }
        CursorRectResolver.invalidateCache()
        NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .romanKeyboardLayoutPreferenceChanged, object: nil)
        Self.activeControllerRegistry.release(self)
        DebugLogger.event("input.controller_retired", metadata: [
            .state("reason", "app_focus_loss")
        ])
    }

    /// IMK creates one controller per client input session. A newly activated
    /// controller can arrive before the old controller's `deactivateServer`, so claim
    /// process-wide ownership only after retiring the previous controller while its
    /// host still accepts the composition commit.
    private func claimProcessActiveController(incomingClient: IMKTextInput?) {
        Self.activeControllerRegistry.claim(self) { previous in
            previous.publishHanjaShortcutSessionState(.unknown)
            previous.retireForControllerHandoff(incomingClient: incomingClient)
        }
        publishHanjaShortcutSessionState(.unknown)
    }

    private func retireForControllerHandoff(incomingClient: IMKTextInput?) {
        Self.prepareForActivationDuringSessionRetirement(sessionRetirementInProgress)
        let mayReuseField = incomingClient.map { session?.matches($0) == true } ?? true
        let finishControllerHandoff = { [self] in
            NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
            NotificationCenter.default.removeObserver(self, name: .romanKeyboardLayoutPreferenceChanged, object: nil)
            CursorRectResolver.invalidateCache()
            DebugLogger.event("input.controller_handoff")
        }
        guard let retirement = Self.captureSessionRetirementSnapshot(session: session) else {
            finishControllerHandoff()
            return
        }
        let enclosingRetirement = sessionRetirementInProgress
        sessionRetirementInProgress = retirement
        defer {
            if sessionRetirementInProgress === retirement {
                sessionRetirementInProgress = enclosingRetirement
            }
        }
        _ = Self.retireSessionForControllerHandoff(
            retirement,
            currentSession: { self.session },
            fieldIdentityMayHaveChanged: mayReuseField
        ) {
            finishControllerHandoff()
        }
    }

    /// Event-tap callbacks cannot call IMK/client APIs. Publish only the content-free
    /// result of the main-thread secure gate, and only for the process-active owner.
    private func publishHanjaShortcutSessionState(_ state: HanjaShortcutSessionState) {
        #if DEBUG
        assert(Thread.isMainThread, "Hanja shortcut session state must be published on main thread")
        #endif
        HanjaShortcutSessionStateStore.shared.update(
            state,
            from: self,
            activeOwner: Self.sharedController
        )
    }

    /// Return the session for `client`, creating or refreshing it as needed.
    /// - A different client object ⇒ new session (full context analysis).
    /// - Same client after deactivateServer ⇒ re-analyze (focus may have moved to a
    ///   different field of the same app, e.g. a password field).
    /// - Finder lightweight context ⇒ re-analyze per keystroke (desktop vs. rename
    ///   field can only be told apart by coordinates at keystroke time).
    private func ensureSession(for client: IMKTextInput) -> InputSession? {
        if let session, session.matches(client) {
            _ = session.refreshContextForInputBoundary(using: { client in
                ClientContextDetector.analyze(client: client)
            })
            return session
        }

        DebugLogger.event("input.session_replaced")
        let newSession = replaceSession(
            client: client,
            context: ClientContextDetector.analyze(client: client)
        )
        guard let newSession else { return nil }
        syncRomanKeyboardLayout(for: client)
        return newSession
    }

    // MARK: - Keyboard Layout (English pass-through support)

    private func syncRomanKeyboardLayout(
        for client: IMKTextInput,
        mode: InputMode? = nil,
        force: Bool = false
    ) {
        let clientID = ObjectIdentifier(client as AnyObject)
        let now = CFAbsoluteTimeGetCurrent()
        guard force || lastKeyboardOverrideClientID != clientID || now - lastKeyboardOverrideTime > 0.5 else {
            return
        }

        let selector = NSSelectorFromString("overrideKeyboardWithKeyboardNamed:")
        let object = client as AnyObject
        guard object.responds(to: selector) else {
            DebugLogger.event("input.keyboard_override_skipped", metadata: [
                .state("reason", "unsupported")
            ])
            return
        }

        let targetMode = mode ?? Self.sharedInputModeStore.mode
        let respectCurrentLayout = ConfigurationManager.shared.respectCurrentRomanKeyboardLayout
        let currentASCIILayoutID = respectCurrentLayout && targetMode == .english
            ? Self.currentASCIICapableKeyboardLayoutID()
            : nil
        let layoutID = Self.preferredRomanKeyboardLayoutID(
            inputMode: targetMode,
            respectCurrentLayout: respectCurrentLayout,
            currentASCIILayoutID: currentASCIILayoutID,
            forcedLayoutID: Self.forcedRomanKeyboardLayoutID
        )
        _ = object.perform(selector, with: layoutID)
        lastKeyboardOverrideClientID = clientID
        lastKeyboardOverrideTime = now
        DebugLogger.event("input.keyboard_override_applied")
    }

    internal static func preferredRomanKeyboardLayoutID(
        inputMode: InputMode,
        respectCurrentLayout: Bool,
        currentASCIILayoutID: String?,
        forcedLayoutID: String
    ) -> String {
        guard inputMode == .english,
              respectCurrentLayout,
              let currentASCIILayoutID,
              !currentASCIILayoutID.isEmpty else {
            return forcedLayoutID
        }
        return currentASCIILayoutID
    }

    private static func currentASCIICapableKeyboardLayoutID() -> String? {
        guard let sourceReference = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else {
            DebugLogger.event("input.roman_layout_fallback", metadata: [
                .state("reason", "lookup_failed")
            ])
            return nil
        }
        let source = sourceReference.takeRetainedValue()
        guard inputSourceStringProperty(source, key: kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String,
              inputSourceBoolProperty(source, key: kTISPropertyInputSourceIsASCIICapable),
              let layoutID = inputSourceStringProperty(source, key: kTISPropertyInputSourceID),
              !layoutID.isEmpty else {
            DebugLogger.event("input.roman_layout_fallback", metadata: [
                .state("reason", "invalid_source")
            ])
            return nil
        }
        return layoutID
    }

    private static func inputSourceStringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func inputSourceBoolProperty(_ source: TISInputSource, key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        let value = Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private static func resolveForcedRomanKeyboardLayoutID() -> String {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ]

        guard let sourceList = TISCreateInputSourceList(filter as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] else {
            return romanKeyboardLayoutCandidates[0]
        }

        let availableIDs = Set(sourceList.compactMap { source -> String? in
            guard let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                return nil
            }
            return Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        })

        return romanKeyboardLayoutCandidates.first { availableIDs.contains($0) } ?? romanKeyboardLayoutCandidates[0]
    }

    // MARK: - Mode Transitions (한/영)

    public func performPriTypeModeTransition(
        source: InputModeCoordinator.ToggleSource,
        trace: ToggleLatencyTrace
    ) {
        guard let activeSession = session else {
            DebugLogger.event("toggle.ignored", metadata: [
                .state("source", source.diagnosticLabel),
                .state("reason", "no_active_session")
            ])
            trace.mark(.ignored)
            return
        }

        _ = Self.routeExternalModeTransition(
            in: activeSession,
            source: source,
            trace: trace,
            analyzeContext: { client in
                ClientContextDetector.analyze(client: client)
            },
            shouldPassThroughSecureInput: { client, context in
                self.shouldPassThroughSecureInput(client: client, context: context)
            },
            syncRomanKeyboardLayout: { client, mode in
                self.syncRomanKeyboardLayout(for: client, mode: mode, force: true)
            }
        )
    }

    /// Route a physical custom toggle through the same refresh-before-secure-gate
    /// ordering as external Hanja. Secure fields receive no client writes or keyboard
    /// override: the composition is discarded, the user's mode intent is retained,
    /// and layout synchronization is deferred to the next nonsecure boundary.
    /// Returns true only when the normal client-side transition ran.
    @discardableResult
    static func routeExternalModeTransition(
        in session: InputSession,
        source: InputModeCoordinator.ToggleSource,
        trace: ToggleLatencyTrace,
        analyzeContext: (IMKTextInput) -> ClientContext,
        shouldPassThroughSecureInput: (IMKTextInput, ClientContext) -> Bool,
        syncRomanKeyboardLayout: (IMKTextInput, InputMode) -> Void
    ) -> Bool {
        _ = session.refreshContextForInputBoundary(using: analyzeContext)

        let composer = session.composer
        let nextMode = composer.inputMode.toggled
        DebugLogger.event("toggle.transition_started", metadata: [
            .state("source", source.diagnosticLabel),
            .state("from", composer.inputMode == .korean ? "korean" : "english"),
            .state("to", nextMode == .korean ? "korean" : "english")
        ])

        composer.dismissHanjaCandidates()
        #if DEBUG
        Self.pendingToggleTrace?.mark(.superseded)
        Self.pendingToggleTrace = trace
        #endif

        if shouldPassThroughSecureInput(session.client, session.context) {
            session.discardForSecureInput()
            session.deferRomanKeyboardLayoutSync(trace: trace)
            composer.setInputMode(nextMode)
            trace.mark(.modeWrite)
            return false
        }

        _ = session.prepareForNonSecureClientWrites()
        session.ensureAdapterMatchesPolicy()
        session.cancelDeferredRomanKeyboardLayoutSync()
        session.finalize(reason: .modeTransition)
        trace.mark(.finalize)
        composer.clearLocalBuffer()
        CursorRectResolver.invalidateCache()
        syncRomanKeyboardLayout(session.client, nextMode)
        trace.mark(.keyboardOverride)
        composer.setInputMode(nextMode)
        trace.mark(.modeWrite)
        return true
    }

    /// Resolve a previously observed macOS-owned source boundary. This is called
    /// only after the current client passes the secure-input gate; notification and
    /// activation callbacks are allowed to mark the boundary but never commit text.
    @discardableResult
    func reconcileMacOSOwnedInputSourceBoundary() -> Bool {
        guard let session else { return false }

        DebugLogger.event("input_mode.ownership_reconciliation_started", metadata: [
            .state("from", session.composer.inputMode == .korean ? "korean" : "english")
        ])
        Self.applyMacOSOwnedInputSourceBoundary(to: session) {
            self.syncRomanKeyboardLayout(for: session.client, mode: .korean, force: true)
        }
        return true
    }

    /// Testable transaction body. The controller remains the only production mode
    /// writer; the ownership monitor can only ask it to execute this path.
    static func applyMacOSOwnedInputSourceBoundary(
        to session: InputSession,
        syncRomanKeyboardLayout: () -> Void
    ) {
        let composer = session.composer
        composer.dismissHanjaCandidates()
        session.finalize(reason: .inputSourceOwnership)
        composer.clearLocalBuffer()
        CursorRectResolver.invalidateCache()
        syncRomanKeyboardLayout()
        composer.setInputMode(.korean)
    }

    // MARK: - IMK Lifecycle

    // 입력기가 활성화될 때 호출 - 새 세션 시작
    override public func activateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK activateServer must run on main thread")
        #endif
        Self.prepareForActivationDuringSessionRetirement(sessionRetirementInProgress)
        // The currently active owner invalidates its snapshot before IMK probing or
        // handoff. Once the claim completes, this controller republishes unknown.
        Self.sharedController?.publishHanjaShortcutSessionState(.unknown)
        super.activateServer(sender)
        claimProcessActiveController(incomingClient: sender as? IMKTextInput)
        session?.composer.dismissHanjaCandidates()
        CursorRectResolver.invalidateCache()
        // NOTE: Focus changes never reset the shared InputModeStore. Korean/English
        // state is process-global, while libhangul composition remains session-owned.
        if let client = sender as? IMKTextInput {
            syncRomanKeyboardLayout(for: client, force: true)

            if let session, session.matches(client) {
                // Electron/Chromium may activate the same client repeatedly without
                // deactivation. Keep that session's composer so an in-flight syllable
                // is not reset; refresh expensive context once at the next keyDown.
                session.markContextStaleForSameClientReactivation()
                session.armFocusLossFinalizer()
                DebugLogger.event("input.session_reactivated")
            } else {
                // Analyze context lightly at activation and upgrade at first keyDown.
                guard let newSession = replaceSession(
                    client: client,
                    context: ClientContextDetector.analyzeForActivation(client: client)
                ) else { return }
                newSession.markContextStale()
                DebugLogger.event("input.session_activated", metadata: [
                    .flag("lightweight", newSession.context.isLightweight)
                ])
            }
        } else {
            // Fallback if sender is not IMKTextInput (rare). Preserve the session object,
            // but stop trusting its context and stop watching focus on its behalf.
            session?.disarmFocusLossFinalizer()
            session?.markContextStale()
        }

        // Activation is evidence that PriType is the selected source, but it only
        // records a real ownership boundary. It never resets mode or commits text.
        InputModeCoordinator.shared.observePriTypeActivation()
        // Activation is still unclassified. A layout mismatch must not commit old
        // preedit through the retained delegate before the secure-input gate.
        let currentLayoutId = ConfigurationManager.shared.keyboardId
        session?.refreshKeyboardLayoutForStaleActivation(id: currentLayoutId)

        // Observe layout changes. IMK can call activateServer again without an
        // intervening deactivateServer (common in Electron/Chromium hosts), and
        // NotificationCenter allows duplicate (observer, selector, name)
        // registrations that would each fire handleLayoutChange. Remove any prior
        // registration first so this stays idempotent.
        NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleLayoutChange), name: .keyboardLayoutChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .romanKeyboardLayoutPreferenceChanged, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRomanKeyboardLayoutPreferenceChange),
            name: .romanKeyboardLayoutPreferenceChanged,
            object: nil
        )
    }

    override public func deactivateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK deactivateServer must run on main thread")
        #endif
        // Fallback finalize. The primary path is the session's focus-loss observer (it
        // fires earlier, while the host still accepts input); by the time
        // deactivateServer runs, native hosts like KakaoTalk have already resigned and
        // ignore insertText. If the observer already committed, this is a no-op.
        let deactivation = Self.captureDeactivationSnapshot(session: session, sender: sender)
        let enclosingRetirement = sessionRetirementInProgress
        if let deactivation {
            publishHanjaShortcutSessionState(.unknown)
            sessionRetirementInProgress = deactivation
        }
        defer {
            if sessionRetirementInProgress === deactivation {
                sessionRetirementInProgress = enclosingRetirement
            }
        }
        _ = deactivation?.session.finalize(reason: .deactivateServer)
        super.deactivateServer(sender)
        // Keep the session until replacement so handle() can refresh it even if it
        // arrives before the next activateServer.
        // - disarm the focus-loss observer so an inactive host never receives a
        //   redundant late finalize (composition state itself is session-owned);
        // - drop field-local Hanja/cursor state and re-analyze on the next input.
        _ = Self.finishDeactivation(
            deactivation,
            currentSession: session
        ) {
            NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
            NotificationCenter.default.removeObserver(self, name: .romanKeyboardLayoutPreferenceChanged, object: nil)
            Self.activeControllerRegistry.release(self)
        }
    }

    @objc private func handleLayoutChange() {
        let newId = ConfigurationManager.shared.keyboardId
        DebugLogger.event("input.keyboard_layout_notification")
        // Layout switches mid-composition end the composition like any other
        // session-ending event — through the single finalize path.
        guard let session else { return }
        let composer = session.composer
        if composer.keyboardLayoutId != newId {
            session.finalize(reason: .keyboardLayoutChange)
            composer.dismissHanjaCandidates()
            CursorRectResolver.invalidateCache()
        }
        composer.updateKeyboardLayout(id: newId)
    }

    @objc private func handleRomanKeyboardLayoutPreferenceChange() {
        guard let session else { return }
        syncRomanKeyboardLayout(for: session.client, force: true)
    }

    // Keep flagsChanged for Caps Lock/TIS ownership and explicitly opt into mouse
    // down delivery. InputMethodKit's default outside-click commit only applies when
    // this mask is exactly keyDown, so the mouse callback below owns that boundary.
    override public func recognizedEvents(_ sender: Any!) -> Int {
        Int(
            NSEvent.EventTypeMask.keyDown.rawValue
                | NSEvent.EventTypeMask.flagsChanged.rawValue
                | NSEvent.EventTypeMask.leftMouseDown.rawValue
                | NSEvent.EventTypeMask.rightMouseDown.rawValue
                | NSEvent.EventTypeMask.otherMouseDown.rawValue
        )
    }

    override public func mouseDown(
        onCharacterIndex index: Int,
        coordinate point: NSPoint,
        withModifier flags: Int,
        continueTracking keepTracking: UnsafeMutablePointer<ObjCBool>!,
        client sender: Any!
    ) -> Bool {
        keepTracking?.pointee = false
        guard let client = sender as? IMKTextInput,
              let session,
              session.matches(client) else {
            return false
        }

        session.reconcileMouseDown(
            characterIndex: index,
            markedRange: client.markedRange()
        )
        return false // The host still owns caret movement and selection.
    }

    // MARK: - Keystroke Pipeline

    override public func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        #if DEBUG
        assert(Thread.isMainThread, "IMK handle must run on main thread")
        #endif
        guard let event = event, let client = sender as? IMKTextInput else { return false }

        guard event.type == .keyDown else {
            return false
        }

        #if DEBUG
        let firstHandleTrace = Self.pendingToggleTrace
        Self.pendingToggleTrace = nil
        firstHandleTrace?.mark(.firstHandle)
        #endif

        // 1. Resolve the session FIRST — all subsequent logic uses its fresh context.
        guard let session = ensureSession(for: client) else { return false }
        let composer = session.composer

        // 2. Duplicate-keyDown suppression. Some hosts (observed: KakaoTalk) deliver
        // the same physical keyDown to the IME twice. That double-processes input —
        // notably one backspace decomposing TWO jamo, or Return reaching the host
        // twice. Consume an exact re-delivery regardless of the original handled
        // result: returning false again would repeat the host's default action.
        let keyDownSnapshot = KeyDownSnapshot(event: event)
        if let handled = session.registerKeyDown(keyDownSnapshot).immediateHandledResult {
            DebugLogger.event("input.duplicate_keydown_dropped", metadata: [
                .flag("repeat", event.isARepeat)
            ])
            return handled
        }

        #if DEBUG
        if debugHandleLogCount < 200 {
            debugHandleLogCount += 1
            DebugLogger.event("input.handle", metadata: [
                .flag("repeat", event.isARepeat),
                .state("mode", composer.inputMode == .korean ? "korean" : "english"),
                .flag("lightweight_context", session.context.isLightweight),
                .flag("immediate_delivery", session.context.shouldUseImmediateMode)
            ])
        }
        #endif

        // 3. Mark keystroke with current app's bundleId for cross-app hanja validation
        composer.markKeystroke(bundleId: session.context.bundleId)

        // 4. DYNAMIC CHECK: Secure Input (password fields) — raw pass-through.
        if shouldPassThroughSecureInput(client: client, context: session.context) {
            return Self.routeSecureKeyDown(in: session, keyCode: event.keyCode)
        }

        // A previous Secure Input pass-through may have left PriType-owned marked
        // text in the host. This is the first point that proves client writes are
        // safe again; lifecycle callbacks alone must never perform this cleanup.
        _ = session.prepareForNonSecureClientWrites()

        // Apply a pending macOS ownership/source boundary only after the secure
        // client check. This makes the first normal key use Korean without allowing
        // an observer or activation callback to insert text into a password field.
        _ = InputModeCoordinator.shared.reconcileSystemOwnershipIfNeeded(for: self)

        // A custom toggle inside Secure Input changes only PriType's internal mode.
        // Synchronize the client keyboard layout now that this field passed the gate,
        // before the first key is interpreted in that mode.
        _ = session.reconcileDeferredRomanKeyboardLayoutSync { client, mode in
            self.syncRomanKeyboardLayout(for: client, mode: mode, force: true)
        }

        // 5. The delivery policy can flip mid-session (experimental flag toggled in
        // settings); make sure the adapter still matches before composing into it.
        session.ensureAdapterMatchesPolicy()

        // 6. Compose, then invalidate field identity for host-owned field boundaries.
        let handled = composer.handle(event, delegate: session.adapter)
        session.observeHostFieldBoundaryKeyDown(
            keyCode: event.keyCode,
            passedToHost: !handled
        )
        return handled
    }

    /// Secure fields receive the raw key. A host-passed field boundary can reuse the
    /// same client for another field, so invalidate context before the next key.
    static func routeSecureKeyDown(in session: InputSession, keyCode: UInt16) -> Bool {
        session.discardForSecureInput()
        session.observeHostFieldBoundaryKeyDown(keyCode: keyCode, passedToHost: true)
        return false
    }

    private func shouldPassThroughSecureInput(client: IMKTextInput, context: ClientContext) -> Bool {
        let bundleId = context.bundleId
        let isSystemSecureClient = SecureInputPolicy.isSystemSecureClient(bundleId)
        let hasGlobalSecureInput = !isSystemSecureClient && IsSecureEventInputEnabled()
        let requiresSelectionProbe = SecureInputPolicy.requiresSelectionProbe(
            bundleId: bundleId,
            hasTextInputCapability: context.hasTextInputCapability,
            hasGlobalSecureInput: hasGlobalSecureInput
        )
        let hasInvalidSelection = requiresSelectionProbe
            && client.selectedRange().location == NSNotFound
        let signals = SecureInputSignals(
            bundleId: bundleId,
            hasTextInputCapability: context.hasTextInputCapability,
            hasInvalidSelection: hasInvalidSelection,
            hasGlobalSecureInput: hasGlobalSecureInput
        )
        let isSecureInput = SecureInputPolicy.shouldPassThrough(signals)

        if isSecureInput {
            let reason: StaticString
            if isSystemSecureClient {
                reason = "system_client"
            } else if hasGlobalSecureInput {
                reason = "global_secure_input"
            } else {
                reason = "invalid_selection"
            }
            DebugLogger.event("input.secure_passthrough", metadata: [
                .state("reason", reason)
            ])
        }

        publishHanjaShortcutSessionState(isSecureInput ? .secure : .nonsecure)
        return isSecureInput
    }

    // 마우스 클릭 등으로 조합 영역 외부 클릭 시 조합 커밋
    override public func commitComposition(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK commitComposition must run on main thread")
        #endif
        _ = Self.routeHostCommitComposition(in: session, sender: sender)
        super.commitComposition(sender)
    }

    /// A host commit belongs only to the matching session. Once routed, field
    /// identity becomes stale even when there was no active composition to finalize.
    @discardableResult
    static func routeHostCommitComposition(in session: InputSession?, sender: Any?) -> Bool {
        guard let session else { return false }
        if let senderClient = sender as? IMKTextInput,
           !session.matches(senderClient) {
            DebugLogger.event("composition.finalize_ignored", metadata: [
                .state("reason", CompositionFinalizeReason.mouseCommit.diagnosticLabel),
                .state("cause", "stale_client")
            ])
            return false
        }

        _ = session.finalize(reason: .mouseCommit)
        session.finishHostCommitBoundary()
        return true
    }

    /// Route an external Hanja shortcut to the active session's composer. The
    /// composer is no longer process-global, so an inactive client cannot supply
    /// stale preedit or local-buffer state.
    public func triggerHanjaLookup() {
        #if DEBUG
        assert(Thread.isMainThread, "External Hanja lookup must run on main thread")
        #endif
        guard Self.sharedController === self else {
            DebugLogger.event("hanja.lookup_skipped", metadata: [
                .state("reason", "inactive_controller")
            ])
            return
        }
        guard let currentSession = session else { return }
        guard let activeSession = ensureSession(for: currentSession.client) else { return }
        let isSecureInput = shouldPassThroughSecureInput(
            client: activeSession.client,
            context: activeSession.context
        )
        Self.routeExternalHanjaLookup(
            in: activeSession,
            isSecureInput: isSecureInput,
            reconcileOwnership: {
                _ = InputModeCoordinator.shared.reconcileSystemOwnershipIfNeeded(for: self)
            },
            performLookup: { composer in
                composer.triggerHanjaLookup()
            }
        )
    }

    /// Preserve the same fail-closed ordering as keyDown for an external shortcut.
    /// Ownership reconciliation may finalize composition, so it must remain behind
    /// the secure gate and complete before the composer's Korean-mode guard runs.
    @discardableResult
    static func routeExternalHanjaLookup(
        in session: InputSession,
        isSecureInput: Bool,
        reconcileOwnership: () -> Void,
        performLookup: (HangulComposer) -> Void
    ) -> Bool {
        guard !isSecureInput else {
            session.discardForSecureInput()
            return false
        }
        _ = session.prepareForNonSecureClientWrites()
        reconcileOwnership()
        session.ensureAdapterMatchesPolicy()
        performLookup(session.composer)
        return true
    }

    // MARK: - Input Method Menu

    /// Returns custom menu for the input method (shown in system input source menu)
    override public func menu() -> NSMenu! {
        let menu = NSMenu()

        // Settings
        let settingsItem = NSMenuItem(title: "PriType 설정...", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "PriType 정보", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        return menu
    }

    @objc private func openSettings(_ sender: Any?) {
        DebugLogger.log("Opening settings")
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
    }

    @MainActor
    @objc private func showAbout(_ sender: Any?) {
        DebugLogger.log("Showing about")
        AboutInfo.showAlert()
    }
}
