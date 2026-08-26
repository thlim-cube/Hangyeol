import Cocoa
import InputMethodKit
import Carbon.HIToolbox

/// Collects IMK capabilities at activation and input-field boundaries.
///
/// This type owns client IPC only. Pure decisions live in `SecureInputPolicy`,
/// `HostSurfaceResolver`, and `ClientCompatibilityPolicy`.
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

    /// Probes whether explicit replacement ranges are safe for this client.
    /// The call is gated so the shipping marked-text path does no extra hot-path IPC.
    static func probeDocumentAccessSafe(
        _ client: IMKTextInput,
        bundleId: String,
        allowBlinkNativeField: Bool = false
    ) -> Bool {
        guard ConfigurationManager.shared.experimentalDirectInsertion
                || ClientCompatibilityPolicy.prefersDirectInsertionForComposition(
                    bundleId: bundleId
                )
                || allowBlinkNativeField else {
            return false
        }
        return hasUsableSelection(client.selectedRange())
    }

    private static func probeCapabilities(
        client: IMKTextInput,
        bundleId: String,
        validAttributeNames: Set<String>,
        validAttributesAreAdvertised: Bool,
        experimentalDirectInsertion: Bool
    ) -> IMKClientCapabilitySnapshot {
        let isFinder = bundleId == "com.apple.finder"
        let isBlink = ClientCompatibilityPolicy.compositionRenderer(bundleId: bundleId) == .blink
        let shouldProbeDocumentAccess = isFinder
            || isBlink
            || experimentalDirectInsertion
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
                && rect.origin.x < HangyeolConfig.finderDesktopThreshold
                && rect.origin.y < HangyeolConfig.finderDesktopThreshold
            if isDesktopSentinel {
                caretGeometry = .finderDesktopSentinel
            } else if CursorRectResolver.isValidCursorRect(rect) {
                caretGeometry = .usable
            } else {
                caretGeometry = .unavailable
            }
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

    /// Fast activation snapshot. Detailed field capabilities remain unclassified
    /// until the first input boundary, where client IPC is safe and necessary.
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

    /// Performs the complete field analysis and returns its immutable context.
    public static func analyze(client: IMKTextInput) -> ClientContext {
        analyze(
            client: client,
            experimentalDirectInsertion: ConfigurationManager.shared.experimentalDirectInsertion
        )
    }

    static func analyze(
        client: IMKTextInput,
        experimentalDirectInsertion: Bool
    ) -> ClientContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        var bundleId = client.bundleIdentifier() ?? ""
        if bundleId.isEmpty, let app = frontmostApp {
            bundleId = app.bundleIdentifier ?? ""
        }

        let validAttributes = client.validAttributesForMarkedText() ?? []
        let validAttributeNames = Set(validAttributes.compactMap { attribute -> String? in
            if let key = attribute as? NSAttributedString.Key {
                return key.rawValue
            }
            return attribute as? String
        })
        let capabilities = probeCapabilities(
            client: client,
            bundleId: bundleId,
            validAttributeNames: validAttributeNames,
            validAttributesAreAdvertised: !validAttributes.isEmpty,
            experimentalDirectInsertion: experimentalDirectInsertion
        )
        let hostSurface = HostSurfaceResolver.resolve(
            bundleId: bundleId,
            capabilities: capabilities
        )
        let isLikelyDesktopArea = capabilities.caretGeometry == .finderDesktopSentinel

        logCapabilities(capabilities, surface: hostSurface)

        return ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: !validAttributes.isEmpty,
            isLikelyDesktopArea: isLikelyDesktopArea,
            documentAccessSafe: capabilities.advertisesDocumentAccess
                || capabilities.hasUsableSelection,
            capabilities: capabilities,
            hostSurface: hostSurface
        )
    }
}
