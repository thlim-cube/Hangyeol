import Darwin
import Foundation
import HangyeolInstallerSupport

public enum PostInstallCommand: Equatable, Sendable {
    case status
    case launchProbe
    case waitForActivation
    case scheduleRepair(
        installationKind: InstallerInstallationKind,
        shouldSelect: Bool,
        temporaryFallbackSourceID: String?,
        waitForPackageReceipt: Bool = false
    )
    case repairPending
    case phase(InstallerActivationPhase, sourceID: String?)
    case invalid
}

public struct PendingInputSourceActivation: Codable, Equatable, Sendable {
    public let token: String
    public let installationKind: InstallerInstallationKind
    public let shouldSelect: Bool
    // Historical plist key retained for decoding existing pending requests.
    // The source is now kept enabled after activation, not automatically removed.
    public let temporaryFallbackSourceID: String?
    public let version: String
    public let build: String
    public let packageReceiptVersion: String?
    public let previousReceiptDate: Date?

    public init(
        token: String,
        installationKind: InstallerInstallationKind,
        shouldSelect: Bool,
        temporaryFallbackSourceID: String?,
        version: String,
        build: String,
        packageReceiptVersion: String? = nil,
        previousReceiptDate: Date? = nil
    ) {
        self.token = token
        self.installationKind = installationKind
        self.shouldSelect = shouldSelect
        self.temporaryFallbackSourceID = temporaryFallbackSourceID
        self.version = version
        self.build = build
        self.packageReceiptVersion = packageReceiptVersion
        self.previousReceiptDate = previousReceiptDate
    }
}

public enum PostInstallPreparation {
    public static let statusArgument = "--post-install-status"
    public static let launchProbeArgument = "--verify-launch"
    public static let waitForActivationArgument =
        "--wait-for-input-source-activation"
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
        0.5,
        1,
        2,
        2,
        2,
        2,
        2
    ]
    private static let requiredStableActivationPasses = 5
    private static let fallbackRetirementPhaseTimeout: DispatchTimeInterval =
        .seconds(1)
    private static let activationCompletionAttempts = 81
    private static let activationCompletionPollInterval: TimeInterval = 0.25
    private static let activationCompletionTimeoutNanoseconds: UInt64 =
        20_000_000_000

    private struct ActivationPaths {
        let supportDirectory: URL
        let marker: URL
        // Keep long TIS work separate so publishing a newer generation never
        // waits behind verifier retries or process timeouts.
        let repairLock: URL
        let generationLock: URL
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
                waitForActivationArgument,
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
        if present[0] == waitForActivationArgument {
            return arguments.count == 2 ? .waitForActivation : .invalid
        }
        if present[0] == repairPendingArgument {
            return arguments.count == 2 ? .repairPending : .invalid
        }
        if present[0] == scheduleRepairArgument {
            guard (arguments.count == 5 || (arguments.count == 6 && arguments[5] == "--after-package-receipt")),
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
                temporaryFallbackSourceID: fallbackSourceID,
                waitForPackageReceipt: arguments.count == 6
            )
        }
        guard let phase = InstallerActivationPhase(rawValue: present[0]) else {
            return .invalid
        }
        switch phase {
        case .selectFallback, .verifyFallbackSelected,
             .disableTemporaryFallback, .verifyTemporaryFallbackDisabled:
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
        waitForPackageReceipt: Bool = false,
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
                build: build,
                packageReceiptVersion: waitForPackageReceipt ? version : nil,
                previousReceiptDate: waitForPackageReceipt
                    ? (try? FileManager.default.attributesOfItem(atPath:
                        "/var/db/receipts/com.thlim.hangyeol.plist"))?[.modificationDate] as? Date
                    : nil
            )
            let agentData = try activationAgentData(
                executableURL: executableURL,
                logURL: paths.log
            )
            return try withActivationLock(
                at: paths.generationLock,
                operation: F_LOCK
            ) {
                try writeAtomically(agentData, to: paths.agent)
                try writeAtomically(
                    PropertyListEncoder().encode(request),
                    to: paths.marker
                )
                return true
            }
        } catch {
            fputs("installer: failed to schedule activation repair: \(error)\n", stderr)
            return false
        }
    }

    public static func hasPendingActivation(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: activationPaths(homeDirectory: homeDirectory).marker.path
        )
    }

    /// Keeps PackageKit's completion boundary behind the asynchronous IMK/TIS
    /// repair. The repair removes its marker only after a fresh-process status
    /// check, so the marker is the single durable completion boundary.
    public static func waitForActivationCompletion(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = startedAt.addingReportingOverflow(
            activationCompletionTimeoutNanoseconds
        )
        return waitForActivationCompletion(
            attempts: activationCompletionAttempts,
            isPending: {
                hasPendingActivation(homeDirectory: homeDirectory)
            },
            hasTimeRemaining: {
                overflow || DispatchTime.now().uptimeNanoseconds < deadline
            },
            waitBeforeRetry: {
                waitForActivationRetry(activationCompletionPollInterval)
            }
        )
    }

    internal static func waitForActivationCompletion(
        attempts: Int,
        isPending: () -> Bool,
        hasTimeRemaining: () -> Bool,
        waitBeforeRetry: () -> Void
    ) -> Bool {
        guard attempts > 0 else { return false }
        for attempt in 0..<attempts {
            if !isPending(), !isPending() {
                print(
                    "installer: activation completion observed "
                        + "attempt=\(attempt + 1)"
                )
                return true
            }
            guard attempt + 1 < attempts, hasTimeRemaining() else { break }
            waitBeforeRetry()
        }
        fputs("installer: activation completion timed out\n", stderr)
        return false
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
            return try withActivationLock(
                at: paths.repairLock,
                operation: F_LOCK
            ) {
                let request = try withActivationLock(
                    at: paths.generationLock,
                    operation: F_LOCK
                ) { () -> PendingInputSourceActivation? in
                    guard FileManager.default.fileExists(
                        atPath: paths.marker.path
                    ) else {
                        _ = removeFileIfPresent(paths.agent)
                        return nil
                    }
                    let requestData = try Data(contentsOf: paths.marker)
                    let pending = try PropertyListDecoder().decode(
                        PendingInputSourceActivation.self,
                        from: requestData
                    )
                    guard pending.version == version,
                          pending.build == build else {
                        throw PreparationError.invalidRequest
                    }
                    return pending
                }
                guard let request else { return true }

                // PackageKit can touch and register the bundle after postinstall
                // returns. Do not retire the repair marker based on the earlier TIS
                // snapshot while the old package receipt is still on disk.
                if let receiptVersion = request.packageReceiptVersion {
                    guard waitForPackageReceipt(expectedVersion: receiptVersion,
                                              previousReceiptDate: request.previousReceiptDate) else {
                        print("installer: package receipt is not ready; activation remains pending")
                        return false
                    }
                }

                let boundaries = InputSourceLifecycleRules.activationBoundaries(
                    shouldSelect: request.shouldSelect
                )
                // A still-selected mode may have a stale menu connection after bundle
                // replacement. Force a real fallback -> Hangyeol transition after
                // the new receipt/runtime is ready, even on ordinary updates.
                guard prepareFallbackHandoff(
                    shouldSelect: request.shouldSelect,
                    fallbackSourceID: request.temporaryFallbackSourceID,
                    runPhase: {
                        runInstallerPhaseProcess(
                            $0,
                            temporaryFallbackSourceID: request.temporaryFallbackSourceID,
                            executableURL: executableURL
                        )
                    }
                ) else { return false }
                let activated = convergeStableActivation(
                    boundaries: boundaries,
                    attempts: activationRetryDelays.count,
                    requiredStablePasses: requiredStableActivationPasses,
                    verifyBeforeWriting:
                        request.installationKind == .ordinaryUpdate,
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
                        waitForActivationRetry(delay)
                    }
                )
                guard activated else { return false }

                return try retireActivationAfterFreshReadiness(
                    verifyFreshReadiness: {
                        runStatusProbeProcess(executableURL: executableURL)
                    },
                    retireActivation: {
                        try withActivationLock(
                            at: paths.generationLock,
                            operation: F_LOCK
                        ) {
                            let currentData = try Data(contentsOf: paths.marker)
                            let currentRequest = try PropertyListDecoder().decode(
                                PendingInputSourceActivation.self,
                                from: currentData
                            )
                            guard currentRequest.token == request.token else {
                                print(
                                    "installer: a newer activation request replaced this generation"
                                )
                                return false
                            }
                            // Keep the working fallback. Removing its HIToolbox entry
                            // directly can diverge from TIS and empty the system menu.
                            // The user can manage input sources in System Settings.

                            let retired = retireActivationRequest(
                                removeMarker: {
                                    removeFileIfPresent(paths.marker)
                                },
                                removeAgent: {
                                    removeFileIfPresent(paths.agent)
                                },
                                clearSnapshot: {
                                    clearInstallationSnapshot(in: defaults)
                                }
                            )
                            guard retired else { return false }
                            print(
                                "installer: activation repaired "
                                    + "kind=\(request.installationKind.rawValue) "
                                    + "selected=\(request.shouldSelect)"
                            )
                            return true
                        }
                    }
                )
            }
        } catch {
            fputs("installer: pending activation repair failed: \(error)\n", stderr)
            return false
        }
    }

    internal static func waitForActivationRetry(_ delay: TimeInterval) {
        guard delay > 0 else { return }
        // A GCD worker has no run-loop sources; RunLoop.run can return immediately.
        // This runs off the IMK main thread and must enforce a real elapsed interval.
        Thread.sleep(forTimeInterval: delay)
    }

    internal static func prepareFallbackHandoff(
        shouldSelect: Bool,
        fallbackSourceID: String?,
        runPhase: (InstallerActivationPhase) -> Int32
    ) -> Bool {
        guard shouldSelect, fallbackSourceID != nil else { return true }
        guard runPhase(.selectFallback) == InstallerPhaseExit.success else { return false }
        return runPhase(.verifyFallbackSelected) == InstallerPhaseExit.success
    }

    /// A fresh-process failure must leave both the temporary fallback and the
    /// durable retry request untouched. Only readiness success may enter the
    /// generation-checked retirement transaction.
    internal static func retireActivationAfterFreshReadiness(
        verifyFreshReadiness: () -> Bool,
        retireActivation: () throws -> Bool
    ) rethrows -> Bool {
        guard verifyFreshReadiness() else { return false }
        return try retireActivation()
    }

    internal static func retireActivationRequest(
        removeMarker: () -> Bool,
        removeAgent: () -> Bool,
        clearSnapshot: () -> Void
    ) -> Bool {
        guard removeMarker() else { return false }
        clearSnapshot()
        if !removeAgent() {
            fputs(
                "installer: activation marker retired; stale repair agent will self-clean\n",
                stderr
            )
        }
        return true
    }

    internal static func retireTemporaryFallback(
        boundary: InstallerActivationBoundary,
        runPhase: (InstallerActivationPhase) -> Int32
    ) -> Bool {
        let actionStatus = runPhase(boundary.action)
        let verifyStatus = runPhase(boundary.verify)
        print(
            "installer: fallback retirement action=\(actionStatus) "
                + "verify=\(verifyStatus)"
        )
        return verifyStatus == InstallerPhaseExit.success
    }

    /// A single fresh verifier can observe caller-local TIS state before the
    /// login session has settled. Require consecutive, independent passes and
    /// repair any regression before retiring the temporary fallback.
    internal static func convergeStableActivation(
        boundaries: [InstallerActivationBoundary],
        attempts: Int,
        requiredStablePasses: Int,
        verifyBeforeWriting: Bool,
        runPhase: (InstallerActivationPhase) -> Int32,
        waitBeforeRetry: (Int) -> Void
    ) -> Bool {
        guard !boundaries.isEmpty,
              attempts > 0,
              requiredStablePasses > 0,
              requiredStablePasses <= attempts else {
            return false
        }
        var stablePasses = 0
        var needsConvergence = true

        for attempt in 0..<attempts {
            let converged: Bool
            if needsConvergence {
                converged = convergeActivation(
                    boundaries: boundaries,
                    attempts: 1,
                    verifyBeforeWriting: verifyBeforeWriting || attempt > 0,
                    runPhase: runPhase,
                    waitBeforeRetry: { _ in }
                )
            } else {
                converged = true
            }
            let verified = converged && verifyActivation(
                boundaries: boundaries,
                runPhase: runPhase
            )
            stablePasses = verified ? stablePasses + 1 : 0
            needsConvergence = !verified
            print(
                "installer: stable activation pass=\(stablePasses) "
                    + "attempt=\(attempt + 1)"
            )
            if stablePasses == requiredStablePasses {
                return true
            }
            if attempt + 1 < attempts {
                waitBeforeRetry(attempt + 1)
            }
        }
        return false
    }

    private static func verifyActivation(
        boundaries: [InstallerActivationBoundary],
        runPhase: (InstallerActivationPhase) -> Int32
    ) -> Bool {
        for boundary in boundaries {
            let status = runPhase(boundary.verify)
            print(
                "installer: stable verify=\(boundary.verify.rawValue) "
                    + "status=\(status)"
            )
            guard status == InstallerPhaseExit.success else { return false }
        }
        return true
    }

    internal static func convergeActivation(
        boundaries: [InstallerActivationBoundary],
        attempts: Int,
        verifyBeforeWriting: Bool,
        runPhase: (InstallerActivationPhase) -> Int32,
        waitBeforeRetry: (Int) -> Void
    ) -> Bool {
        guard attempts > 0 else { return false }
        for boundary in boundaries {
            if verifyBeforeWriting {
                let initialVerificationStatus = runPhase(boundary.verify)
                print(
                    "installer: boundary=\(boundary.verify.rawValue) "
                        + "preflight=\(initialVerificationStatus)"
                )
                if initialVerificationStatus == InstallerPhaseExit.success {
                    continue
                }
            }

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

    internal static func waitForPackageReceipt(
        expectedVersion: String,
        previousReceiptDate: Date? = nil,
        attempts: Int = 80,
        readVersion: () -> String? = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath:
                "/var/db/receipts/com.thlim.hangyeol.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  plist["PackageIdentifier"] as? String == "com.thlim.hangyeol" else { return nil }
            return plist["PackageVersion"] as? String
        },
        readModificationDate: () -> Date? = {
            (try? FileManager.default.attributesOfItem(atPath:
                "/var/db/receipts/com.thlim.hangyeol.plist"))?[.modificationDate] as? Date
        },
        wait: () -> Void = { Thread.sleep(forTimeInterval: 0.25) }
    ) -> Bool {
        for _ in 0..<max(0, attempts) {
            if readVersion() == expectedVersion {
                if let previousReceiptDate {
                    if let currentDate = readModificationDate(), currentDate != previousReceiptDate {
                        return true
                    }
                } else { return true }
            }
            wait()
        }
        return false
    }

    private static func runInstallerPhaseProcess(
        _ phase: InstallerActivationPhase,
        temporaryFallbackSourceID: String?,
        executableURL: URL,
        timeout timeoutOverride: DispatchTimeInterval? = nil
    ) -> Int32 {
        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        switch phase {
        case .selectFallback, .verifyFallbackSelected,
             .disableTemporaryFallback, .verifyTemporaryFallbackDisabled:
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
        if let timeoutOverride {
            timeout = timeoutOverride
        } else {
            switch phase {
            case .enableParent, .enableMode:
                timeout = .seconds(120)
            default:
                timeout = .seconds(10)
            }
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

    private static func runStatusProbeProcess(
        executableURL: URL
    ) -> Bool {
        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = [statusArgument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if completion.wait(timeout: .now() + .seconds(3)) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if completion.wait(timeout: .now() + .milliseconds(500)) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .seconds(1))
            }
            return false
        }
        return process.terminationReason == .exit
            && process.terminationStatus == EXIT_SUCCESS
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
            repairLock: supportDirectory
                .appendingPathComponent("input-source-activation-repair.lock"),
            generationLock: supportDirectory.appendingPathComponent(
                "input-source-activation-generation.lock"
            ),
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

    private static func withActivationLock<T>(
        at url: URL,
        operation: Int32,
        body: () throws -> T
    ) throws -> T {
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw PreparationError.lockUnavailable
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, operation, 0) == 0 else {
            throw PreparationError.lockUnavailable
        }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private static func removeFileIfPresent(_ url: URL) -> Bool {
        if Darwin.unlink(url.path) == 0 {
            return true
        }
        return errno == ENOENT
    }
}
