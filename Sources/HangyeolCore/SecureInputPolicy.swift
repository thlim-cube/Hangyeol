import Foundation

/// Inputs for the pure Secure Input decision.
struct SecureInputSignals: Sendable {
    let bundleId: String
    let hasTextInputCapability: Bool
    let hasInvalidSelection: Bool
    let hasGlobalSecureInput: Bool
}

/// Decides whether an event must bypass IMK composition.
///
/// This policy never performs client IPC. Callers gather only the signals that are
/// still required and publish the result after their session lease is revalidated.
struct SecureInputPolicy: Sendable {
    static func isSystemSecureClient(_ bundleId: String) -> Bool {
        bundleId == "com.apple.SecurityAgent"
            || bundleId == "com.apple.loginwindow"
            || bundleId == "com.apple.screencaptureui"
    }

    static func shouldPassThrough(_ signals: SecureInputSignals) -> Bool {
        if isSystemSecureClient(signals.bundleId) {
            return true
        }

        return signals.hasGlobalSecureInput
            || (!signals.hasTextInputCapability && signals.hasInvalidSelection)
    }

    /// `selectedRange()` is client IPC on the keystroke hot path. Its result affects
    /// the fail-closed conjunction only when no cheaper signal decided the outcome.
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
