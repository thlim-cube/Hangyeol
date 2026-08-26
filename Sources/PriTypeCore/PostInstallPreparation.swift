import Foundation

public enum PostInstallPreparation {
    public static let argument = "--post-install-prepare"
    public static let failureExitCode: Int32 = 10

    private static let pendingSetupKey = "PriTypePendingPostInstallSetup"
    internal static let selectedBeforeInstallKey = "PriTypeSelectedBeforeInstall"

    public static func shouldPrepare(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(argument)
    }

    public static func markPending(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingSetupKey)
        defaults.synchronize()
    }

    public static func consumePending(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: pendingSetupKey) else {
            return false
        }
        defaults.removeObject(forKey: pendingSetupKey)
        defaults.synchronize()
        return true
    }

    public static func selectedBeforeInstall(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: selectedBeforeInstallKey)
    }

    public static func clearSelectedBeforeInstall(
        in defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: selectedBeforeInstallKey)
        defaults.synchronize()
    }
}
