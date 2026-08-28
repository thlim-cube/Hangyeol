import Darwin
import Foundation
import HangyeolInstallerSupport

public enum PostInstallCommand: Equatable, Sendable {
    case status
    case launchProbe
    case scheduleRepair(
        installationKind: InstallerInstallationKind,
        shouldSelect: Bool,
        temporaryFallbackSourceID: String?
    )
    case repairPending
    case phase(InstallerActivationPhase, sourceID: String?)
    case invalid
}

public struct PendingInputSourceActivation: Codable, Equatable, Sendable {
    public let token: String
    public let installationKind: InstallerInstallationKind
    public let shouldSelect: Bool
    public let temporaryFallbackSourceID: String?
    public let version: String
    public let build: String

    public init(
        token: String,
        installationKind: InstallerInstallationKind,
        shouldSelect: Bool,
        temporaryFallbackSourceID: String?,
        version: String,
        build: String
    ) {
        self.token = token
        self.installationKind = installationKind
        self.shouldSelect = shouldSelect
        self.temporaryFallbackSourceID = temporaryFallbackSourceID
        self.version = version
        self.build = build
    }
}

public enum PostInstallPreparation {
    public static let statusArgument = "--post-install-status"
    public static let launchProbeArgument = "--verify-launch"
    public static let scheduleRepairArgument = "--schedule-input-source-repair"
    public static let repairPendingArgument = "--repair-pending-input-source"
    public static let activationAgentLabel =
        "com.thlim.hangyeol.activation-repair"
    public static let failureExitCode: Int32 = 10

    private static let pendingSetupKey = "HangyeolPendingPostInstallSetup"
    internal static let selectedBeforeInstallKey = "HangyeolSelectedBeforeInstall"
    internal static let installedBeforeInstallKey = "HangyeolInstalledBeforeInstall"
    internal static let installedBundleIdentifierKey = "HangyeolInstalledBundleIdentifier"
    internal static let installedConnectionNameKey = "HangyeolInstalledConnectionName"
    internal static let installedInputModeSchemaKey = "HangyeolInstalledInputModeSchema"
    internal static let fallbackInputSourceIDKey = "HangyeolFallbackInputSourceID"
    internal static let fallbackWasEnabledKey = "HangyeolFallbackWasEnabled"

    private static let activationRetryDelays: [TimeInterval] = [
        0,
        0.2,
        0.5,
        1,
        2
    ]

    private struct ActivationPaths {
        let supportDirectory: URL
        let marker: URL
        let lock: URL
        let agent: URL
        let logDirectory: URL
        let log: URL
    }

    private enum PreparationError: Error {
        case invalidDirectory(URL)
        case missingExecutable
        case invalidRequest
        case lockUnavailable
    }

    public static func command(arguments: [String]) -> PostInstallCommand? {
        let privateArguments = Set(
            [
                statusArgument,
                launchProbeArgument,
                scheduleRepairArgument,
                repairPendingArgument
            ] + InstallerActivationPhase.allCases.map(\.rawValue)
        )
        let present = arguments.dropFirst().filter(privateArguments.contains)
        guard !present.isEmpty else { return nil }
        guard present.count == 1 else { return .invalid }

        if present[0] == statusArgument {
            return arguments.count == 2 ? .status : .invalid
        }
        if present[0] == launchProbeArgument {
            return arguments.count == 2 ? .launchProbe : .invalid
        }
        if present[0] == repairPendingArgument {
            return arguments.count == 2 ? .repairPending : .invalid
        }
        if present[0] == scheduleRepairArgument {
            guard arguments.count == 5,
                  let kind = InstallerInstallationKind(rawValue: arguments[2]),
                  let shouldSelect = parseBoolean(arguments[3]) else {
                return .invalid
            }
            let fallbackSourceID = arguments[4] == "-" ? nil : arguments[4]
            guard fallbackSourceID?.isEmpty != true,
                  shouldSelect || fallbackSourceID == nil else {
                return .invalid
            }
            return .scheduleRepair(
                installationKind: kind,
                shouldSelect: shouldSelect,
                temporaryFallbackSourceID: fallbackSourceID
            )
        }
        guard let phase = InstallerActivationPhase(rawValue: present[0]) else {
            return .invalid
        }
        switch phase {
        case .disableTemporaryFallback, .verifyTemporaryFallbackDisabled:
            guard arguments.count == 3, !arguments[2].isEmpty else {
                return .invalid
            }
            return .phase(phase, sourceID: arguments[2])
        default:
            return arguments.count == 2
                ? .phase(phase, sourceID: nil)
                : .invalid
        }
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
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

    public static func hasInstalledBeforeInstallSnapshot(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: installedBeforeInstallKey) != nil
    }

    public static func clearInstallationSnapshot(
        in defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: selectedBeforeInstallKey)
        defaults.removeObject(forKey: installedBeforeInstallKey)
        defaults.removeObject(forKey: installedBundleIdentifierKey)
        defaults.removeObject(forKey: installedConnectionNameKey)
        defaults.removeObject(forKey: installedInputModeSchemaKey)
        defaults.removeObject(forKey: fallbackInputSourceIDKey)
        defaults.removeObject(forKey: fallbackWasEnabledKey)
        defaults.synchronize()
    }

    public static func scheduleActivationRepair(
        installationKind: InstallerInstallationKind,
        shouldSelect: Bool,
        temporaryFallbackSourceID: String? = nil,
        executableURL: URL,
        version: String,
        build: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard shouldSelect || temporaryFallbackSourceID == nil else {
            return false
        }
        do {
            let paths = activationPaths(homeDirectory: homeDirectory)
            try ensureDirectory(paths.supportDirectory)
            try ensureDirectory(paths.logDirectory)
            try ensureDirectory(paths.agent.deletingLastPathComponent())

            let request = PendingInputSourceActivation(
                token: UUID().uuidString,
                installationKind: installationKind,
                shouldSelect: shouldSelect,
                temporaryFallbackSourceID: temporaryFallbackSourceID,
                version: version,
                build: build
            )
            let agentData = try activationAgentData(
                executableURL: executableURL,
                logURL: paths.log
            )
            try writeAtomically(agentData, to: paths.agent)
            try writeAtomically(
                PropertyListEncoder().encode(request),
                to: paths.marker
            )
            return true
        } catch {
            fputs("installer: failed to schedule activation repair: \(error)\n", stderr)
            return false
        }
    }

    public static func repairPendingActivation(
        executableURL: URL,
        version: String,
        build: String,
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let paths = activationPaths(homeDirectory: homeDirectory)
        do {
            try ensureDirectory(paths.supportDirectory)
            let lockDescriptor = Darwin.open(
                paths.lock.path,
                O_CREAT | O_RDWR,
                S_IRUSR | S_IWUSR
            )
            guard lockDescriptor >= 0 else {
                throw PreparationError.lockUnavailable
            }
            defer { Darwin.close(lockDescriptor) }
            guard Darwin.lockf(lockDescriptor, F_TLOCK, 0) == 0 else {
                throw PreparationError.lockUnavailable
            }
            defer { Darwin.lockf(lockDescriptor, F_ULOCK, 0) }

            guard FileManager.default.fileExists(atPath: paths.marker.path) else {
                _ = removeFileIfPresent(paths.agent)
                return true
            }
            let requestData = try Data(contentsOf: paths.marker)
            let request = try PropertyListDecoder().decode(
                PendingInputSourceActivation.self,
                from: requestData
            )
            guard request.version == version, request.build == build else {
                throw PreparationError.invalidRequest
            }

            let boundaries = InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: request.shouldSelect,
                hasTemporaryFallback:
                    request.temporaryFallbackSourceID != nil
            )
            let activated = convergeActivation(
                boundaries: boundaries,
                attempts: activationRetryDelays.count,
                runPhase: {
                    runInstallerPhaseProcess(
                        $0,
                        temporaryFallbackSourceID:
                            request.temporaryFallbackSourceID,
                        executableURL: executableURL
                    )
                },
                waitBeforeRetry: { attempt in
                    let delay = activationRetryDelays[attempt]
                    if delay > 0 {
                        RunLoop.current.run(
                            until: Date().addingTimeInterval(delay)
                        )
                    }
                }
            )
            guard activated else { return false }

            let currentData = try Data(contentsOf: paths.marker)
            let currentRequest = try PropertyListDecoder().decode(
                PendingInputSourceActivation.self,
                from: currentData
            )
            guard currentRequest.token == request.token else {
                print("installer: a newer activation request replaced this generation")
                return false
            }

            guard removeFileIfPresent(paths.marker) else { return false }
            clearInstallationSnapshot(in: defaults)
            guard removeFileIfPresent(paths.agent) else { return false }
            print(
                "installer: activation repaired kind=\(request.installationKind.rawValue) "
                    + "selected=\(request.shouldSelect)"
            )
            return true
        } catch {
            fputs("installer: pending activation repair failed: \(error)\n", stderr)
            return false
        }
    }

    internal static func convergeActivation(
        boundaries: [InstallerActivationBoundary],
        attempts: Int,
        runPhase: (InstallerActivationPhase) -> Int32,
        waitBeforeRetry: (Int) -> Void
    ) -> Bool {
        guard attempts > 0 else { return false }
        for boundary in boundaries {
            var verified = false
            for attempt in 0..<attempts {
                let actionStatus = runPhase(boundary.action)
                let verifyStatus = runPhase(boundary.verify)
                print(
                    "installer: boundary=\(boundary.verify.rawValue) "
                        + "attempt=\(attempt + 1) action=\(actionStatus) "
                        + "verify=\(verifyStatus)"
                )
                if verifyStatus == InstallerPhaseExit.success {
                    verified = true
                    break
                }
                if attempt + 1 < attempts {
                    waitBeforeRetry(attempt + 1)
                }
            }
            guard verified else { return false }
        }
        return true
    }

    private static func runInstallerPhaseProcess(
        _ phase: InstallerActivationPhase,
        temporaryFallbackSourceID: String?,
        executableURL: URL
    ) -> Int32 {
        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        switch phase {
        case .disableTemporaryFallback, .verifyTemporaryFallbackDisabled:
            guard let temporaryFallbackSourceID else {
                return InstallerPhaseExit.failed
            }
            process.arguments = [phase.rawValue, temporaryFallbackSourceID]
        default:
            process.arguments = [phase.rawValue]
        }
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            return InstallerPhaseExit.failed
        }

        let timeout: DispatchTimeInterval
        switch phase {
        case .enableParent, .enableMode:
            timeout = .seconds(120)
        default:
            timeout = .seconds(10)
        }
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if completion.wait(timeout: .now() + .milliseconds(500)) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .seconds(1))
            }
            return InstallerPhaseExit.retryable
        }
        guard process.terminationReason == .exit else {
            return InstallerPhaseExit.failed
        }
        return process.terminationStatus
    }

    private static func activationPaths(
        homeDirectory: URL
    ) -> ActivationPaths {
        let supportDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/Hangyeol")
        let logDirectory = homeDirectory
            .appendingPathComponent("Library/Logs/Hangyeol")
        return ActivationPaths(
            supportDirectory: supportDirectory,
            marker: supportDirectory
                .appendingPathComponent("input-source-activation-pending.plist"),
            lock: supportDirectory
                .appendingPathComponent("input-source-activation-repair.lock"),
            agent: homeDirectory
                .appendingPathComponent("Library/LaunchAgents")
                .appendingPathComponent(activationAgentLabel + ".plist"),
            logDirectory: logDirectory,
            log: logDirectory.appendingPathComponent("installation.log")
        )
    }

    private static func activationAgentData(
        executableURL: URL,
        logURL: URL
    ) throws -> Data {
        guard executableURL.path.hasPrefix("/Library/Input Methods/"),
              executableURL.lastPathComponent == ProductIdentity.systemName else {
            throw PreparationError.missingExecutable
        }
        let propertyList: [String: Any] = [
            "Label": activationAgentLabel,
            "ProgramArguments": [executableURL.path, repairPendingArgument],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }

    private static func ensureDirectory(_ url: URL) throws {
        var metadata = stat()
        if url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw PreparationError.invalidDirectory(url)
            }
            return
        }
        guard errno == ENOENT else {
            throw PreparationError.invalidDirectory(url)
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw PreparationError.invalidDirectory(url)
        }
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        guard Darwin.chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw PreparationError.invalidRequest
        }
    }

    private static func removeFileIfPresent(_ url: URL) -> Bool {
        if Darwin.unlink(url.path) == 0 {
            return true
        }
        return errno == ENOENT
    }
}
