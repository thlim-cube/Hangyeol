import Foundation

public enum PostInstallPreparation {
    public static let argument = "--post-install-prepare"
    public static let notificationArgument = "--post-install-notify"
    public static let statusArgument = "--post-install-status"
    public static let launchProbeArgument = "--verify-launch"
    public static let failureExitCode: Int32 = 10

    private static let authoritativeProbeAttempts = 120
    private static let authoritativeProbeInterval: TimeInterval = 0.5
    private static let requiredConsecutiveProbeSuccesses = 2

    private static let pendingSetupKey = "HangyeolPendingPostInstallSetup"
    internal static let selectedBeforeInstallKey = "HangyeolSelectedBeforeInstall"
    internal static let installedBeforeInstallKey = "HangyeolInstalledBeforeInstall"

    public static func shouldPrepare(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(argument)
    }

    public static func shouldMarkPending(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(notificationArgument)
    }

    public static func shouldCheckStatus(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(statusArgument)
    }

    public static func shouldRunLaunchProbe(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(launchProbeArgument)
    }

    public static func shouldSelectAfterActivation(
        wasInstalledBeforeUpdate: Bool,
        restorePreviousSelection: Bool
    ) -> Bool {
        !wasInstalledBeforeUpdate || restorePreviousSelection
    }

    /// Waits while the signed installer helper owns the macOS input-source
    /// consent request. The probe must execute in a separate process because
    /// the process that called `TISEnableInputSource` can observe its own
    /// uncommitted TIS cache before the user's consent is persisted.
    public static func waitForAuthoritativeStatus(
        probe: () -> Bool
    ) -> Bool {
        settleAuthoritativeStatus(
            attempts: authoritativeProbeAttempts,
            requiredConsecutiveSuccesses: requiredConsecutiveProbeSuccesses,
            probe: probe,
            waitAfterIncompleteProbe: {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(authoritativeProbeInterval)
                )
            }
        )
    }

    internal static func settleAuthoritativeStatus(
        attempts: Int,
        requiredConsecutiveSuccesses: Int = 2,
        probe: () -> Bool,
        waitAfterIncompleteProbe: () -> Void
    ) -> Bool {
        guard attempts > 0, requiredConsecutiveSuccesses > 0 else { return false }
        var consecutiveSuccesses = 0
        for attempt in 0..<attempts {
            if probe() {
                consecutiveSuccesses += 1
                if consecutiveSuccesses == requiredConsecutiveSuccesses {
                    return true
                }
            } else {
                consecutiveSuccesses = 0
            }
            if attempt + 1 < attempts {
                waitAfterIncompleteProbe()
            }
        }
        return false
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
