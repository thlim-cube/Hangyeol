import Foundation

/// The host text system that owns the focused input target.
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

/// Capability evidence collected once at a field-analysis boundary.
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

/// Resolve the renderer before distinguishing its web and native fields.
/// AppKit and WebKit also advertise replacement ranges; that attribute alone
/// cannot establish that a client uses Blink.
enum HostSurfaceResolver {
    static func resolve(
        bundleId: String,
        capabilities: IMKClientCapabilitySnapshot
    ) -> HostSurface {
        // These native/WebKit hosts advertise the same replacement attribute.
        // Preserve capability fallback for unidentified hosts, including Electron
        // wrappers, without overriding a positively known system renderer.
        let knownSystemRenderer = [
            "com.apple.TextEdit", "com.apple.finder",
            "com.apple.Safari", "com.apple.SafariTechnologyPreview"
        ].contains(bundleId)
        if capabilities.advertisesBlinkReplacementRange && !knownSystemRenderer {
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
