import Foundation

/// Immutable analysis result for one focused IMK text field.
public struct ClientContext: Sendable {
    let capabilities: IMKClientCapabilitySnapshot
    let hostSurface: HostSurface

    public let bundleId: String

    /// Conservative marked-text capability signal used by Secure Input policy.
    public let hasTextInputCapability: Bool

    /// Whether Finder currently exposes its desktop/non-text sentinel target.
    public let isLikelyDesktopArea: Bool

    /// Whether activation intentionally skipped client IPC for latency.
    public let isLightweight: Bool

    /// Whether selection/document access is safe enough for explicit ranges.
    public let documentAccessSafe: Bool

    /// Whether a Blink process currently exposes a native AppKit text field.
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

    public var isFinder: Bool {
        bundleId == "com.apple.finder"
    }

    /// Finder's rename editor can omit marked-text attributes and expose an
    /// invalid selection while still returning a usable field rectangle. Keep
    /// this exception narrower than generic AppKit geometry so password-like
    /// clients retain the normal fail-closed Secure Input probe.
    var isConfirmedFinderTextTarget: Bool {
        isFinder
            && hostSurface == .appKit
            && capabilities.caretGeometry == .usable
    }

    /// Finder's non-text desktop target must not receive marked text.
    public var shouldUseImmediateMode: Bool {
        hostSurface == .finderNonText
    }
}
