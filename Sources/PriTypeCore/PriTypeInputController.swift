import Cocoa
import InputMethodKit
import LibHangul
import Carbon.HIToolbox

/// Thin IMK edge of the input pipeline.
///
/// The controller owns nothing but the IMK lifecycle. Everything session-scoped —
/// client, analyzed context, delivery adapter, duplicate-keyDown state, focus-loss
/// safety net — lives in a single `InputSession`, and EVERY composition-ending event
/// (app deactivate, deactivateServer, mouse commit, custom toggle, keyboard-layout
/// change) funnels into `InputSession.finalize(reason:)`, the
/// one host-agnostic commit path.
///
/// ```
/// keyDown ──► handle() ──► ensureSession ──► dedup ──► secure gate ──► HangulComposer
///                                                                          │
///                  TextDeliveryAdapter (marked / direct / immediate) ◄─────┘
///
/// toggle key ──► InputModeCoordinator ──► performPriTypeModeTransition ─┐
/// app deactivate / deactivateServer / mouse commit / layout change ────┴─► session.finalize
/// ```
@objc(PriTypeInputController)
public class PriTypeInputController: IMKInputController, @unchecked Sendable {
    private static let romanKeyboardLayoutID = resolveRomanKeyboardLayoutID()
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
    // 1. `sharedComposer`: Created once at startup, accessed only via IMK callbacks
    // 2. `sharedController`: Read/written only in activateServer/deactivateServer
    //
    // This is a documented limitation of integrating Swift 6 strict concurrency with
    // legacy Objective-C frameworks like InputMethodKit.

    /// Shared composer instance for toggle key handler access
    /// - Warning: Access from main thread only (guaranteed by IMK, not compiler-enforced)
    public static let sharedComposer = HangulComposer()
    private var composer: HangulComposer { Self.sharedComposer }

    /// Last active controller reference for external toggle access
    /// - Warning: Access from main thread only (guaranteed by IMK, not compiler-enforced)
    nonisolated(unsafe) public static weak var sharedController: PriTypeInputController?

    /// The live input session (client + context + adapter + dedup + focus-loss net).
    /// Kept across deactivateServer — async Hanja callbacks and a `handle()` arriving
    /// before the next activateServer still need the adapter/context — and replaced
    /// when a different client appears.
    private var session: InputSession?

    /// Session-derived views for collaborators (Hanja lookup in `HangulComposer`).
    public var currentAdapter: (any HangulComposerDelegate)? { session?.adapter }
    public var cachedContext: ClientContext? { session?.context }

    #if DEBUG
    private var debugHandleLogCount = 0
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
    }

    // MARK: - Session Management

    /// Return the session for `client`, creating or refreshing it as needed.
    /// - A different client object ⇒ new session (full context analysis).
    /// - Same client after deactivateServer ⇒ re-analyze (focus may have moved to a
    ///   different field of the same app, e.g. a password field).
    /// - Finder lightweight context ⇒ re-analyze per keystroke (desktop vs. rename
    ///   field can only be told apart by coordinates at keystroke time).
    private func ensureSession(for client: IMKTextInput) -> InputSession {
        if let session, session.matches(client) {
            if session.contextNeedsRefresh {
                session.refreshContext(ClientContextDetector.analyze(client: client))
                session.armFocusLossFinalizer()
            } else if session.context.isLightweight && session.context.isFinder {
                session.refreshContext(ClientContextDetector.analyze(client: client))
            }
            return session
        }

        DebugLogger.log("PriTypeInputController: client changed or no session, analyzing (Slow Path)")
        let newSession = InputSession(
            client: client,
            context: ClientContextDetector.analyze(client: client),
            composer: composer
        )
        session?.disarmFocusLossFinalizer()
        session = newSession
        newSession.armFocusLossFinalizer()
        syncRomanKeyboardLayout(for: client)
        return newSession
    }

    /// Route a composition-ending event to the single finalize path. Prefers the
    /// session (it knows the delivery mode — direct insertion must NOT re-insert);
    /// falls back to a detached marked-text finalize when IMK hands us a sender the
    /// session has never seen.
    private func finalizeActiveComposition(sender: Any?, reason: CompositionFinalizeReason) {
        let senderClient = sender as? IMKTextInput
        if let session {
            if session.adapter is DirectInsertionAdapter
                || senderClient == nil
                || session.matches(senderClient!) {
                session.finalize(reason: reason)
                return
            }
        }
        if let senderClient, composer.hasActiveComposition {
            InputSession.finalizeMarkedComposition(composer: composer, client: senderClient, reason: reason)
        } else {
            session?.finalize(reason: reason)
        }
    }

    // MARK: - Keyboard Layout (English pass-through support)

    private func syncRomanKeyboardLayout(for client: IMKTextInput, force: Bool = false) {
        let clientID = ObjectIdentifier(client as AnyObject)
        let now = CFAbsoluteTimeGetCurrent()
        guard force || lastKeyboardOverrideClientID != clientID || now - lastKeyboardOverrideTime > 0.5 else {
            return
        }

        let selector = NSSelectorFromString("overrideKeyboardWithKeyboardNamed:")
        let object = client as AnyObject
        guard object.responds(to: selector) else {
            DebugLogger.log("PriTypeInputController: client does not support keyboard override")
            return
        }

        _ = object.perform(selector, with: Self.romanKeyboardLayoutID)
        lastKeyboardOverrideClientID = clientID
        lastKeyboardOverrideTime = now
        DebugLogger.log("PriTypeInputController: override keyboard layout -> \(Self.romanKeyboardLayoutID)")
    }

    private static func resolveRomanKeyboardLayoutID() -> String {
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

    public func performPriTypeModeTransition(source: InputModeCoordinator.ToggleSource) {
        guard let session else {
            DebugLogger.log("PriTypeInputController: no current session for mode transition (\(source))")
            return
        }

        let nextMode = composer.inputMode.toggled
        DebugLogger.log("PriTypeInputController: mode transition \(composer.inputMode) -> \(nextMode) source=\(source)")

        session.finalize(reason: .modeTransition)
        composer.clearLocalBuffer()
        syncRomanKeyboardLayout(for: session.client, force: true)
        composer.setInputMode(nextMode)
    }

    // MARK: - IMK Lifecycle

    // 입력기가 활성화될 때 호출 - 새 세션 시작
    override public func activateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK activateServer must run on main thread")
        #endif
        super.activateServer(sender)
        // NOTE: Focus changes never reset `composer.inputMode`. Korean/English state
        // is process-global and owned solely by the custom toggle path, so switching
        // clients, tabs, or apps preserves the user's last mode.
        if let client = sender as? IMKTextInput {
            syncRomanKeyboardLayout(for: client, force: true)

            // PERFORMANCE: Analyze context ONCE per activation (lightweight — no
            // client IPC) and let `ensureSession` upgrade it lazily. This avoids
            // heavy IPC calls (validAttributes, coordinates) on every focus change.
            let newSession = InputSession(
                client: client,
                context: ClientContextDetector.analyzeForActivation(client: client),
                composer: composer
            )
            session?.disarmFocusLossFinalizer()
            session = newSession
            newSession.armFocusLossFinalizer()
            DebugLogger.log("Activated for client: \(newSession.context.bundleId) (Lightweight Context)")
        } else {
            // Fallback if sender is not IMKTextInput (rare). Keep the old session's
            // adapter alive for async Hanja callbacks, but stop trusting its context
            // and stop watching focus on its behalf.
            session?.disarmFocusLossFinalizer()
            session?.markContextStale()
        }

        // Set as active controller for toggle access
        Self.sharedController = self

        // Ensure composer has correct layout (in case it changed while inactive)
        let currentLayoutId = ConfigurationManager.shared.keyboardId
        composer.updateKeyboardLayout(id: currentLayoutId)

        // Observe layout changes. IMK can call activateServer again without an
        // intervening deactivateServer (common in Electron/Chromium hosts), and
        // NotificationCenter allows duplicate (observer, selector, name)
        // registrations that would each fire handleLayoutChange. Remove any prior
        // registration first so this stays idempotent.
        NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleLayoutChange), name: .keyboardLayoutChanged, object: nil)
    }

    override public func deactivateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK deactivateServer must run on main thread")
        #endif
        // Fallback finalize. The primary path is the session's focus-loss observer (it
        // fires earlier, while the host still accepts input); by the time
        // deactivateServer runs, native hosts like KakaoTalk have already resigned and
        // ignore insertText. If the observer already committed, this is a no-op.
        finalizeActiveComposition(sender: sender, reason: .deactivateServer)
        // NOTE: Do NOT clear localTextBuffer here.
        // Cross-app hanja leaking is prevented by bundleId matching in handleHanjaLookup(),
        // not by clearing the buffer. Clearing would make same-app hanja lookup impossible.
        super.deactivateServer(sender)
        // Keep the session alive — async Hanja callbacks need the adapter, and a
        // handle() arriving before the next activateServer needs the context. But:
        // - disarm the focus-loss observer: the composer is shared, so a stale
        //   observer firing later would flush a NEWER session's composition into
        //   THIS client (the cross-app commit-leak class);
        // - mark the context stale so the next handle() re-analyzes it.
        session?.disarmFocusLossFinalizer()
        session?.markContextStale()
        NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
    }

    @objc private func handleLayoutChange() {
        let newId = ConfigurationManager.shared.keyboardId
        DebugLogger.log("PriTypeInputController: Layout changed to \(newId), updating composer")
        // Layout switches mid-composition end the composition like any other
        // session-ending event — through the single finalize path.
        if composer.keyboardLayoutId != newId {
            session?.finalize(reason: .keyboardLayoutChange)
        }
        composer.updateKeyboardLayout(id: newId)
    }

    // Match the native IMK path used by DINKIssTyle: ask IMK for flagsChanged
    // so TIS can drive Caps Lock language switching, then pass modifier events
    // through without doing any work in handle().
    override public func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
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

        // 1. Resolve the session FIRST — all subsequent logic uses its fresh context.
        let session = ensureSession(for: client)

        // 2. Duplicate-keyDown suppression. Some hosts (observed: KakaoTalk) deliver
        // the same physical keyDown to the IME twice. That double-processes input —
        // notably one backspace decomposing TWO jamo, i.e. a composing syllable
        // "deleted all at once". Drop the exact re-delivery and replay the original
        // result. Host-event-level, so it applies in every delivery mode.
        let keyDownSnapshot = KeyDownSnapshot(timestamp: event.timestamp, keyCode: event.keyCode, isARepeat: event.isARepeat)
        if session.registerKeyDown(keyDownSnapshot) {
            DebugLogger.log("PriTypeInputController: dropped duplicate keyDown keyCode=\(event.keyCode)")
            return session.lastHandleResult
        }

        #if DEBUG
        if debugHandleLogCount < 200 {
            debugHandleLogCount += 1
            DebugLogger.log("PriTypeInputController: handle keyCode=\(event.keyCode) repeat=\(event.isARepeat) mode=\(composer.inputMode) chars='\(event.characters ?? "")' modifiers=\(event.modifierFlags.rawValue) bundle=\(session.context.bundleId) lightweight=\(session.context.isLightweight) immediate=\(session.context.shouldUseImmediateMode)")
        }
        #endif

        // 3. Mark keystroke with current app's bundleId for cross-app hanja validation
        composer.markKeystroke(bundleId: session.context.bundleId)

        // 4. DYNAMIC CHECK: Secure Input (password fields) — raw pass-through.
        if shouldPassThroughSecureInput(client: client, context: session.context) {
            session.discardForSecureInput()
            return false
        }

        // 5. The delivery policy can flip mid-session (experimental flag toggled in
        // settings); make sure the adapter still matches before composing into it.
        session.ensureAdapterMatchesPolicy()

        // 6. Compose.
        let handled = composer.handle(event, delegate: session.adapter)
        session.recordHandleResult(handled)
        return handled
    }

    private func shouldPassThroughSecureInput(client: IMKTextInput, context: ClientContext) -> Bool {
        let bundleId = context.bundleId

        if SecureInputPolicy.isSystemSecureClient(bundleId) {
            DebugLogger.log("Secure Input: System secure client (\(bundleId)), passing through")
            return true
        }

        let hasGlobalSecureInput = IsSecureEventInputEnabled()

        if hasGlobalSecureInput {
            DebugLogger.log("Secure Input: global secure input active in '\(bundleId)', passing through")
            return true
        }

        guard !context.hasTextInputCapability else {
            return false
        }

        let selectionRange = client.selectedRange()
        let hasInvalidSelection = selectionRange.location == NSNotFound

        if hasInvalidSelection {
            DebugLogger.log("Secure Input: invalid selection in '\(bundleId)', passing through")
            return true
        }

        return false
    }

    // 마우스 클릭 등으로 조합 영역 외부 클릭 시 조합 커밋
    override public func commitComposition(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK commitComposition must run on main thread")
        #endif
        finalizeActiveComposition(sender: sender, reason: .mouseCommit)
        composer.localTextBuffer = "" // Clear buffer when focus changes or user clicks elsewhere
        super.commitComposition(sender)
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
