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
        NotificationCenter.default.removeObserver(self, name: .romanKeyboardLayoutPreferenceChanged, object: nil)
    }

    // MARK: - Session Management

    private func makeComposer() -> HangulComposer {
        HangulComposer(
            statusBar: StatusBarManager.shared,
            configuration: ConfigurationManager.shared,
            inputModeStore: Self.sharedInputModeStore
        )
    }

    private func replaceSession(client: IMKTextInput, context: ClientContext) -> InputSession {
        if let previous = session {
            previous.finalize(reason: .sessionReplacement)
            previous.disarmFocusLossFinalizer()
        }

        let newSession = InputSession(client: client, context: context, composer: makeComposer())
        newSession.composer.updateKeyboardLayout(id: ConfigurationManager.shared.keyboardId)
        session = newSession
        newSession.armFocusLossFinalizer()
        return newSession
    }

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
        let newSession = replaceSession(
            client: client,
            context: ClientContextDetector.analyze(client: client)
        )
        syncRomanKeyboardLayout(for: client)
        return newSession
    }

    /// Route a composition-ending event to the owning session only. A late callback
    /// for an older client must never finalize the currently active client's composer.
    @discardableResult
    private func finalizeActiveComposition(sender: Any?, reason: CompositionFinalizeReason) -> Bool {
        let senderClient = sender as? IMKTextInput
        guard let session else { return false }
        if let senderClient, !session.matches(senderClient) {
            DebugLogger.log("PriTypeInputController: ignored finalize for stale client reason=\(reason.rawValue)")
            return false
        }
        session.finalize(reason: reason)
        return true
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
            DebugLogger.log("PriTypeInputController: client does not support keyboard override")
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
        DebugLogger.log("PriTypeInputController: override keyboard layout -> \(layoutID)")
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
            DebugLogger.log("PriTypeInputController: current Roman layout lookup failed, keeping ABC/US fallback")
            return nil
        }
        let source = sourceReference.takeRetainedValue()
        guard inputSourceStringProperty(source, key: kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String,
              inputSourceBoolProperty(source, key: kTISPropertyInputSourceIsASCIICapable),
              let layoutID = inputSourceStringProperty(source, key: kTISPropertyInputSourceID),
              !layoutID.isEmpty else {
            DebugLogger.log("PriTypeInputController: current Roman layout unavailable, keeping ABC/US fallback")
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

    public func performPriTypeModeTransition(source: InputModeCoordinator.ToggleSource) {
        guard let session else {
            DebugLogger.log("PriTypeInputController: no current session for mode transition (\(source))")
            return
        }

        let composer = session.composer
        let nextMode = composer.inputMode.toggled
        DebugLogger.log("PriTypeInputController: mode transition \(composer.inputMode) -> \(nextMode) source=\(source)")

        session.finalize(reason: .modeTransition)
        composer.clearLocalBuffer()
        syncRomanKeyboardLayout(for: session.client, mode: nextMode, force: true)
        composer.setInputMode(nextMode)
    }

    // MARK: - IMK Lifecycle

    // 입력기가 활성화될 때 호출 - 새 세션 시작
    override public func activateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK activateServer must run on main thread")
        #endif
        super.activateServer(sender)
        // NOTE: Focus changes never reset the shared InputModeStore. Korean/English
        // state is process-global, while libhangul composition remains session-owned.
        if let client = sender as? IMKTextInput {
            syncRomanKeyboardLayout(for: client, force: true)

            if let session, session.matches(client) {
                // Electron/Chromium may activate the same client repeatedly without
                // deactivation. Keep that session's composer so an in-flight syllable
                // is not reset; refresh expensive context once at the next keyDown.
                session.markContextStale()
                session.armFocusLossFinalizer()
                DebugLogger.log("Reactivated existing input session")
            } else {
                // Analyze context lightly at activation and upgrade at first keyDown.
                let newSession = replaceSession(
                    client: client,
                    context: ClientContextDetector.analyzeForActivation(client: client)
                )
                newSession.markContextStale()
                DebugLogger.log("Activated new input session (lightweight context)")
            }
        } else {
            // Fallback if sender is not IMKTextInput (rare). Keep the old session's
            // adapter alive for async Hanja callbacks, but stop trusting its context
            // and stop watching focus on its behalf.
            session?.disarmFocusLossFinalizer()
            session?.markContextStale()
        }

        // Set as active controller for toggle access
        Self.sharedController = self

        // Ensure this session's composer has the current layout.
        let currentLayoutId = ConfigurationManager.shared.keyboardId
        session?.composer.updateKeyboardLayout(id: currentLayoutId)

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
        let senderClient = sender as? IMKTextInput
        let deactivatesCurrentSession = senderClient.map { session?.matches($0) == true } ?? true
        finalizeActiveComposition(sender: sender, reason: .deactivateServer)
        // NOTE: Do NOT clear localTextBuffer here.
        // Cross-app hanja leaking is prevented by bundleId matching in handleHanjaLookup(),
        // not by clearing the buffer. Clearing would make same-app hanja lookup impossible.
        super.deactivateServer(sender)
        // Keep the session alive — async Hanja callbacks need the adapter, and a
        // handle() arriving before the next activateServer needs the context. But:
        // - disarm the focus-loss observer so an inactive host never receives a
        //   redundant late finalize (composition state itself is session-owned);
        // - mark the context stale so the next handle() re-analyzes it.
        if deactivatesCurrentSession {
            session?.disarmFocusLossFinalizer()
            session?.markContextStale()
            NotificationCenter.default.removeObserver(self, name: .keyboardLayoutChanged, object: nil)
            NotificationCenter.default.removeObserver(self, name: .romanKeyboardLayoutPreferenceChanged, object: nil)
            if Self.sharedController === self {
                Self.sharedController = nil
            }
        }
    }

    @objc private func handleLayoutChange() {
        let newId = ConfigurationManager.shared.keyboardId
        DebugLogger.log("PriTypeInputController: Layout changed to \(newId), updating composer")
        // Layout switches mid-composition end the composition like any other
        // session-ending event — through the single finalize path.
        guard let session else { return }
        let composer = session.composer
        if composer.keyboardLayoutId != newId {
            session.finalize(reason: .keyboardLayoutChange)
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
              session.matches(client),
              MouseCompositionPolicy.shouldFinalize(
                  characterIndex: index,
                  markedRange: client.markedRange(),
                  hasActiveComposition: session.composer.hasActiveComposition
              ) else {
            return false
        }

        session.finalize(reason: .mouseCommit)
        session.composer.clearLocalBuffer()
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

        // 1. Resolve the session FIRST — all subsequent logic uses its fresh context.
        let session = ensureSession(for: client)
        let composer = session.composer

        // 2. Duplicate-keyDown suppression. Some hosts (observed: KakaoTalk) deliver
        // the same physical keyDown to the IME twice. That double-processes input —
        // notably one backspace decomposing TWO jamo, or Return reaching the host
        // twice. Consume an exact re-delivery regardless of the original handled
        // result: returning false again would repeat the host's default action.
        let keyDownSnapshot = KeyDownSnapshot(event: event)
        if let handled = session.registerKeyDown(keyDownSnapshot).immediateHandledResult {
            DebugLogger.log("PriTypeInputController: dropped duplicate keyDown keyCode=\(event.keyCode)")
            return handled
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
        return composer.handle(event, delegate: session.adapter)
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
        if finalizeActiveComposition(sender: sender, reason: .mouseCommit) {
            session?.composer.localTextBuffer = "" // Click invalidates this session's local context.
        }
        super.commitComposition(sender)
    }

    /// Route an external Hanja shortcut to the active session's composer. The
    /// composer is no longer process-global, so an inactive client cannot supply
    /// stale preedit or local-buffer state.
    public func triggerHanjaLookup() {
        session?.composer.triggerHanjaLookup()
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
