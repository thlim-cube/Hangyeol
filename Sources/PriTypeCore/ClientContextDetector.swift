import Cocoa
import InputMethodKit
import Carbon.HIToolbox

// MARK: - SecureInputPolicy

/// Pure policy for deciding whether a secure-input-looking client should bypass IMK composition.
///
/// Avoid Accessibility probing on the keystroke hot path. System/global secure
/// signals pass through directly; with the global signal off, an invalid selection
/// is fail-closed only when the cached context also lacks text-input capability.
struct SecureInputSignals: Sendable {
    let bundleId: String
    let hasTextInputCapability: Bool
    let hasInvalidSelection: Bool
    let hasGlobalSecureInput: Bool
}

struct SecureInputPolicy: Sendable {
    static func isSystemSecureClient(_ bundleId: String) -> Bool {
        bundleId == "com.apple.SecurityAgent" ||
            bundleId == "com.apple.loginwindow" ||
            bundleId == "com.apple.screencaptureui"
    }

    static func shouldPassThrough(_ signals: SecureInputSignals) -> Bool {
        if isSystemSecureClient(signals.bundleId) {
            return true
        }

        return signals.hasGlobalSecureInput
            || (!signals.hasTextInputCapability && signals.hasInvalidSelection)
    }

    /// `selectedRange()` is client IPC on the keystroke hot path. Its result affects
    /// the fail-closed conjunction only when neither a system/global secure signal
    /// nor a cached text-input capability result has already decided the outcome.
    static func requiresSelectionProbe(
        bundleId: String,
        hasTextInputCapability: Bool,
        hasGlobalSecureInput: Bool
    ) -> Bool {
        !isSystemSecureClient(bundleId)
            && !hasGlobalSecureInput
            && !hasTextInputCapability
    }
}

// MARK: - ClientContext

enum HostSurface: Sendable, Equatable {
    case appKit
    case blinkWeb
    case blinkNative
    case finderNonText

    var diagnosticValue: StaticString {
        switch self {
        case .appKit: "appkit"
        case .blinkWeb: "blink_web"
        case .blinkNative: "blink_native"
        case .finderNonText: "finder_non_text"
        }
    }
}

struct IMKClientCapabilitySnapshot: Sendable, Equatable {
    enum CaretGeometry: Sendable, Equatable {
        case usable
        case finderDesktopSentinel
        case unavailable
    }

    let advertisesMarkedTextAttributes: Bool
    let advertisesDocumentAccess: Bool
    let hasUsableSelection: Bool
    let advertisesBlinkReplacementRange: Bool
    let caretGeometry: CaretGeometry

    var hasEditableTextEvidence: Bool {
        advertisesMarkedTextAttributes
            || advertisesDocumentAccess
            || hasUsableSelection
    }

    static let unknown = IMKClientCapabilitySnapshot(
        advertisesMarkedTextAttributes: false,
        advertisesDocumentAccess: false,
        hasUsableSelection: false,
        advertisesBlinkReplacementRange: false,
        caretGeometry: .unavailable
    )
}

enum HostSurfaceResolver {
    static func resolve(
        bundleId: String,
        capabilities: IMKClientCapabilitySnapshot
    ) -> HostSurface {
        if capabilities.advertisesBlinkReplacementRange {
            return .blinkWeb
        }

        if ClientCompatibilityPolicy.compositionRenderer(bundleId: bundleId) == .blink {
            if ClientCompatibilityPolicy.supportsBlinkNativeDirectInsertion(bundleId: bundleId),
               capabilities.hasEditableTextEvidence {
                return .blinkNative
            }
            return .blinkWeb
        }

        if bundleId == "com.apple.finder",
           !capabilities.hasEditableTextEvidence,
           capabilities.caretGeometry == .finderDesktopSentinel {
            return .finderNonText
        }

        return .appKit
    }
}

/// Represents the context of the current text input client
///
/// This struct encapsulates information about the client application and
/// its text input capabilities, enabling context-aware input handling.
public struct ClientContext: Sendable {
    let capabilities: IMKClientCapabilitySnapshot
    let hostSurface: HostSurface
    
    /// Bundle identifier of the client application
    public let bundleId: String
    
    /// Whether the client advertises marked-text capability. This remains separate
    /// from document-access and selection evidence because the secure-input policy
    /// uses this conservative signal.
    public let hasTextInputCapability: Bool
    
    /// Whether the client appears to be in a desktop/non-text area (coordinate heuristic)
    public let isLikelyDesktopArea: Bool

    /// Whether this context intentionally skipped client IPC for activation speed.
    public let isLightweight: Bool

    /// Whether the client reports a usable selection range (proxy for legacy
    /// Carbon `TSMDocumentAccess` support). When false, `insertText`'s
    /// `replacementRange` is unreliable — direct insertion would corrupt text, so
    /// the experimental direct-insertion path is denied. Probed once at activation.
    public let documentAccessSafe: Bool

    /// Whether a Blink host is exposing one of its native AppKit text fields.
    /// Web content accepts plain NSString marked text, while native fields (notably
    /// Chrome's omnibox) need real-text delivery on macOS 26 to avoid AppKit's
    /// attributed-marked-text crash.
    public let usesBlinkNativeTextClient: Bool

    public init(
        bundleId: String,
        hasTextInputCapability: Bool,
        isLikelyDesktopArea: Bool,
        isLightweight: Bool = false,
        documentAccessSafe: Bool = false,
        usesBlinkNativeTextClient: Bool = false
    ) {
        let inferredCapabilities = IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: hasTextInputCapability,
            advertisesDocumentAccess: documentAccessSafe,
            hasUsableSelection: documentAccessSafe,
            advertisesBlinkReplacementRange: false,
            caretGeometry: isLikelyDesktopArea ? .finderDesktopSentinel : .usable
        )
        self.bundleId = bundleId
        self.hasTextInputCapability = hasTextInputCapability
        self.isLikelyDesktopArea = isLikelyDesktopArea
        self.isLightweight = isLightweight
        self.documentAccessSafe = documentAccessSafe
        self.usesBlinkNativeTextClient = usesBlinkNativeTextClient
        self.capabilities = inferredCapabilities
        if bundleId == "com.apple.finder", isLikelyDesktopArea {
            self.hostSurface = .finderNonText
        } else if usesBlinkNativeTextClient,
                  ClientCompatibilityPolicy.supportsBlinkNativeDirectInsertion(
                      bundleId: bundleId
                  ) {
            self.hostSurface = .blinkNative
        } else if ClientCompatibilityPolicy.compositionRenderer(bundleId: bundleId) == .blink {
            self.hostSurface = .blinkWeb
        } else {
            self.hostSurface = .appKit
        }
    }

    init(
        bundleId: String,
        hasTextInputCapability: Bool,
        isLikelyDesktopArea: Bool,
        isLightweight: Bool = false,
        documentAccessSafe: Bool,
        capabilities: IMKClientCapabilitySnapshot,
        hostSurface: HostSurface
    ) {
        self.bundleId = bundleId
        self.hasTextInputCapability = hasTextInputCapability
        self.isLikelyDesktopArea = isLikelyDesktopArea
        self.isLightweight = isLightweight
        self.documentAccessSafe = documentAccessSafe
        self.usesBlinkNativeTextClient = hostSurface == .blinkNative
        self.capabilities = capabilities
        self.hostSurface = hostSurface
    }
    
    // MARK: - Derived Properties
    
    /// Whether the client is Finder
    public var isFinder: Bool {
        bundleId == "com.apple.finder"
    }
    
    /// Whether immediate mode should be used (skip marked text display)
    ///
    /// Finder's rename field can expose both an empty
    /// `validAttributesForMarkedText` list and the desktop dummy coordinates.
    /// Document-access or selection capability is stronger editor evidence than
    /// those heuristics.
    public var shouldUseImmediateMode: Bool {
        hostSurface == .finderNonText
    }
}

// MARK: - ClientCompatibilityPolicy

public enum ClientCompatibilityPolicy {
    private static let blinkReplacementRangeAttributeName =
        "NSTextInputReplacementRangeAttributeName"
    private static let goodNotesBundleId = "com.goodnotesapp.x"
    private static let hermesBundleIds: Set<String> = [
        "com.nousresearch.hermes",
        "com.nousresearch.hermes.setup"
    ]

    /// Apps where experimental direct insertion is known to be IMPOSSIBLE, not just
    /// risky: Electron/Chromium and browser web-content fields report `selectedRange`
    /// and `attributedSubstring` asynchronously / inaccurately, so the in-place
    /// rewrite cannot verify or target the live region — it desyncs the composition.
    /// (Confirmed in on-device logs: every keystroke tripped the caret-stability guard
    /// in Claude Desktop / Electron.) These keep the canonical marked-text path, which
    /// works fine there. This is graceful degradation, not a feature gate — direct
    /// insertion still runs in every NATIVE app (e.g. KakaoTalk, Notes). See
    /// Docs/KoreanWindowsInputFeasibility.md §2.
    private static let directInsertionDenylist: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",        // Arc
        "org.mozilla.firefox",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    public static func needsDirectNewlineAfterReturnCommit(bundleId: String) -> Bool {
        bundleId == goodNotesBundleId
    }

    /// Some chat-style hosts send the message on Return before their text system has
    /// incorporated the IMK commit. When Hangul is still marked, the submitted text can
    /// miss the last composing syllable. For those hosts, consume the Return that only
    /// finalizes composition; the next Return remains a normal send/newline action.
    public static func needsReturnConsumedAfterCompositionCommit(bundleId: String) -> Bool {
        hermesBundleIds.contains(bundleId)
    }

    /// Hermes is an Electron chat host whose send action can read the DOM value before
    /// Chromium has incorporated IMK marked text, dropping only the final Hangul
    /// syllable. Prefer real-text composition there when document access is usable.
    public static func prefersDirectInsertionForComposition(bundleId: String) -> Bool {
        hermesBundleIds.contains(bundleId)
    }

    /// Whether direct insertion must be denied for `bundleId` because the host cannot
    /// reliably support in-place real-text rewrites (Electron/Chromium/browsers).
    /// Explicit list + a keyword heuristic for unlisted Electron/Chromium wrappers.
    public static func directInsertionDenied(bundleId: String) -> Bool {
        if directInsertionDenylist.contains(bundleId) { return true }
        let lower = bundleId.lowercased()
        return lower.contains("electron")
            || lower.contains("chrome")
            || lower.contains("chromium")
    }

    /// Hosts whose text fields may be rendered by Blink (Chromium/Electron/CEF).
    /// Web-content clients receive plain NSString marked text; native fields owned
    /// by those apps are separated during context analysis and avoid marked text.
    private static let blinkRendererBundleIds: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "com.spotify.client",              // CEF
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",      // Arc
        "com.naver.whale",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    /// Blink hosts with a known native AppKit address field. Electron shells such
    /// as Slack and Codex render their editors in web content even when their text
    /// client omits Chromium's replacement-range attribute, so negative attribute
    /// evidence must never opt them into direct insertion.
    private static let blinkBrowserNativeTextClientBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",      // Arc
        "com.naver.whale",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    public static func compositionRenderer(bundleId: String) -> CompositionRenderer {
        if blinkRendererBundleIds.contains(bundleId) { return .blink }
        let lower = bundleId.lowercased()
        if lower.contains("electron") || lower.contains("chrome") || lower.contains("chromium") {
            return .blink
        }
        return .system
    }

    /// Chromium's RenderWidgetHostViewCocoa advertises this replacement-range
    /// attribute; Chrome's native AppKit fields do not. Keep this as a pure policy
    /// so the one activation-time IPC remains in ClientContextDetector.
    static func usesBlinkWebContentTextClient(
        bundleId: String,
        validAttributeNames: Set<String>
    ) -> Bool {
        compositionRenderer(bundleId: bundleId) == .blink
            && validAttributeNames.contains(blinkReplacementRangeAttributeName)
    }

    static func supportsBlinkNativeDirectInsertion(bundleId: String) -> Bool {
        blinkBrowserNativeTextClientBundleIds.contains(bundleId)
    }

    static func needsBlinkWebContentHostKeyMediation(
        bundleId: String,
        usesBlinkNativeTextClient: Bool
    ) -> Bool {
        if blinkBrowserNativeTextClientBundleIds.contains(bundleId) {
            return !usesBlinkNativeTextClient
        }

        // Electron shells in the renderer allowlist expose only web-content
        // editors even when their IMK client lacks Chromium's identifying
        // replacement-range attribute. Do not mistake that negative evidence
        // for a native AppKit field.
        return blinkRendererBundleIds.contains(bundleId)
            || bundleId.lowercased().contains("electron")
    }
}

/// Which engine renders the host's marked-text (composition) decoration.
/// `.system` covers AppKit/TextKit, Catalyst, WebKit (Safari) and everything else;
/// `.blink` is Chromium-derived hosts. Used only to pick preedit underline styling.
public enum CompositionRenderer: Sendable, Equatable {
    case system
    case blink
}

// MARK: - ClientContextDetector

/// Detects and analyzes the context of text input clients
///
/// This utility class extracts the complex client detection logic from
/// `PriTypeInputController`, improving maintainability and testability.
///
/// ## Usage
/// ```swift
/// let context = ClientContextDetector.analyze(client: sender as! IMKTextInput)
/// if context.shouldUseImmediateMode {
///     // Use ImmediateModeAdapter
/// }
/// ```
public struct ClientContextDetector: Sendable {
    private static let maxReasonableTextLocation = 10_000_000
    private static let documentAccessProperty = TSMDocumentPropertyTag(
        kTSMDocumentSupportDocumentAccessPropertyTag
    )

    private static func hasUsableSelection(_ range: NSRange) -> Bool {
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return range.location != NSNotFound
            && !overflow
            && range.location < maxReasonableTextLocation
            && end < maxReasonableTextLocation
    }

    /// Probe for legacy Carbon `TSMDocumentAccess` support. A client that returns a
    /// sane selection range honors `insertText(replacementRange:)`; NSNotFound
    /// (terminals/secure/launchers) or absurd values (Chromium garbage) mean the
    /// replacementRange is ignored, so direct insertion would corrupt text.
    /// One IPC call — done once per activation, never on the keystroke hot path.
    ///
    /// Gated on the experimental flag: when direct insertion is OFF (the default,
    /// shipping configuration) this returns false WITHOUT any IPC, so the marked-text
    /// path pays zero extra cost for a feature it never uses.
    static func probeDocumentAccessSafe(
        _ client: IMKTextInput,
        bundleId: String,
        allowBlinkNativeField: Bool = false
    ) -> Bool {
        guard ConfigurationManager.shared.experimentalDirectInsertion ||
              ClientCompatibilityPolicy.prefersDirectInsertionForComposition(bundleId: bundleId) ||
              allowBlinkNativeField else {
            return false
        }
        return hasUsableSelection(client.selectedRange())
    }

    private static func probeCapabilities(
        client: IMKTextInput,
        bundleId: String,
        validAttributeNames: Set<String>,
        validAttributesAreAdvertised: Bool
    ) -> IMKClientCapabilitySnapshot {
        let isFinder = bundleId == "com.apple.finder"
        let isBlink = ClientCompatibilityPolicy.compositionRenderer(bundleId: bundleId) == .blink
        let shouldProbeDocumentAccess = isFinder
            || isBlink
            || ConfigurationManager.shared.experimentalDirectInsertion
            || ClientCompatibilityPolicy.prefersDirectInsertionForComposition(bundleId: bundleId)

        let selectedRange = shouldProbeDocumentAccess
            ? client.selectedRange()
            : NSRange(location: NSNotFound, length: NSNotFound)
        let hasUsableSelection = hasUsableSelection(selectedRange)
        let advertisesDocumentAccess = client.supportsProperty(documentAccessProperty)

        let caretGeometry: IMKClientCapabilitySnapshot.CaretGeometry
        if isFinder {
            let rect = client.firstRect(
                forCharacterRange: NSRange(location: 0, length: 0),
                actualRange: nil
            )
            let isDesktopSentinel = rect.origin.x >= 0 && rect.origin.y >= 0
                && rect.origin.x < PriTypeConfig.finderDesktopThreshold
                && rect.origin.y < PriTypeConfig.finderDesktopThreshold
            caretGeometry = isDesktopSentinel ? .finderDesktopSentinel : .usable
        } else {
            caretGeometry = .unavailable
        }

        return IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: validAttributesAreAdvertised,
            advertisesDocumentAccess: advertisesDocumentAccess,
            hasUsableSelection: hasUsableSelection,
            advertisesBlinkReplacementRange: validAttributeNames.contains(
                "NSTextInputReplacementRangeAttributeName"
            ),
            caretGeometry: caretGeometry
        )
    }

    private static func logCapabilities(
        _ capabilities: IMKClientCapabilitySnapshot,
        surface: HostSurface
    ) {
        DebugLogger.event("host.capabilities", metadata: [
            .state("surface", surface.diagnosticValue),
            .flag("marked_attributes", capabilities.advertisesMarkedTextAttributes),
            .flag("document_access", capabilities.advertisesDocumentAccess),
            .flag("usable_selection", capabilities.hasUsableSelection),
            .flag("blink_replacement", capabilities.advertisesBlinkReplacementRange),
            .flag(
                "finder_desktop_sentinel",
                capabilities.caretGeometry == .finderDesktopSentinel
            )
        ])
    }

    public static func analyzeForActivation(client: IMKTextInput) -> ClientContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        var bundleId = frontmostApp?.bundleIdentifier ?? ""
        if bundleId.isEmpty {
            bundleId = client.bundleIdentifier() ?? ""
        }
        let isFinder = bundleId == "com.apple.finder"

        return ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: !isFinder,
            isLikelyDesktopArea: isFinder,
            isLightweight: true,
            documentAccessSafe: probeDocumentAccessSafe(client, bundleId: bundleId),
            capabilities: .unknown,
            hostSurface: isFinder ? .finderNonText : .appKit
        )
    }

    /// Analyzes an IMKTextInput client and returns its context
    ///
    /// - Parameter client: The text input client to analyze
    /// - Returns: A `ClientContext` containing the analysis results
    public static func analyze(client: IMKTextInput) -> ClientContext {
        // 1. FAST PATH: Check active application Bundle ID
        // Using NSWorkspace is generally faster and safer than generic IPC calls on the client
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        var bundleId = client.bundleIdentifier() ?? ""
        if bundleId.isEmpty, let app = frontmostApp {
            bundleId = app.bundleIdentifier ?? ""
        }
        
        // 2. Capabilities Check (Required for both Finder and standard apps)
        // Check text input capability via validAttributesForMarkedText
        let validAttrs = client.validAttributesForMarkedText() ?? []
        let hasTextInputCapability = !validAttrs.isEmpty
        let validAttributeNames = Set(validAttrs.compactMap { attribute -> String? in
            if let key = attribute as? NSAttributedString.Key {
                return key.rawValue
            }
            return attribute as? String
        })
        let capabilities = probeCapabilities(
            client: client,
            bundleId: bundleId,
            validAttributeNames: validAttributeNames,
            validAttributesAreAdvertised: !validAttrs.isEmpty
        )
        let hostSurface = HostSurfaceResolver.resolve(
            bundleId: bundleId,
            capabilities: capabilities
        )
        // 3. SECURE INPUT CHECK is no longer cached here.
        // It is checked dynamically in PriTypeInputController.handle() for better accuracy.
        
        // 4. CONDITIONAL HEURISTIC: Coordinate check ONLY for Finder
        // This prevents false positives in other apps (e.g. Safari tabs at top of screen)
        let isLikelyDesktopArea = capabilities.caretGeometry == .finderDesktopSentinel

        logCapabilities(capabilities, surface: hostSurface)
        
        return ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: hasTextInputCapability,
            isLikelyDesktopArea: isLikelyDesktopArea,
            documentAccessSafe: capabilities.advertisesDocumentAccess
                || capabilities.hasUsableSelection,
            capabilities: capabilities,
            hostSurface: hostSurface
        )
    }
}
