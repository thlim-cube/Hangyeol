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

/// Maps capability evidence to one host surface. Bundle identity is a fallback,
/// never stronger than the IMK capabilities observed for the current field.
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
