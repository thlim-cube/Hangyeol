import Cocoa
import LibHangul
import InputMethodKit

// Protocol and InputMode are now in HangulComposerTypes.swift
// Helper functions are now in CompositionHelpers.swift

// MARK: - HangulComposer

/// Core Hangul composition engine that wraps libhangul
///
/// `HangulComposer` handles the complete lifecycle of Hangul text input:
/// - Converting keystrokes to Hangul syllables
/// - Managing preedit (composition in progress) state
/// - Committing finalized text
/// - Applying Korean or English mode selected by the IMK controller
///
/// ## Overview
/// The composer uses `libhangul`'s `HangulInputContext` internally to perform
/// the actual character composition according to Korean keyboard layouts.
///
/// ## Usage
/// ```swift
/// let composer = HangulComposer()
/// let handled = composer.handle(keyEvent, delegate: myDelegate)
/// ```
///
/// ## Thread Safety
/// This class is not thread-safe. All calls should be made from the main thread.
public class HangulComposer: @unchecked Sendable {
    
    // MARK: - Public Properties
    
    /// The process-wide input mode (Korean or English).
    ///
    /// Composition state remains local to this composer, but every production
    /// session reads the same `InputModeStore` so focus changes preserve the user's
    /// last mode without sharing libhangul preedit state across clients.
    public var inputMode: InputMode { inputModeStore.mode }

    /// Whether the underlying Hangul engine currently has active composition.
    public var hasActiveComposition: Bool {
        !context.isEmpty()
    }

    /// Exact normalized preedit rendered through `setMarkedText`.
    /// Used only to verify that a repeated activation still exposes this composer's
    /// marked content before preserving field ownership.
    var activePreeditForDisplay: String {
        let preedit = context.getPreeditString()
        return CompositionHelpers.normalizeJamoForDisplay(preedit)
            .precomposedStringWithCanonicalMapping
    }
    
    // MARK: - Dependencies
    
    /// Status bar updater (injected for testability)
    private let statusBar: StatusBarUpdating
    
    /// Configuration provider (injected for testability)
    private let configuration: ConfigurationProviding

    /// Shared only in production controllers. Standalone/test composers receive a
    /// fresh store so their mode state cannot leak into one another.
    private let inputModeStore: InputModeStore

    /// Candidate presenter (injected in lifecycle tests so no real panel is opened).
    private let candidateWindow: any HanjaCandidatePresenting

    /// Production controllers provide a field/caret lease before a selectable panel
    /// is shown. Standalone composers may still exercise panel lifecycle behavior,
    /// but their callbacks cannot edit a client because they have no lease.
    private let captureHanjaSelectionLease: ((UInt64, String) -> HanjaSelectionSnapshot?)?
    
    // MARK: - Private Properties
    
    /// Weak fallback for calls that originate outside `handle(_:delegate:)`.
    private weak var lastDelegate: (any HangulComposerDelegate)?
    
    /// Whether Hanja candidate mode is currently active
    private var hanjaMode = false

    /// Identifies this composer when it uses the process-wide candidate presenter.
    private let hanjaOwnerID = UUID()

    /// The exact presenter generation owned by this composer, if any.
    private var hanjaPresentationID: HanjaCandidatePresentationID?
    
    /// Invalidates callbacks retained by a previous candidate window. A client can
    /// change between panel presentation and a mouse/keyboard selection.
    private var hanjaGeneration: UInt64 = 0
    
    /// Local cache of recently typed text to support double-space detection and Hanja lookup
    public var localTextBuffer: String = ""
    
    /// Maximum buffer size for local text tracking
    private let bufferMaxLength = 15
    
    /// Append text to the local buffer, trimming to max length
    private func appendToBuffer(_ text: String) {
        localTextBuffer.append(text)
        if localTextBuffer.count > bufferMaxLength {
            localTextBuffer = String(localTextBuffer.suffix(bufferMaxLength))
        }
    }
    
    // MARK: - libhangul Context
    // ThreadSafeHangulInputContext is thread-safe and supports synchronous calls.
    // It uses NSLock internally for synchronization.
    /// Active keyboard layout id ("2" 두벌식, "3" 세벌식, ...). Exposed so the
    /// controller can finalize through the session BEFORE a layout switch.
    public private(set) var keyboardLayoutId: String = HangyeolConfig.defaultKeyboardId
    private var context: ThreadSafeHangulInputContext = {
       let ctx = ThreadSafeHangulInputContext(keyboard: HangyeolConfig.defaultKeyboardId)
       DebugLogger.event("composer.context_configured")
       return ctx
    }()
    private let keyboardManager = HangulKeyboardManager()
    private var activeKeyboard: HangulKeyboard?
    
    /// Text convenience handler (double-space period)
    /// Owns all state for text convenience features
    private let textConvenience: TextConvenienceHandler
    
    // MARK: - Initialization
    
    /// Creates a new HangulComposer with default settings
    /// - Parameters:
    ///   - statusBar: Status bar updater (defaults to shared manager)
    ///   - configuration: Configuration provider (defaults to shared manager)
    public convenience init(
        statusBar: StatusBarUpdating = StatusBarManager.shared,
        configuration: ConfigurationProviding = ConfigurationManager.shared
    ) {
        self.init(
            statusBar: statusBar,
            configuration: configuration,
            inputModeStore: InputModeStore(),
            candidateWindow: HanjaCandidateWindow.shared
        )
    }

    convenience init(
        statusBar: StatusBarUpdating,
        configuration: ConfigurationProviding,
        inputModeStore: InputModeStore
    ) {
        self.init(
            statusBar: statusBar,
            configuration: configuration,
            inputModeStore: inputModeStore,
            candidateWindow: HanjaCandidateWindow.shared
        )
    }

    convenience init(
        statusBar: StatusBarUpdating,
        configuration: ConfigurationProviding,
        candidateWindow: any HanjaCandidatePresenting
    ) {
        self.init(
            statusBar: statusBar,
            configuration: configuration,
            inputModeStore: InputModeStore(),
            candidateWindow: candidateWindow
        )
    }

    init(
        statusBar: StatusBarUpdating,
        configuration: ConfigurationProviding,
        inputModeStore: InputModeStore,
        candidateWindow: any HanjaCandidatePresenting,
        captureHanjaSelectionLease: ((UInt64, String) -> HanjaSelectionSnapshot?)? = nil
    ) {
        self.statusBar = statusBar
        self.configuration = configuration
        self.inputModeStore = inputModeStore
        self.candidateWindow = candidateWindow
        self.captureHanjaSelectionLease = captureHanjaSelectionLease
        self.textConvenience = TextConvenienceHandler(
            isDoubleSpacePeriodEnabled: {
                configuration.doubleSpacePeriodEnabled
            },
            isAutoCapitalizationEnabled: {
                configuration.autoCapitalizationEnabled
            },
            isSmartQuoteSubstitutionEnabled: {
                configuration.smartQuoteSubstitutionEnabled
            },
            isSmartDashSubstitutionEnabled: {
                configuration.smartDashSubstitutionEnabled
            },
            isEnglishFallbackEnabled: {
                configuration.englishTextConvenienceFallbackEnabled
            }
        )
        self.activeKeyboard = keyboardManager.keyboard(for: keyboardLayoutId)
        DebugLogger.event("composer.initialized")
    }

    // MARK: - Public Methods
    
    /// Update the keyboard layout dynamically
    ///
    /// This method commits any in-progress composition before switching layouts
    /// to prevent text corruption.
    ///
    /// - Parameter id: The keyboard layout identifier (e.g., "2" for 두벌식, "3" for 세벌식)
    public func updateKeyboardLayout(id: String) {
        // Only re-create context if layout actually changed.
        // Electron apps trigger activateServer frequently, and re-creating
        // the context every time resets the composition state, causing the
        // first character to appear in English.
        guard keyboardLayoutId != id else {
            return
        }
        
        DebugLogger.event("composer.keyboard_layout_changing")
        // Commit existing text before switching to avoid corruption
        if let delegate = lastDelegate, !context.isEmpty() {
            commitComposition(delegate: delegate)
        }
        
        // Re-initialize context with new keyboard ID
        keyboardLayoutId = id
        context = ThreadSafeHangulInputContext(keyboard: id)
        activeKeyboard = keyboardManager.keyboard(for: id)
        clearLocalBuffer()
    }
    
    /// Set Korean or English mode from the Hangyeol controller.
    ///
    /// Custom toggle keys are coordinated by `InputModeCoordinator` and
    /// `HangyeolInputController` before reaching this method.
    /// - Important: `inputMode` is the single source of truth for the Korean/
    ///   English state. The only sanctioned writers are
    ///   `HangyeolInputController.performHangyeolModeTransition` (custom toggle) and
    ///   its macOS-owned input-source boundary reconciliation. No ordinary lifecycle
    ///   or IMK focus callback — including `activateServer` — may mutate the mode.
    public func setInputMode(_ mode: InputMode) {
        // A candidate belongs to the Korean-mode session that opened it. Invalidate
        // retained selection callbacks before changing mode (or honoring a repeated
        // setter call) so they cannot edit a later field.
        dismissHanjaCandidates()

        guard inputMode != mode else {
            return
        }

        DebugLogger.event("composer.mode_write_requested", metadata: [
            .state("mode", mode == .korean ? "korean" : "english")
        ])

        if let delegate = lastDelegate, !context.isEmpty() {
            commitComposition(delegate: delegate)
            DebugLogger.event("composition.committed_before_mode_write")
        }

        inputModeStore.setMode(mode)
        clearLocalBuffer()
        statusBar.setMode(inputMode)
        DebugLogger.event("composer.mode_written", metadata: [
            .state("mode", inputMode == .korean ? "korean" : "english")
        ])
    }

    // MARK: - Private Helpers
    
    /// Handle special keys (Return, Escape, Space, Arrow, Tab, Delete)
    /// - Returns: `nil` if not a special key, otherwise the result to return from handle()
    private func handleSpecialKey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        delegate: HangulComposerDelegate
    ) -> Bool? {
        // Return / Enter
        if keyCode == KeyCode.return || keyCode == KeyCode.numpadEnter {
            let hadComposition = !context.isEmpty()
            let usesBlinkComposition = lastInputHostSurface == .blinkWeb
            let isBlinkSoftLineBreak = keyCode == KeyCode.return
                && modifierFlags.contains(.shift)
                && usesBlinkComposition
            let hostOwnedReturnModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option
            ]
            let defersBlinkWebContentReturn = hadComposition
                && lastInputHostSurface == .blinkWeb
                && (lastInputBundleId != "com.google.Chrome" || modifierFlags.contains(.shift))
                && modifierFlags.intersection(hostOwnedReturnModifiers).isEmpty

            // Preserve Chrome's original plain Return path. Rich-editor soft
            // breaks (observed in Jira) can replace the last marked syllable even
            // after insertText returns, so Shift+Return must wait for retirement.
            // This uses the existing readiness check, not a fixed typing delay.
            // Blink can acknowledge the commit before the renderer retires its
            // marked range. Capture that range first so the host Return is released
            // only after the composition has actually become ordinary document text.
            let scheduledHostReturn = defersBlinkWebContentReturn
                && delegate.tryPerformHostKeyTransaction(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags.rawValue,
                    commit: {
                        commitComposition(delegate: delegate)
                    }
                )
            if !scheduledHostReturn {
                commitComposition(delegate: delegate)
            }
            if hadComposition
                && !isBlinkSoftLineBreak
                && !usesBlinkComposition {
                delegate.setMarkedText("")
            }
            localTextBuffer = ""

            if scheduledHostReturn {
                DebugLogger.event("input.return", metadata: [
                    .state("action", "commit_then_defer_until_mark_retired")
                ])
                return true
            }

            if hadComposition && ClientCompatibilityPolicy.needsDirectNewlineAfterReturnCommit(bundleId: lastInputBundleId) {
                delegate.insertText("\n")
                DebugLogger.event("input.return", metadata: [
                    .state("action", "insert_newline_and_consume")
                ])
                return true
            }

            if hadComposition && ClientCompatibilityPolicy.needsReturnConsumedAfterCompositionCommit(bundleId: lastInputBundleId) {
                DebugLogger.event("input.return", metadata: [
                    .state("action", "commit_and_consume")
                ])
                return true
            }

            DebugLogger.event("input.return", metadata: [
                .state("action", "pass_through"),
                .flag("had_composition", hadComposition)
            ])
            return false
        }
        
        // Escape - only consume if there's an active composition to cancel
        if keyCode == KeyCode.escape {
            if !context.isEmpty() {
                DebugLogger.event("composition.cancelled", metadata: [
                    .state("reason", "escape")
                ])
                cancelComposition(delegate: delegate)
                localTextBuffer = ""
                return true
            }
            localTextBuffer = ""
            return false  // No composition, pass to system (e.g. Finder close dialog)
        }
        
        // Space - handle double-space period
        if keyCode == KeyCode.space {
            commitComposition(delegate: delegate)
            let result = textConvenience.handleDoubleSpacePeriod(buffer: &localTextBuffer, delegate: delegate, checkHangul: true)
            if result == .convertedToPeriod {
                DebugLogger.event("text_convenience.applied", metadata: [
                    .state("feature", "double_space_period"),
                    .state("mode", "korean")
                ])
                return true
            }
            delegate.insertText(" ")
            appendToBuffer(" ")
            return true
        }
        
        // Non-space: reset space state
        textConvenience.resetSpaceState()
        
        // Arrow keys
        if keyCode == KeyCode.leftArrow || keyCode == KeyCode.rightArrow ||
           keyCode == KeyCode.upArrow || keyCode == KeyCode.downArrow {
            commitComposition(delegate: delegate)
            localTextBuffer = ""
            return false
        }
        
        // Tab
        if keyCode == KeyCode.tab {
            commitComposition(delegate: delegate)
            localTextBuffer = ""
            return false
        }

        // Forward Delete is host-owned: commit the current composition, then let
        // the app delete the character after the caret. Backspace remains owned
        // by the Hangul engine while a composition is active.
        if keyCode == KeyCode.forwardDelete {
            let hadComposition = !context.isEmpty()
            let hostOwnedDeleteModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option, .shift
            ]
            let defersBlinkWebContentDelete = hadComposition
                && lastInputHostSurface == .blinkWeb
                && lastInputBundleId != "com.google.Chrome"
                && modifierFlags.intersection(hostOwnedDeleteModifiers).isEmpty

            // Blink can expose two caret shapes while composing. The adapter keeps
            // the owned mark start so commit and following-range deletion can run
            // as one transaction without racing renderer retirement.
            let performedHostDeleteTransaction = defersBlinkWebContentDelete
                && delegate.tryPerformHostKeyTransaction(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags.rawValue,
                    commit: { [self] in
                        commitComposition(delegate: delegate)
                    }
                )

            if performedHostDeleteTransaction {
                localTextBuffer = ""
                DebugLogger.event("input.forward_delete", metadata: [
                    .state("action", "atomic_commit_then_delete_following_range")
                ])
                return true
            }

            commitComposition(delegate: delegate)
            localTextBuffer = ""
            return false
        }

        // Backspace
        if keyCode == KeyCode.backspace {
            if !localTextBuffer.isEmpty {
                localTextBuffer.removeLast()
            }
            if !context.isEmpty() {
                applyFineGrainedBackspacePolicy()
                if context.backspace() {
                    updateComposition(delegate: delegate)
                    return true
                } else {
                    updateComposition(delegate: delegate)
                    return true
                }
            }
            return false
        }
        
        return nil  // Not a special key
    }

    /// Process a single character through the Hangul engine
    /// - Returns: `true` if the character was processed, `false` if skipped
    private func processCharacter(_ char: Unicode.Scalar, delegate: HangulComposerDelegate) -> Bool {
        let charCode = UInt32(char.value)
        
        // Skip non-printable characters
        if KeyCode.shouldPassThrough(charCode) {
            return false
        }
        
        if shouldCommitBeforeExtendedI(char) {
            commitComposition(delegate: delegate)
        }

        // Primary attempt
        if context.process(Character(char)) {
            updateComposition(delegate: delegate)
            return true
        }
        
        // Failure case - try committing first then retry
        DebugLogger.event("composer.process_failed")
        
        if !context.isEmpty() {
            commitComposition(delegate: delegate)
        }
        
        // Retry with clean context
        if context.process(Character(char)) {
            DebugLogger.event("composer.retry_succeeded")
            updateComposition(delegate: delegate)
            return true
        }
        
        // Still failed - insert printable ASCII directly
        if KeyCode.isPrintableASCII(charCode) {
            DebugLogger.event("composer.retry_failed", metadata: [
                .state("fallback", "direct_insert")
            ])
            delegate.insertText(String(char))
            appendToBuffer(String(char))
            return true
        }
        
        DebugLogger.event("composer.retry_failed", metadata: [
            .state("fallback", "pass_through")
        ])
        return false
    }
    
    /// Handle a keyboard event
    ///
    /// This is the main entry point for processing keyboard input. The method
    /// determines whether to process the event as Hangul input, pass it through
    /// to the system, or handle it as a special key (Return, Space, etc.).
    ///
    /// - Parameters:
    ///   - event: The `NSEvent` to process (must be `.keyDown`)
    ///   - delegate: The delegate to receive composition callbacks
    /// - Returns: `true` if the event was consumed, `false` if it should be passed to the system
    public func handle(_ event: NSEvent, delegate: HangulComposerDelegate) -> Bool {
        // Keep a weak fallback for direct composer callers. Production external
        // lookups use the active controller's session-owned adapter first.
        self.lastDelegate = delegate
        
        // Only handle key down events for actual typing
        if event.type != .keyDown {
            return false
        }
        
        // Global context invalidation:
        // Any navigation or confirmation key (Arrow, Tab, Return) invalidates our local text context
        // because the cursor has likely moved, changing the text before it.
        let keyCode = event.keyCode
        if keyCode == KeyCode.leftArrow || keyCode == KeyCode.rightArrow ||
           keyCode == KeyCode.upArrow || keyCode == KeyCode.downArrow ||
           keyCode == KeyCode.tab || keyCode == KeyCode.return || keyCode == KeyCode.numpadEnter {
            clearLocalBuffer()
        }
        
        // English mode stays inside the Hangyeol input source but performs no
        // composition. Most keys pass through to the host app unchanged.
        // - Roman characters come from the keyboard layout that the controller
        //   installs via `overrideKeyboardWithKeyboardNamed` (ABC/US by default,
        //   or the user's current Roman layout when explicitly enabled).
        // - English text conveniences are host-owned by default. An explicit
        //   preference enables Hangyeol's fallback for hosts where substitutions
        //   do not fire. The handler consumes only actual transformations.
        // Keeping the default path pure pass-through avoids duplicate host
        // transformations and cursor-context drift.
        if inputMode == .english {
            if !context.isEmpty() {
                commitComposition(delegate: delegate)
            }
            localTextBuffer = ""
            if textConvenience.handleEnglishModeInput(event, delegate: delegate) {
                return true
            }
            return false
        }
        
        // If Hanja candidate window is visible, forward keys to it
        if hanjaMode, let presentationID = hanjaPresentationID {
            let consumed = candidateWindow.handleKey(
                event,
                presentationID: presentationID
            )
            if candidateWindow.visiblePresentationID != presentationID {
                invalidateHanjaState()
            }
            if consumed {
                return true
            }
            // If not consumed (regular key dismissed the window),
            // fall through to normal key processing below so the
            // keystroke is handled by the Hangul composer instead
            // of being passed raw to the app (which would produce English).
        }
        
        // Option key: no longer intercepted here.
        // Right Option key is handled via CGEventTap in RightCommandSuppressor.
        // Pass through if modifiers (Command, Control, Option) are present
        // This ensures system shortcuts work correctly without interference
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
             // Commit any in-progress composition first. Otherwise marked text stays
             // live and the host app ignores or misapplies the shortcut (e.g. Cmd+←).
             if !context.isEmpty() {
                 commitComposition(delegate: delegate)
             }
             localTextBuffer = "" // Any system shortcut (Cmd+V, Cmd+Z, etc.) invalidates local context
             return false
        }

        // Special keys are identified by hardware keyCode, not by their text
        // payload. Some IMK clients deliver Return/Numpad Enter with empty
        // `characters`; checking the payload first would leave the last Hangul
        // syllable uncommitted while the host performs its Return action.
        if let result = handleSpecialKey(
            keyCode: keyCode,
            modifierFlags: event.modifierFlags,
            delegate: delegate
        ) {
            return result
        }
        
        guard let characters = event.characters, !characters.isEmpty else {
            return false
        }
        
        let inputCharacters = normalizedHangulInputCharacters(
            characters,
            modifierFlags: event.modifierFlags
        )
        
        // Filter: If input contains non-printable characters (e.g., function keys, arrows)
        // This catches Fn+Arrow (Home/End/PageUp/PageDown) and other navigation keys
        // that don't match the KeyCode enum in handleSpecialKey.
        if let firstScalar = inputCharacters.unicodeScalars.first {
            let firstCharCode = UInt32(firstScalar.value)
            if KeyCode.shouldPassThrough(firstCharCode) {
                DebugLogger.event("input.non_text_key_passthrough")
                if !context.isEmpty() {
                    commitComposition(delegate: delegate)
                }
                localTextBuffer = ""
                return false
            }
        }
        
        var handledAtLeastOnce = false
        
        for char in inputCharacters.unicodeScalars {
            if processCharacter(char, delegate: delegate) {
                handledAtLeastOnce = true
            }
        }
        
        // If we processed anything, we return true to stop system from handling duplicates.
        return handledAtLeastOnce
    }

    private func mappedJamo(for scalar: Unicode.Scalar) -> UCSChar {
        activeKeyboard?.mapKey(Int(scalar.value)) ?? 0
    }

    private func currentSyllableJamo() -> HangulJamoCombination {
        let preedit = context.getPreeditString()
        var result = HangulJamoCombination()
        for code in preedit {
            if HangulCharacter.isSyllable(code) {
                return HangulCharacter.syllableToJamo(code)
            }
            if HangulCharacter.isChoseong(code) {
                result.choseong = code
            } else if HangulCharacter.isJungseong(code) {
                result.jungseong = code
            } else if HangulCharacter.isJongseong(code) {
                result.jongseong = code
            } else if (0x314F...0x3163).contains(code) {
                result.jungseong = HangulCharacter.compatibilityJamoToJamo(code, as: .jungseong)
            } else if HangulCharacter.isCJamo(code) {
                let asChoseong = HangulCharacter.compatibilityJamoToJamo(code, as: .choseong)
                if HangulCharacter.isChoseong(asChoseong) {
                    result.choseong = asChoseong
                    continue
                }
                let asJongseong = HangulCharacter.compatibilityJamoToJamo(code, as: .jongseong)
                if HangulCharacter.isJongseong(asJongseong) {
                    result.jongseong = asJongseong
                }
            }
        }
        return result
    }

    private func shouldCommitBeforeExtendedI(_ char: Unicode.Scalar) -> Bool {
        guard !configuration.extendedVowelCombinationEnabled else { return false }
        guard mappedJamo(for: char) == 0x1175 else { return false }
        guard !context.isEmpty() else { return false }
        let jamo = currentSyllableJamo()
        guard jamo.jongseong == 0 else { return false }
        switch jamo.jungseong {
        case 0x1161, 0x1163, 0x1165, 0x1167:
            return true
        default:
            return false
        }
    }

    private func isNoFinalExtendedTargetVowel() -> Bool {
        let jamo = currentSyllableJamo()
        guard jamo.jongseong == 0 else { return false }
        switch jamo.jungseong {
        case 0x1162, 0x1164, 0x1166, 0x1168:
            return true
        default:
            return false
        }
    }

    private func applyFineGrainedBackspacePolicy() {
        let atomic = !configuration.extendedVowelCombinationEnabled
            && isNoFinalExtendedTargetVowel()
        context.setOption(.fineGrainedBackspace, value: !atomic)
    }

    /// NSEvent characters reflect the combined Caps Lock and Shift state. When
    /// the user disables Caps Lock double consonants, derive Korean key casing
    /// from the physical Shift flag alone so Shift+key remains unchanged.
    private func normalizedHangulInputCharacters(
        _ characters: String,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String {
        guard modifierFlags.contains(.capsLock),
              !configuration.capsLockProducesDoubleConsonants else {
            return characters
        }

        let usesShift = modifierFlags.contains(.shift)
        var normalized = ""
        for scalar in characters.unicodeScalars {
            let value = scalar.value
            let normalizedValue: UInt32
            if (65...90).contains(value) {
                normalizedValue = usesShift ? value : value + 32
            } else if (97...122).contains(value) {
                normalizedValue = usesShift ? value - 32 : value
            } else {
                normalizedValue = value
            }
            normalized.append(Character(String(Unicode.Scalar(normalizedValue)!)))
        }
        return normalized
    }
    
    /// Updates the marked text and commits any finalized text
    ///
    /// This method retrieves the current preedit (composition in progress) and commit
    /// strings from libhangul, then updates the delegate accordingly:
    /// - Committed text is inserted immediately
    /// - Preedit text replaces the current marked text
    ///
    /// - Parameter delegate: The delegate to receive composition updates
    private func updateComposition(delegate: HangulComposerDelegate) {
        let preedit = context.getPreeditString()
        let commit = context.getCommitString()

        // ORDERING INVARIANT (load-bearing — do not reorder):
        // commit (insertText) MUST happen BEFORE the preedit update (setMarkedText).
        // This is the macOS equivalent of the Windows Korean IME model — only the
        // single in-progress syllable is ever "marked", and the previous syllable is
        // committed the instant libhangul emits it on a syllable boundary. Reordering
        // (mark-before-commit) reintroduces stale-cursor preedit (cf. kitty #4219) and
        // breaks the experimental DirectInsertionAdapter, which relies on insertText
        // arriving first to finalize the live preedit before the new one is rendered.
        // See ARCHITECTURE.md, "입력 처리 흐름".
        if !commit.isEmpty {
            let finalStr = CompositionHelpers.convertAndNormalize(commit)
            delegate.insertText(finalStr)
            appendToBuffer(finalStr)
        }

        // Update preedit text (the single live syllable).
        if !preedit.isEmpty {
            let preeditStr = CompositionHelpers.normalizeJamoForDisplay(preedit)
            delegate.setMarkedText(preeditStr)
        } else {
             delegate.setMarkedText("")
        }
    }
    
    /// Commits the current composition by flushing the libhangul context
    ///
    /// Flushes all pending text from the context and inserts it as finalized text.
    /// The committed string is normalized using precomposed canonical mapping to
    /// ensure proper Unicode representation.
    ///
    /// - Parameter delegate: The delegate to receive the committed text
    private func commitComposition(delegate: HangulComposerDelegate) {
        // Flush context
        let flushed = context.flush()
        let commitStr = CompositionHelpers.convertToString(flushed)

        if !commitStr.isEmpty {
            // insertText replaces the marked text automatically
            let finalStr = CompositionHelpers.convertAndNormalize(flushed)
            delegate.insertText(finalStr)
            appendToBuffer(finalStr)
            DebugLogger.event("composition.committed", metadata: [
                .count("length", finalStr.count)
            ])
        }
    }

    /// Cancels the current composition without committing
    ///
    /// Resets the libhangul context and clears the marked text display.
    /// Use this when the user explicitly cancels input (e.g., pressing Escape).
    ///
    /// - Parameter delegate: The delegate to receive the cleared state
    private func cancelComposition(delegate: HangulComposerDelegate) {
        context.reset()
        delegate.setMarkedText("")
        // Do NOT clear localTextBuffer on cancel, as previously committed text is still valid context
    }
    
    /// Force commit any in-progress composition
    ///
    /// Called when the input method is about to be deactivated or when
    /// text needs to be finalized immediately (e.g., before window switch).
    ///
    /// - Parameter delegate: The delegate to receive the committed text
    public func forceCommit(delegate: HangulComposerDelegate) {
        commitComposition(delegate: delegate)
        // Preserve the last Hangul character for Hanja lookup.
        // Electron apps (Chrome, VS Code) trigger frequent deactivateServer calls
        // which call forceCommit. Clearing the entire buffer makes Hanja lookup impossible.
        if let lastChar = localTextBuffer.last, lastChar.isHangulChar {
            localTextBuffer = String(lastChar)
        } else {
            localTextBuffer = ""
        }
    }

    /// Flush any in-progress composition and return its committed NFC string ("" if none).
    ///
    /// Unlike `forceCommit`, this does NOT insert via a delegate — the caller inserts the
    /// returned text itself. `deactivateServer` uses this to commit straight to the
    /// deactivating client with an explicit `replacementRange` over the marked text, which
    /// reliably clears a stranded preedit during a focus transition (some hosts, e.g.
    /// KakaoTalk, do not honor insertText's automatic marked-text replacement at that moment).
    public func flushCommitString() -> String {
        guard !context.isEmpty() else { return "" }
        let flushed = context.flush()
        let committed = CompositionHelpers.convertAndNormalize(flushed)
        if let lastChar = committed.last, lastChar.isHangulChar {
            localTextBuffer = String(lastChar)
        } else {
            localTextBuffer = ""
        }
        return committed
    }
    
    /// Reset the composition state
    ///
    /// Clears any in-progress composition without committing it.
    /// Use this when composition should be discarded (e.g., after Escape key).
    ///
    /// - Parameter delegate: The delegate to receive the cleared marked text
    public func reset(delegate: HangulComposerDelegate) {
        context.reset()
        delegate.setMarkedText("")
        delegate.insertText("") 
        localTextBuffer = ""
    }
    
    /// Clear field-local text context without affecting composition state.
    public func clearLocalBuffer() {
        localTextBuffer = ""
        resetTextConvenienceState()
    }

    /// Invalidate timing-based conveniences without changing composition or Hanja context.
    func resetTextConvenienceState() {
        textConvenience.resetSpaceState()
    }

    /// Drops in-progress composition without touching the current client.
    ///
    /// Secure text fields must receive raw key events from the system. Calling
    /// `setMarkedText` or `insertText` while focus is inside a password field can
    /// trigger host-app warning beeps, so this reset intentionally has no delegate.
    public func discardCompositionForPassThrough() {
        context.reset()
        clearLocalBuffer()
    }
    
    /// Bundle ID of the app where the last keystroke was processed.
    /// Used to prevent cross-app hanja leaking: if the current app differs from
    /// the app that populated localTextBuffer, the buffer is considered stale.
    private var lastInputBundleId: String = ""
    private var lastInputHostSurface: HostSurface = .appKit
    
    /// Record which app the current keystroke is from (called from handle via controller)
    public func markKeystroke(
        bundleId: String,
        usesBlinkNativeTextClient: Bool = false
    ) {
        let hostSurface: HostSurface
        if usesBlinkNativeTextClient,
           ClientCompatibilityPolicy.supportsBlinkNativeDirectInsertion(bundleId: bundleId) {
            hostSurface = .blinkNative
        } else if ClientCompatibilityPolicy.compositionRenderer(bundleId: bundleId) == .blink {
            hostSurface = .blinkWeb
        } else {
            hostSurface = .appKit
        }
        markKeystroke(bundleId: bundleId, hostSurface: hostSurface)
    }

    func markKeystroke(bundleId: String, hostSurface: HostSurface) {
        lastInputBundleId = bundleId
        lastInputHostSurface = hostSurface
    }
    
    /// Check if the buffer belongs to the given app
    public func isBufferFromApp(_ bundleId: String) -> Bool {
        return !lastInputBundleId.isEmpty && lastInputBundleId == bundleId
    }
    
    // MARK: - Hanja Lookup

    /// End the current candidate interaction and invalidate callbacks captured by
    /// its panel. Controllers call this whenever the owning input session ends.
    func dismissHanjaCandidates() {
        let presentationID = hanjaPresentationID
        invalidateHanjaState()
        if let presentationID {
            candidateWindow.dismiss(presentationID: presentationID)
        }
    }

    private func invalidateHanjaState() {
        hanjaGeneration &+= 1
        hanjaMode = false
        hanjaPresentationID = nil
    }
    
    /// Trigger Hanja lookup externally (called by RightCommandSuppressor via CGEventTap)
    ///
    /// This is the public entry point for Hanja conversion.
    /// Acts as a toggle: dismisses if already visible, opens if not.
    public func triggerHanjaLookup() {
        // The presenter is process-wide while composers are session-local. Dismiss
        // the exact visible generation, including one orphaned by an old composer.
        if let visiblePresentationID = candidateWindow.visiblePresentationID {
            if visiblePresentationID == hanjaPresentationID {
                dismissHanjaCandidates()
            } else {
                invalidateHanjaState()
                candidateWindow.dismiss(presentationID: visiblePresentationID)
            }
            DebugLogger.event("hanja.window_toggled_off")
            return
        }

        // Recover if AppKit hid the panel without delivering its dismiss callback.
        if hanjaMode {
            invalidateHanjaState()
        }
        
        // Production lookups use the active session-owned adapter. Standalone callers
        // can still use the most recent delegate while its owner keeps it alive.
        let activeDelegate = HangyeolInputController.sharedController?.currentAdapter
            ?? lastDelegate
        guard let delegate = activeDelegate else {
            DebugLogger.event("hanja.lookup_skipped", metadata: [
                .state("reason", "no_active_delegate")
            ])
            return
        }
        _ = handleHanjaLookup(delegate: delegate)
    }
    
    /// Handle Option key to trigger Hanja candidate lookup
    /// Searches based on the current preedit (composing) text, or the last committed Hangul character
    private func handleHanjaLookup(delegate: HangulComposerDelegate) -> Bool {
        guard inputMode == .korean else {
            DebugLogger.event("hanja.lookup_skipped", metadata: [
                .state("reason", "english_mode")
            ])
            return false
        }
        
        // Search key: only use OWNED state (preedit or localTextBuffer).
        // Previously we had fallback strategies using textBeforeCursor/attributedSubstring,
        // but those pick up existing text in the field that wasn't just typed,
        // causing false-positive hanja windows in Chromium/Electron apps.
        var searchKey = ""
        var hadPreedit = false
        
        // Strategy 1: Current preedit (composing text) — most reliable
        let preedit = context.getPreeditString()
        let preeditStr = CompositionHelpers.convertAndNormalize(preedit)
        
        if !preeditStr.isEmpty {
            searchKey = preeditStr
            hadPreedit = true
            DebugLogger.event("hanja.lookup_source", metadata: [
                .state("source", "composition"),
                .count("length", searchKey.count)
            ])
        }
        
        // Strategy 2: localTextBuffer (last typed character) — only if from the same app
        // Cross-app check: if the current focused app differs from the app that populated
        // the buffer, the buffer content is stale and should not trigger hanja.
        if searchKey.isEmpty {
            // Use NSWorkspace as the primary source of truth for frontmost app, because
            // cachedContext might be stale if the user clicked a non-text area in a new app.
            let currentBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                ?? HangyeolInputController.sharedController?.cachedContext?.bundleId ?? ""
            if isBufferFromApp(currentBundleId),
               let lastChar = localTextBuffer.last, lastChar.isHangulChar {
                searchKey = String(lastChar)
                DebugLogger.event("hanja.lookup_source", metadata: [
                    .state("source", "local_buffer"),
                    .count("length", searchKey.count)
                ])
            }
        }
        
        // Strategy 3: Read text before cursor if buffer is empty and no preedit
        // This handles cases where the user used arrow keys to move the cursor
        if searchKey.isEmpty {
            if let text = delegate.textBeforeCursor(length: 1), let lastChar = text.last, lastChar.isHangulChar {
                searchKey = String(lastChar)
                DebugLogger.event("hanja.lookup_source", metadata: [
                    .state("source", "cursor_context"),
                    .count("length", searchKey.count)
                ])
            }
        }
        
        guard !searchKey.isEmpty else {
            DebugLogger.event("hanja.lookup_skipped", metadata: [
                .state("reason", "no_candidate_text")
            ])
            return true // Consume the key but don't open the window
        }
        
        let entries = HanjaManager.shared.search(key: searchKey)
        guard !entries.isEmpty else {
            DebugLogger.event("hanja.lookup_completed", metadata: [
                .count("result_count", 0),
                .count("query_length", searchKey.count)
            ])
            return true
        }
        
        DebugLogger.event("hanja.lookup_completed", metadata: [
            .count("result_count", entries.count),
            .count("query_length", searchKey.count)
        ])
        
        hanjaMode = true
        hanjaGeneration &+= 1
        let snapshotGeneration = hanjaGeneration
        let presentationID = HanjaCandidatePresentationID(
            ownerID: hanjaOwnerID,
            generation: snapshotGeneration
        )
        hanjaPresentationID = presentationID
        
        // IMPORTANT: Capture cursor position BEFORE commit.
        // Chromium/Electron apps update cursor position asynchronously after commit,
        // so firstRect() returns garbage values if called after commitComposition().
        // While preedit is active, the cursor is at the marked text position → valid
        // coordinates. The strategy chain lives in CursorRectResolver.
        let controller = HangyeolInputController.sharedController
        let inputClient = controller?.activeSessionClient
        let cursorRect = CursorRectResolver.resolve(
            client: inputClient,
            sessionID: controller?.activeSessionIdentifier
        )

        // Commit preedit AFTER capturing cursor position
        if hadPreedit {
            commitComposition(delegate: delegate)
            guard hanjaGeneration == snapshotGeneration,
                  hanjaPresentationID == presentationID,
                  hanjaMode else {
                DebugLogger.event("hanja.lookup_skipped", metadata: [
                    .state("reason", "invalidated_during_commit")
                ])
                return true
            }
        }
        
        // Capture immutable lookup state for the retained selection callback.
        let selectionSearchKey = searchKey
        let replacementLength = selectionSearchKey.utf16.count
        let replacementCharacterCount = selectionSearchKey.count
        
        // Production callbacks require the current session's client, field generation,
        // caret, and source text to remain owned at selection time.
        let selectionSnapshot = captureHanjaSelectionLease?(
            snapshotGeneration,
            selectionSearchKey
        )
        guard (captureHanjaSelectionLease == nil || selectionSnapshot != nil),
              hanjaGeneration == snapshotGeneration,
              hanjaPresentationID == presentationID,
              hanjaMode else {
            DebugLogger.event("hanja.lookup_skipped", metadata: [
                .state("reason", "selection_not_owned")
            ])
            invalidateHanjaState()
            return true
        }
        
        candidateWindow.show(
            presentationID: presentationID,
            entries: entries,
            cursorRect: cursorRect,
            onSelect: { [weak self] entry in
                guard let self = self else { return }
                guard self.hanjaGeneration == snapshotGeneration,
                      self.hanjaPresentationID == presentationID,
                      self.hanjaMode else {
                    DebugLogger.event("hanja.selection_aborted", metadata: [
                        .state("reason", "stale_generation")
                    ])
                    return
                }

                guard let snapshot = selectionSnapshot,
                      let activeController = HangyeolInputController.sharedController,
                      let activeSessionID = activeController.activeSessionIdentifier,
                      let activeClient = activeController.activeSessionClient,
                      snapshot.matches(
                          generation: self.hanjaGeneration,
                          clientID: ObjectIdentifier(activeClient as AnyObject),
                          sessionID: activeSessionID
                      ) else {
                    DebugLogger.event("hanja.selection_aborted", metadata: [
                        .state("reason", "session_changed")
                    ])
                    self.invalidateHanjaState()
                    return
                }

                guard activeController.applyHanjaSelection(
                    snapshot: snapshot,
                    expectedText: selectionSearchKey,
                    replacement: entry.hanja
                ) else {
                    DebugLogger.event("hanja.selection_aborted", metadata: [
                        .state("reason", "field_not_owned")
                    ])
                    self.invalidateHanjaState()
                    return
                }

                self.localTextBuffer = String(self.localTextBuffer.dropLast(replacementCharacterCount)) + entry.hanja
                self.invalidateHanjaState()
                DebugLogger.event("hanja.candidate_selected", metadata: [
                    .count("replacement_length", replacementLength)
                ])
            },
            onDismiss: { [weak self] in
                guard let self,
                      self.hanjaGeneration == snapshotGeneration,
                      self.hanjaPresentationID == presentationID else { return }
                self.invalidateHanjaState()
                DebugLogger.event("hanja.window_dismissed")
            }
        )
        
        return true
    }
    
    // MARK: - Cursor Position Validation

    /// Forwarder kept for API stability (tests/benchmark). The implementation and
    /// the full coordinate strategy chain live in `CursorRectResolver`.
    public static func isValidCursorRect(_ rect: NSRect) -> Bool {
        CursorRectResolver.isValidCursorRect(rect)
    }

    func ownsHanjaSelection(generation: UInt64) -> Bool {
        hanjaGeneration == generation && hanjaMode && inputMode == .korean
    }
}

/// Identity captured when a candidate panel opens. InputMethodKit may reuse the
/// same client object across fields, so both client and `InputSession` identity are
/// required in addition to the composer generation.
struct HanjaSelectionSnapshot {
    let generation: UInt64
    let clientID: ObjectIdentifier
    let sessionID: ObjectIdentifier
    let fieldGeneration: UInt64
    let selectionLocation: Int

    func matches(
        generation: UInt64,
        clientID: ObjectIdentifier,
        sessionID: ObjectIdentifier
    ) -> Bool {
        self.generation == generation
            && self.clientID == clientID
            && self.sessionID == sessionID
    }
}

// MARK: - Character Extension for Hangul detection
extension Character {
    var isHangulChar: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        // Hangul Syllables: U+AC00 - U+D7A3
        // Hangul Jamo: U+1100 - U+11FF
        // Hangul Compatibility Jamo: U+3130 - U+318F
        let v = scalar.value
        return (v >= 0xAC00 && v <= 0xD7A3) ||
               (v >= 0x1100 && v <= 0x11FF) ||
               (v >= 0x3130 && v <= 0x318F)
    }
}
