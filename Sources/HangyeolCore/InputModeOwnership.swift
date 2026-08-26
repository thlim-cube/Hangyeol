import Foundation

/// Coarse selected-source state used to distinguish a real input-source boundary
/// from ordinary IMK focus changes. Raw source identifiers are intentionally not
/// retained or logged.
enum SelectedInputSourceKind: Equatable {
    case hangyeol
    case other
    case unavailable
}

enum SelectedInputSourceClassifier {
    private static let hangyeolInputSourceID = ProductIdentity.inputModeID
    private static let hangyeolBundleID = ProductIdentity.bundleID

    static func classify(
        inputSourceID: String?,
        bundleID: String?
    ) -> SelectedInputSourceKind {
        guard let inputSourceID else { return .unavailable }
        if inputSourceID == hangyeolInputSourceID || bundleID == hangyeolBundleID {
            return .hangyeol
        }
        return .other
    }
}

struct InputModeOwnershipSnapshot: Equatable {
    let macOSOwnsSwitching: Bool
    let selectedInputSource: SelectedInputSourceKind
}

enum InputModeOwnershipBoundary: Equatable {
    case macOSOwnershipEnabled
    case hangyeolReselected

    var diagnosticLabel: StaticString {
        switch self {
        case .macOSOwnershipEnabled: "ownership_enabled"
        case .hangyeolReselected: "input_source_reselected"
        }
    }
}

/// Tracks only explicit ownership/source transitions. Repeated activation of the
/// same Hangyeol source is deliberately a no-op so tabs and apps retain the user's
/// process-wide Korean/English choice.
struct InputModeOwnershipTracker {
    private var previousMacOSOwnership: Bool?
    private var lastKnownSelectedInputSource: SelectedInputSourceKind?
    private var ownershipEnablementAwaitsSelectedSource = false
    private(set) var hasPendingKoreanReconciliation = false

    @discardableResult
    mutating func observe(_ snapshot: InputModeOwnershipSnapshot) -> InputModeOwnershipBoundary? {
        let ownershipBecameEnabled = previousMacOSOwnership == false
            && snapshot.macOSOwnsSwitching
        previousMacOSOwnership = snapshot.macOSOwnsSwitching

        guard snapshot.macOSOwnsSwitching else {
            // Once Hangyeol owns switching again, a system-owned reconciliation is
            // no longer valid and must not reset a later custom-mode choice.
            ownershipEnablementAwaitsSelectedSource = false
            hasPendingKoreanReconciliation = false
            if snapshot.selectedInputSource != .unavailable {
                lastKnownSelectedInputSource = snapshot.selectedInputSource
            }
            return nil
        }

        guard snapshot.selectedInputSource != .unavailable else {
            // Do not guess which source is selected. Remember an ownership edge so
            // a later positive Hangyeol observation can resolve it safely.
            ownershipEnablementAwaitsSelectedSource =
                ownershipEnablementAwaitsSelectedSource || ownershipBecameEnabled
            return nil
        }

        let boundary: InputModeOwnershipBoundary?
        if snapshot.selectedInputSource == .hangyeol,
           ownershipBecameEnabled || ownershipEnablementAwaitsSelectedSource {
            boundary = .macOSOwnershipEnabled
        } else if snapshot.selectedInputSource == .hangyeol,
                  lastKnownSelectedInputSource == .other {
            boundary = .hangyeolReselected
        } else {
            boundary = nil
        }

        ownershipEnablementAwaitsSelectedSource = false
        lastKnownSelectedInputSource = snapshot.selectedInputSource
        if boundary != nil {
            hasPendingKoreanReconciliation = true
        }
        return boundary
    }

    mutating func markReconciled() {
        hasPendingKoreanReconciliation = false
    }
}
