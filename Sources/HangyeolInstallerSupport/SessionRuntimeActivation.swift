/// The installed bundle remains untouched while a signed session copy takes over.
public protocol SessionRuntimeHost {
    func validateCandidate() -> Bool
    func prepareInputSource() -> Bool
    func stopCurrentRuntime() -> Bool
    func launchCandidate() -> Bool
    func verifyCandidate() -> Bool
    func restoreInputSource() -> Bool
    func restoreInstalledRuntime() -> Bool
}

public enum SessionRuntimeActivationResult: Equatable {
    case deferred
    case applied
    case restored
    case recoveryFailed
}

public enum SessionRuntimeActivation {
    public static func compatibleConnectionName(installed: String?, proposed: String?, bundleID: String?) -> Bool {
        guard let installed, let proposed else { return false }
        if installed == proposed { return true }
        return bundleID == "com.thlim.inputmethod.Hangyeol"
            && installed == "Hangyeol_InputString"
            && proposed == "com.thlim.inputmethod.Hangyeol_Connection"
    }

    public static func shouldRestoreSelection(
        selectedBefore: Bool, currentSourceID: String?, fallbackID: String?
    ) -> Bool {
        selectedBefore && fallbackID != nil && currentSourceID == fallbackID
    }

    public static func apply(using host: any SessionRuntimeHost) -> SessionRuntimeActivationResult {
        guard host.validateCandidate() else { return .deferred }
        guard host.prepareInputSource(),
              host.stopCurrentRuntime(),
              host.launchCandidate(),
              host.verifyCandidate(),
              host.restoreInputSource(),
              host.verifyCandidate() else {
            return host.restoreInstalledRuntime() ? .restored : .recoveryFailed
        }
        return .applied
    }
}
