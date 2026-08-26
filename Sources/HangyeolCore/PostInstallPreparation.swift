import Foundation

public enum PostInstallPreparation {
    public static let argument = "--post-install-prepare"
    public static let launchProbeArgument = "--verify-launch"
    public static let failureExitCode: Int32 = 10

    private static let pendingSetupKey = "HangyeolPendingPostInstallSetup"
    internal static let selectedBeforeInstallKey = "HangyeolSelectedBeforeInstall"
    internal static let installedBeforeInstallKey = "HangyeolInstalledBeforeInstall"

    public static func shouldPrepare(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(argument)
    }

    public static func shouldRunLaunchProbe(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(launchProbeArgument)
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

    public static func installedBeforeInstall(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: installedBeforeInstallKey)
    }

    public static func clearInstallationSnapshot(
        in defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: selectedBeforeInstallKey)
        defaults.removeObject(forKey: installedBeforeInstallKey)
        defaults.synchronize()
    }
}
