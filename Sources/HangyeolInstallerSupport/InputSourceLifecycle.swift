import Foundation

public struct InstallerInputSourceIdentity: Equatable, Sendable {
    public let bundleID: String
    public let modeID: String
    public let ownedBundleIDs: Set<String>

    public init(
        bundleID: String,
        modeID: String,
        legacyBundleIDs: Set<String> = []
    ) {
        self.bundleID = bundleID
        self.modeID = modeID
        self.ownedBundleIDs = legacyBundleIDs.union([bundleID])
    }

    public func owns(_ candidate: InstallerInputSourceCandidate) -> Bool {
        if let bundleID = candidate.bundleID,
           ownedBundleIDs.contains(bundleID) {
            return true
        }
        if let modeID = candidate.modeID,
           modeID == self.modeID
                || ownedBundleIDs.contains(where: {
                    modeID == $0 || modeID.hasPrefix($0 + ".")
                }) {
            return true
        }
        return ownedBundleIDs.contains(where: {
            candidate.sourceID == $0
                || candidate.sourceID.hasPrefix($0 + ".")
        })
    }
}

public enum InstallerInputSourceKind: Equatable, Sendable {
    case inputMethodParent
    case inputMode
    case other
}

public struct InstallerInputSourceCandidate: Equatable, Sendable {
    public let sourceID: String
    public let bundleID: String?
    public let modeID: String?
    public let kind: InstallerInputSourceKind
    public let isEnabled: Bool
    public let isEnableCapable: Bool
    public let isSelectCapable: Bool
    public let isASCIICapable: Bool

    public init(
        sourceID: String,
        bundleID: String? = nil,
        modeID: String? = nil,
        kind: InstallerInputSourceKind,
        isEnabled: Bool,
        isEnableCapable: Bool,
        isSelectCapable: Bool,
        isASCIICapable: Bool = false
    ) {
        self.sourceID = sourceID
        self.bundleID = bundleID
        self.modeID = modeID
        self.kind = kind
        self.isEnabled = isEnabled
        self.isEnableCapable = isEnableCapable
        self.isSelectCapable = isSelectCapable
        self.isASCIICapable = isASCIICapable
    }
}

public enum InstallerInputSourceRole: Equatable, Sendable {
    case parent
    case mode
}

public struct InstallerInputSourceRoster: Equatable, Sendable {
    public let parent: InstallerInputSourceCandidate?
    public let mode: InstallerInputSourceCandidate?
    public let parentCount: Int
    public let modeCount: Int

    public var hasUniquePair: Bool {
        parent != nil && mode != nil && parentCount == 1 && modeCount == 1
    }

    public var isEnabled: Bool {
        hasUniquePair && parent?.isEnabled == true && mode?.isEnabled == true
    }
}

public enum InstallerInstallationKind: String, Codable, Sendable {
    case firstInstallation = "first-installation"
    case ordinaryUpdate = "ordinary-update"
    case registrationChange = "registration-change"
}

public enum InstallerActivationPhase: String, CaseIterable, Codable, Sendable {
    case register = "--installer-register"
    case verifyInstalled = "--installer-verify-installed"
    case enableParent = "--installer-enable-parent"
    case verifyParent = "--installer-verify-parent"
    case enableMode = "--installer-enable-mode"
    case verifyMode = "--installer-verify-mode"
    case selectMode = "--installer-select-mode"
    case verifySelected = "--installer-verify-selected"
    case disableTemporaryFallback = "--installer-disable-temporary-fallback"
    case verifyTemporaryFallbackDisabled = "--installer-verify-temporary-fallback-disabled"
}

public enum InstallerPhaseExit {
    public static let success: Int32 = 0
    public static let failed: Int32 = 1
    public static let retryable: Int32 = 75
}

public struct InstallerActivationBoundary: Equatable, Sendable {
    public let action: InstallerActivationPhase
    public let verify: InstallerActivationPhase

    public init(
        action: InstallerActivationPhase,
        verify: InstallerActivationPhase
    ) {
        self.action = action
        self.verify = verify
    }
}

public enum InputSourceLifecycleRules {
    public static func role(
        of candidate: InstallerInputSourceCandidate,
        identity: InstallerInputSourceIdentity
    ) -> InstallerInputSourceRole? {
        if candidate.sourceID == identity.bundleID,
           candidate.kind == .inputMethodParent,
           candidate.isEnableCapable,
           !candidate.isSelectCapable {
            return .parent
        }
        if candidate.modeID == identity.modeID,
           candidate.kind == .inputMode,
           candidate.isEnableCapable,
           candidate.isSelectCapable {
            return .mode
        }
        return nil
    }

    public static func roster(
        from candidates: [InstallerInputSourceCandidate],
        identity: InstallerInputSourceIdentity
    ) -> InstallerInputSourceRoster {
        let parents = candidates.filter {
            role(of: $0, identity: identity) == .parent
        }
        let modes = candidates.filter {
            role(of: $0, identity: identity) == .mode
        }
        return InstallerInputSourceRoster(
            parent: parents.count == 1 ? parents[0] : nil,
            mode: modes.count == 1 ? modes[0] : nil,
            parentCount: parents.count,
            modeCount: modes.count
        )
    }

    public static func safeFallbackCandidates(
        from candidates: [InstallerInputSourceCandidate],
        identity: InstallerInputSourceIdentity
    ) -> [InstallerInputSourceCandidate] {
        var seen = Set<String>()
        let safe = candidates.filter {
            $0.isASCIICapable
                && $0.isSelectCapable
                && ($0.isEnabled || $0.isEnableCapable)
                && !identity.owns($0)
                && seen.insert($0.sourceID).inserted
        }
        return safe.enumerated().sorted {
            if $0.element.isEnabled != $1.element.isEnabled {
                return $0.element.isEnabled
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    public static func shouldSelectAfterActivation(
        installationKind: InstallerInstallationKind,
        selectedBeforeInstall: Bool
    ) -> Bool {
        installationKind == .firstInstallation || selectedBeforeInstall
    }

    public static func activationBoundaries(
        shouldSelect: Bool,
        hasTemporaryFallback: Bool = false
    ) -> [InstallerActivationBoundary] {
        var boundaries = [
            InstallerActivationBoundary(
                action: .register,
                verify: .verifyInstalled
            ),
            InstallerActivationBoundary(
                action: .enableParent,
                verify: .verifyParent
            ),
            InstallerActivationBoundary(
                action: .enableMode,
                verify: .verifyMode
            )
        ]
        if shouldSelect {
            boundaries.append(
                InstallerActivationBoundary(
                    action: .selectMode,
                    verify: .verifySelected
                )
            )
        }
        if shouldSelect && hasTemporaryFallback {
            boundaries.append(
                InstallerActivationBoundary(
                    action: .disableTemporaryFallback,
                    verify: .verifyTemporaryFallbackDisabled
                )
            )
        }
        return boundaries
    }
}
