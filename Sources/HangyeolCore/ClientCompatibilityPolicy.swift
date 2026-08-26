import Foundation

/// Bundle-level compatibility evidence used only when field capabilities cannot
/// distinguish the host implementation.
public enum ClientCompatibilityPolicy {
    private static let goodNotesBundleId = "com.goodnotesapp.x"
    private static let hermesBundleIds: Set<String> = [
        "com.nousresearch.hermes",
        "com.nousresearch.hermes.setup"
    ]

    /// Hosts that cannot safely verify and rewrite direct-insertion ranges.
    private static let directInsertionDenylist: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    private static let blinkRendererBundleIds: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "com.spotify.client",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.naver.whale",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    /// Blink processes with known native AppKit address/search fields.
    private static let blinkBrowserNativeTextClientBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.naver.whale",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    public static func needsDirectNewlineAfterReturnCommit(bundleId: String) -> Bool {
        bundleId == goodNotesBundleId
    }

    public static func needsReturnConsumedAfterCompositionCommit(bundleId: String) -> Bool {
        hermesBundleIds.contains(bundleId)
    }

    public static func prefersDirectInsertionForComposition(bundleId: String) -> Bool {
        hermesBundleIds.contains(bundleId)
    }

    public static func directInsertionDenied(bundleId: String) -> Bool {
        if directInsertionDenylist.contains(bundleId) { return true }
        let lower = bundleId.lowercased()
        return lower.contains("electron")
            || lower.contains("chrome")
            || lower.contains("chromium")
    }

    public static func compositionRenderer(bundleId: String) -> CompositionRenderer {
        if blinkRendererBundleIds.contains(bundleId) { return .blink }
        let lower = bundleId.lowercased()
        if lower.contains("electron") || lower.contains("chrome") || lower.contains("chromium") {
            return .blink
        }
        return .system
    }

    static func supportsBlinkNativeDirectInsertion(bundleId: String) -> Bool {
        blinkBrowserNativeTextClientBundleIds.contains(bundleId)
    }

}

/// The engine that renders the host's marked-text decoration.
public enum CompositionRenderer: Sendable, Equatable {
    case system
    case blink
}
