import Foundation
import Testing
@testable import HangyeolCore
@testable import HangyeolInstallerSupport

@Suite("Post-install Preparation")
struct PostInstallPreparationTests {
    @Test("Parses one exact private installer command and rejects mixed commands")
    func parsesPrivateInstallerCommands() {
        #expect(PostInstallPreparation.command(
            arguments: ["Hangyeol", "--post-install-status"]
        ) == .status)
        #expect(PostInstallPreparation.command(
            arguments: ["Hangyeol", "--verify-launch"]
        ) == .launchProbe)
        #expect(PostInstallPreparation.command(
            arguments: ["Hangyeol", "--wait-for-input-source-activation"]
        ) == .waitForActivation)
        #expect(PostInstallPreparation.command(arguments: [
            "Hangyeol",
            "--schedule-input-source-repair",
            "ordinary-update",
            "true",
            "-"
        ]) == .scheduleRepair(
            installationKind: .ordinaryUpdate,
            shouldSelect: true,
            temporaryFallbackSourceID: nil
        ))
        #expect(PostInstallPreparation.command(arguments: [
            "Hangyeol",
            "--installer-register"
        ]) == .phase(.register, sourceID: nil))
        #expect(PostInstallPreparation.command(arguments: [
            "Hangyeol",
            "--installer-disable-temporary-fallback",
            "com.apple.keylayout.ABC"
        ]) == .phase(
            .disableTemporaryFallback,
            sourceID: "com.apple.keylayout.ABC"
        ))
        #expect(PostInstallPreparation.command(arguments: [
            "Hangyeol",
            "--schedule-input-source-repair",
            "ordinary-update",
            "false",
            "com.apple.keylayout.ABC"
        ]) == .invalid)
        #expect(PostInstallPreparation.command(arguments: [
            "Hangyeol",
            "--installer-register",
            "--installer-verify-installed"
        ]) == .invalid)
        #expect(PostInstallPreparation.command(
            arguments: ["Hangyeol", "--unrelated"]
        ) == nil)
    }

    @Test("Pending setup is consumed exactly once")
    func consumesPendingSetupOnce() throws {
        let suiteName = "PostInstallPreparationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PostInstallPreparation.markPending(in: defaults)

        #expect(PostInstallPreparation.consumePending(in: defaults))
        #expect(!PostInstallPreparation.consumePending(in: defaults))
    }

    @Test("Installer completion waits for two stable marker observations")
    func waitsForStableMarkerRetirement() {
        let pendingObservations = [true, false, false]
        var pendingIndex = 0
        var waits = 0

        let completed = PostInstallPreparation.waitForActivationCompletion(
            attempts: 2,
            isPending: {
                defer { pendingIndex += 1 }
                return pendingObservations[pendingIndex]
            },
            hasTimeRemaining: { true },
            waitBeforeRetry: { waits += 1 }
        )

        #expect(completed)
        #expect(pendingIndex == pendingObservations.count)
        #expect(waits == 1)
    }

    @Test("Installer completion obeys one global deadline and preserves the marker")
    func activationCompletionDeadlinePreservesPendingRepair() {
        var deadlineChecks = 0
        var waits = 0

        let completed = PostInstallPreparation.waitForActivationCompletion(
            attempts: 100,
            isPending: { true },
            hasTimeRemaining: {
                deadlineChecks += 1
                return deadlineChecks == 1
            },
            waitBeforeRetry: { waits += 1 }
        )

        #expect(!completed)
        #expect(deadlineChecks == 2)
        #expect(waits == 1)
    }

    @Test("A newer repair generation prevents an older completion observation")
    func newerPendingGenerationCancelsObservedCompletion() {
        let pendingObservations = [false, true, false, false]
        var pendingIndex = 0
        var waits = 0

        let completed = PostInstallPreparation.waitForActivationCompletion(
            attempts: 2,
            isPending: {
                defer { pendingIndex += 1 }
                return pendingObservations[pendingIndex]
            },
            hasTimeRemaining: { true },
            waitBeforeRetry: { waits += 1 }
        )

        #expect(completed)
        #expect(pendingIndex == pendingObservations.count)
        #expect(waits == 1)
    }

    @Test("Fresh readiness failure preserves the temporary fallback and marker")
    func freshReadinessFailureSkipsRetirementTransaction() {
        var actions: [String] = []

        let retired = PostInstallPreparation
            .retireActivationAfterFreshReadiness(
                verifyFreshReadiness: {
                    actions.append("fresh-readiness")
                    return false
                },
                retireActivation: {
                    actions.append("fallback-and-marker")
                    return true
                }
            )

        #expect(!retired)
        #expect(actions == ["fresh-readiness"])
    }

    @Test("Keeps the preinstall migration snapshot until preparation succeeds")
    func keepsInstallationSnapshotUntilCleared() throws {
        let suiteName = "PostInstallPreparationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!PostInstallPreparation.hasInstalledBeforeInstallSnapshot(
            in: defaults
        ))
        defaults.set(true, forKey: PostInstallPreparation.selectedBeforeInstallKey)
        defaults.set(false, forKey: PostInstallPreparation.installedBeforeInstallKey)
        defaults.set("bundle", forKey: PostInstallPreparation.installedBundleIdentifierKey)
        defaults.set("connection", forKey: PostInstallPreparation.installedConnectionNameKey)
        defaults.set("{}", forKey: PostInstallPreparation.installedInputModeSchemaKey)
        defaults.set(
            "com.apple.keylayout.ABC",
            forKey: PostInstallPreparation.fallbackInputSourceIDKey
        )
        defaults.set(
            false,
            forKey: PostInstallPreparation.fallbackWasEnabledKey
        )

        #expect(PostInstallPreparation.selectedBeforeInstall(in: defaults))
        #expect(!PostInstallPreparation.installedBeforeInstall(in: defaults))
        #expect(PostInstallPreparation.hasInstalledBeforeInstallSnapshot(in: defaults))

        PostInstallPreparation.clearInstallationSnapshot(in: defaults)
        #expect(!PostInstallPreparation.selectedBeforeInstall(in: defaults))
        #expect(!PostInstallPreparation.installedBeforeInstall(in: defaults))
        #expect(!PostInstallPreparation.hasInstalledBeforeInstallSnapshot(
            in: defaults
        ))
        #expect(defaults.object(
            forKey: PostInstallPreparation.installedBundleIdentifierKey
        ) == nil)
        #expect(defaults.object(
            forKey: PostInstallPreparation.installedConnectionNameKey
        ) == nil)
        #expect(defaults.object(
            forKey: PostInstallPreparation.installedInputModeSchemaKey
        ) == nil)
        #expect(defaults.object(
            forKey: PostInstallPreparation.fallbackInputSourceIDKey
        ) == nil)
        #expect(defaults.object(
            forKey: PostInstallPreparation.fallbackWasEnabledKey
        ) == nil)
    }

    @Test("Every boundary verifies before writing and verifies again after repair")
    func verifiesBeforeEveryActivationWrite() {
        let boundaries = InputSourceLifecycleRules.activationBoundaries(
            shouldSelect: false
        )
        var phases: [InstallerActivationPhase] = []
        var installedVerifierCount = 0
        var waitAttempts: [Int] = []

        let ready = PostInstallPreparation.convergeActivation(
            boundaries: boundaries,
            attempts: 3,
            verifyBeforeWriting: true,
            runPhase: { phase in
                phases.append(phase)
                if phase == .verifyInstalled {
                    installedVerifierCount += 1
                    return installedVerifierCount == 1
                        ? InstallerPhaseExit.retryable
                        : InstallerPhaseExit.success
                }
                return InstallerPhaseExit.success
            },
            waitBeforeRetry: { waitAttempts.append($0) }
        )

        #expect(ready)
        #expect(phases == [
            .verifyInstalled,
            .register,
            .verifyInstalled,
            .verifyParent,
            .verifyMode
        ])
        #expect(waitAttempts.isEmpty)
    }

    @Test("An already-ready ordinary update performs no TIS writes")
    func skipsWritesForReadyOrdinaryUpdate() {
        var phases: [InstallerActivationPhase] = []

        let ready = PostInstallPreparation.convergeActivation(
            boundaries: InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: true
            ),
            attempts: 3,
            verifyBeforeWriting: true,
            runPhase: { phase in
                phases.append(phase)
                return InstallerPhaseExit.success
            },
            waitBeforeRetry: { _ in }
        )

        #expect(ready)
        #expect(phases == [
            .verifyInstalled,
            .verifyParent,
            .verifyMode,
            .verifySelected
        ])
    }

    @Test("A registration change always performs its required TIS writes")
    func registrationChangeDoesNotTrustExistingRegistration() {
        var phases: [InstallerActivationPhase] = []

        let ready = PostInstallPreparation.convergeActivation(
            boundaries: InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: false
            ),
            attempts: 3,
            verifyBeforeWriting: false,
            runPhase: { phase in
                phases.append(phase)
                return InstallerPhaseExit.success
            },
            waitBeforeRetry: { _ in }
        )

        #expect(ready)
        #expect(phases == [
            .register,
            .verifyInstalled,
            .enableParent,
            .verifyParent,
            .enableMode,
            .verifyMode
        ])
    }

    @Test("A failed boundary cannot execute later TIS writes")
    func stopsAfterFailedBoundary() {
        var phases: [InstallerActivationPhase] = []
        let ready = PostInstallPreparation.convergeActivation(
            boundaries: InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: true
            ),
            attempts: 2,
            verifyBeforeWriting: true,
            runPhase: { phase in
                phases.append(phase)
                return phase == .verifyInstalled
                    ? InstallerPhaseExit.retryable
                    : InstallerPhaseExit.success
            },
            waitBeforeRetry: { _ in }
        )

        #expect(!ready)
        #expect(!phases.contains(.enableParent))
        #expect(!phases.contains(.selectMode))
    }

    @Test("Activation requires consecutive fresh stable passes")
    func requiresConsecutiveStableActivationPasses() {
        var verificationPass = 0
        var waits: [Int] = []
        let ready = PostInstallPreparation.convergeStableActivation(
            boundaries: InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: true
            ),
            attempts: 5,
            requiredStablePasses: 3,
            verifyBeforeWriting: false,
            runPhase: { phase in
                if phase == .verifySelected {
                    verificationPass += 1
                    if verificationPass == 2 {
                        return InstallerPhaseExit.retryable
                    }
                }
                return InstallerPhaseExit.success
            },
            waitBeforeRetry: { waits.append($0) }
        )

        #expect(ready)
        #expect(waits == [1, 2, 3])
        #expect(verificationPass >= 6)
    }

    @Test("Transient activation never reaches a stable success")
    func rejectsAlternatingTransientActivation() {
        var selectedVerification = 0
        let ready = PostInstallPreparation.convergeStableActivation(
            boundaries: InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: true
            ),
            attempts: 5,
            requiredStablePasses: 3,
            verifyBeforeWriting: true,
            runPhase: { phase in
                guard phase == .verifySelected else {
                    return InstallerPhaseExit.success
                }
                selectedVerification += 1
                return selectedVerification.isMultiple(of: 2)
                    ? InstallerPhaseExit.retryable
                    : InstallerPhaseExit.success
            },
            waitBeforeRetry: { _ in }
        )

        #expect(!ready)
    }

    @Test("Stable activation rejects an impossible observation budget")
    func rejectsImpossibleStableActivationBudget() {
        var phaseCount = 0
        let ready = PostInstallPreparation.convergeStableActivation(
            boundaries: InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: false
            ),
            attempts: 2,
            requiredStablePasses: 3,
            verifyBeforeWriting: true,
            runPhase: { _ in
                phaseCount += 1
                return InstallerPhaseExit.success
            },
            waitBeforeRetry: { _ in }
        )

        #expect(!ready)
        #expect(phaseCount == 0)
    }

    @Test("Temporary fallback retirement is a separate final boundary")
    func retiresTemporaryFallbackOnlyAfterStableActivation() {
        let fallback = InputSourceLifecycleRules.temporaryFallbackBoundary(
            shouldSelect: true,
            hasTemporaryFallback: true
        )
        #expect(fallback?.action == .disableTemporaryFallback)
        #expect(fallback?.verify == .verifyTemporaryFallbackDisabled)
        #expect(!InputSourceLifecycleRules.activationBoundaries(
            shouldSelect: true
        ).contains { $0.action == .disableTemporaryFallback })
    }

    @Test("Fallback retirement is one bounded action and verification")
    func retiresFallbackWithoutRetryingInsideGenerationLock() throws {
        let boundary = try #require(
            InputSourceLifecycleRules.temporaryFallbackBoundary(
                shouldSelect: true,
                hasTemporaryFallback: true
            )
        )
        var phases: [InstallerActivationPhase] = []

        let retired = PostInstallPreparation.retireTemporaryFallback(
            boundary: boundary,
            runPhase: { phase in
                phases.append(phase)
                return phase == .verifyTemporaryFallbackDisabled
                    ? InstallerPhaseExit.retryable
                    : InstallerPhaseExit.success
            }
        )

        #expect(!retired)
        #expect(phases == [
            .disableTemporaryFallback,
            .verifyTemporaryFallbackDisabled
        ])
    }

    @Test("Scheduling publishes a one-shot agent before its generation marker")
    func schedulesOneShotActivationRepair() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HangyeolActivation.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = URL(
            fileURLWithPath:
                "/Library/Input Methods/Hangyeol.app/Contents/MacOS/Hangyeol"
        )

        #expect(!PostInstallPreparation.scheduleActivationRepair(
            installationKind: .ordinaryUpdate,
            shouldSelect: false,
            temporaryFallbackSourceID: "com.apple.keylayout.ABC",
            executableURL: executable,
            version: "3.0.15",
            build: "98",
            homeDirectory: home
        ))

        #expect(PostInstallPreparation.scheduleActivationRepair(
            installationKind: .ordinaryUpdate,
            shouldSelect: true,
            temporaryFallbackSourceID: "com.apple.keylayout.ABC",
            executableURL: executable,
            version: "3.0.15",
            build: "98",
            homeDirectory: home
        ))

        let marker = home.appendingPathComponent(
            "Library/Application Support/Hangyeol/"
                + "input-source-activation-pending.plist"
        )
        let agent = home.appendingPathComponent(
            "Library/LaunchAgents/"
                + PostInstallPreparation.activationAgentLabel + ".plist"
        )
        let request = try PropertyListDecoder().decode(
            PendingInputSourceActivation.self,
            from: Data(contentsOf: marker)
        )
        let agentValues = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: agent),
                format: nil
            ) as? [String: Any]
        )

        #expect(request.installationKind == .ordinaryUpdate)
        #expect(request.shouldSelect)
        #expect(
            request.temporaryFallbackSourceID
                == "com.apple.keylayout.ABC"
        )
        #expect(request.version == "3.0.15")
        #expect(agentValues["RunAtLoad"] as? Bool == true)
        #expect(agentValues["KeepAlive"] == nil)
        #expect((agentValues["ProgramArguments"] as? [String]) == [
            executable.path,
            PostInstallPreparation.repairPendingArgument
        ])
        #expect(PostInstallPreparation.hasPendingActivation(homeDirectory: home))
    }

    @Test("A retired marker remains authoritative when stale agent cleanup fails")
    func markerRetirementSurvivesStaleAgentCleanupFailure() {
        var actions: [String] = []

        let retired = PostInstallPreparation.retireActivationRequest(
            removeMarker: {
                actions.append("marker")
                return true
            },
            removeAgent: {
                actions.append("agent")
                return false
            },
            clearSnapshot: { actions.append("snapshot") }
        )

        #expect(retired)
        #expect(actions == ["marker", "snapshot", "agent"])
    }

    @Test("A marker removal failure preserves the retry generation")
    func markerRemovalFailurePreservesRetryGeneration() {
        var actions: [String] = []

        let retired = PostInstallPreparation.retireActivationRequest(
            removeMarker: {
                actions.append("marker")
                return false
            },
            removeAgent: {
                actions.append("agent")
                return true
            },
            clearSnapshot: { actions.append("snapshot") }
        )

        #expect(!retired)
        #expect(actions == ["marker"])
    }

    @Test("Ordinary launches ignore a missing activation marker")
    func ordinaryLaunchIgnoresMissingActivationMarker() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HangyeolActivationMissing.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(!PostInstallPreparation.hasPendingActivation(homeDirectory: home))
    }
}

@Suite("Installer Session Contract")
struct InstallerSessionContractTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func script(named name: String) throws -> String {
        try String(
            contentsOf: repoRoot
                .appendingPathComponent("Packaging/scripts")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func repositoryFile(named name: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func absoluteCommandPaths(in source: String) throws -> Set<String> {
        let expression = try NSRegularExpression(
            pattern: #"(?m)(?:^|[\s;|&(])(/(?:bin|sbin|usr/bin|usr/sbin|usr/libexec)/[A-Za-z0-9._+-]+)"#
        )
        let sourceRange = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: sourceRange).compactMap {
            guard let range = Range($0.range(at: 1), in: source) else {
                return nil
            }
            return String(source[range])
        })
    }

    private func classifyInstallation(
        wasInstalled: String,
        previousBundleIdentifier: String = ProductIdentity.bundleID,
        previousConnectionName: String = ProductIdentity.connectionName,
        previousInputModeSchema: String = "{\"mode\":\"Hang\"}",
        currentBundleIdentifier: String = ProductIdentity.bundleID,
        currentConnectionName: String = ProductIdentity.connectionName,
        currentInputModeSchema: String = "{\"mode\":\"Hang\"}"
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repoRoot.appendingPathComponent(
                "Packaging/scripts/postinstall_classification.sh"
            ).path,
            wasInstalled,
            previousBundleIdentifier,
            previousConnectionName,
            previousInputModeSchema,
            currentBundleIdentifier,
            currentConnectionName,
            currentInputModeSchema
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == EXIT_SUCCESS)
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @Test("Installer classification fails closed without an explicit first-install snapshot")
    func classifiesInstallerSessionWithoutLaunchingHangyeol() throws {
        #expect(try classifyInstallation(wasInstalled: "1") == "ordinary-update")
        #expect(try classifyInstallation(
            wasInstalled: "1",
            currentInputModeSchema: "{\"mode\":\"Hang\",\"new\":true}"
        ) == "registration-change")
        #expect(try classifyInstallation(
            wasInstalled: "1",
            previousInputModeSchema: ""
        ) == "registration-change")
        #expect(try classifyInstallation(wasInstalled: "0") == "first-installation")
        #expect(try classifyInstallation(wasInstalled: "") == "registration-change")
    }

    @Test("Preinstall leaves the active source before terminating only Hangyeol processes")
    func preinstallHandsOffTheActiveInputSource() throws {
        let source = try script(named: "preinstall")
        let packagedSignatureRange = try #require(
            source.range(of: "codesign --verify --strict \"$PACKAGED_HELPER\"")
        )
        let stagingRange = try #require(
            source.range(of: "/private/tmp/hangyeol-preinstall.XXXXXX")
        )
        let prepareRange = try #require(source.range(of: "--prepare-update"))
        let snapshotRange = try #require(
            source.range(of: "HangyeolSelectedBeforeInstall")
        )
        let terminateRange = try #require(
            source.range(of: "pkill -TERM -x -u \"$USER_ID\"")
        )
        let waitRange = try #require(
            source.range(of: "--wait-for-process-exit 3")
        )
        let forceRange = try #require(
            source.range(of: "pkill -KILL -x -u \"$USER_ID\"")
        )

        #expect(source.contains("for process_name in Hangyeol PriType PriTypeV2"))
        #expect(source.contains("selected-before"))
        #expect(source.contains("fallback-source-id"))
        #expect(source.contains("fallback-was-enabled"))
        #expect(source.contains("HangyeolInstalledBeforeInstall"))
        #expect(source.contains("com.thlim.inputmethod.Hangyeol"))
        #expect(source.contains(Misordered3xIdentity.bundleID))
        #expect(source.contains("com.meapri.hangyeol.inputmethod"))
        #expect(source.contains(Legacy2xIdentity.bundleID))
        #expect(source.contains("/Library/Input Methods/PriType.app"))
        #expect(source.contains("/Library/Input Methods/Hangyeol.localized"))
        #expect(source.contains("pkgutil --forget com.meapri.hangyeol"))
        #expect(source.contains("pkgutil --forget com.meapri.PriTypeV2"))
        #expect(source.contains("tccutil reset Accessibility"))
        #expect(source.contains("2.8.24|2.8.25"))
        #expect(packagedSignatureRange.lowerBound < stagingRange.lowerBound)
        #expect(stagingRange.lowerBound < prepareRange.lowerBound)
        #expect(prepareRange.lowerBound < snapshotRange.lowerBound)
        #expect(snapshotRange.lowerBound < terminateRange.lowerBound)
        #expect(terminateRange.lowerBound < waitRange.lowerBound)
        #expect(waitRange.lowerBound < forceRange.lowerBound)
        #expect(!source.contains("/bin/rm -rf \"/Library/Input Methods/Hangyeol.app\""))
        #expect(!source.contains("TextInputMenuAgent"))
        #expect(!source.contains("TextInputSwitcher"))
        #expect(!source.contains("keyboardservicesd"))
        #expect(!source.contains("imklaunchagent"))
        #expect(!source.contains("cfprefsd"))
        #expect(!source.contains("killall"))
        #expect(!source.contains("sleep "))
        #expect(!source.contains("for user_home in /Users/*"))
    }

    @Test("Installer scripts reference only commands available on macOS")
    func installerAbsoluteCommandPathsExist() throws {
        for scriptName in ["preinstall", "postinstall"] {
            let commands = try absoluteCommandPaths(
                in: script(named: scriptName)
            )
            #expect(!commands.isEmpty)
            for command in commands {
                #expect(
                    FileManager.default.isExecutableFile(atPath: command),
                    "\(scriptName) references missing executable \(command)"
                )
            }
        }
    }

    @Test("Postinstall completes only after the one-shot user repair is ready")
    func postinstallWaitsForActivationCompletion() throws {
        let source = try script(named: "postinstall")
        let validationRange = try #require(
            source.range(of: "codesign --verify --strict \"$APP_PATH\"")
        )
        let classificationRange = try #require(
            source.range(of: "classify_hangyeol_installation")
        )
        let scheduleRange = try #require(
            source.range(of: "--schedule-input-source-repair")
        )
        let terminateRange = try #require(
            source.range(of: "pkill -TERM -x -u \"$USER_ID\"")
        )
        let processExitRange = try #require(
            source.range(of: "--wait-for-process-exit 3")
        )
        let openRange = try #require(
            source.range(of: "run_as_console_user /usr/bin/open \"$APP_PATH\"")
        )
        let waitRange = try #require(
            source.range(of: "--wait-for-input-source-activation")
        )
        let timeoutRange = try #require(source.range(
            of: "activation did not complete in the current login session"
        ))
        let timeoutExitRange = try #require(
            source.range(
                of: "open_input_source_settings\n    exit 0\nfi",
                range: timeoutRange.upperBound..<source.endIndex
            )
        )
        let bootoutRange = try #require(
            source.range(of: "launchctl bootout")
        )
        let bootstrapRange = try #require(
            source.range(of: "launchctl bootstrap")
        )

        #expect(source.contains("launchctl asuser"))
        #expect(source.contains("sudo -H -u"))
        #expect(source.contains("postinstall_classification.sh"))
        #expect(source.contains("HangyeolSelectedBeforeInstall"))
        #expect(source.contains("HangyeolFallbackInputSourceID"))
        #expect(source.contains("HangyeolFallbackWasEnabled"))
        #expect(source.contains("SHOULD_SELECT=true"))
        #expect(source.contains("TEMPORARY_FALLBACK_SOURCE_ID"))
        #expect(source.contains("HangyeolPendingPostInstallSetup"))
        #expect(source.contains("com.thlim.hangyeol.activation-repair"))
        #expect(source.contains("ordinary-update)"))
        #expect(source.contains("registration-change)"))
        #expect(validationRange.lowerBound < classificationRange.lowerBound)
        #expect(classificationRange.lowerBound < scheduleRange.lowerBound)
        #expect(source.contains("for process_name in Hangyeol PriType PriTypeV2"))
        #expect(scheduleRange.lowerBound < terminateRange.lowerBound)
        #expect(terminateRange.lowerBound < processExitRange.lowerBound)
        #expect(processExitRange.lowerBound < openRange.lowerBound)
        #expect(source.contains("hangyeol-postinstall.XXXXXX"))
        #expect(source.contains("codesign --verify --strict \"$STAGED_HELPER\""))
        #expect(openRange.lowerBound < waitRange.lowerBound)
        #expect(waitRange.lowerBound < timeoutRange.lowerBound)
        #expect(timeoutRange.lowerBound < timeoutExitRange.lowerBound)
        #expect(timeoutExitRange.lowerBound < bootoutRange.lowerBound)
        #expect(source.contains("ACTIVATION_MARKER="))
        #expect(openRange.lowerBound < bootoutRange.lowerBound)
        #expect(bootoutRange.lowerBound < bootstrapRange.lowerBound)
        #expect(!source.contains("--post-install-prepare"))
        #expect(!source.contains("--installer-register"))
        #expect(!source.contains("open -W"))
        #expect(!source.contains("lsregister"))
        #expect(!source.contains("kickstart -k"))
        #expect(!source.contains("TextInputMenuAgent"))
        #expect(!source.contains("TextInputSwitcher"))
        #expect(!source.contains("keyboardservicesd"))
        #expect(!source.contains("imklaunchagent"))
        #expect(!source.contains("killall"))
        #expect(!source.contains("eval "))
        #expect(!source.contains("sleep "))
    }

    @Test("Preinstall snapshots only the registration identity needed for classification")
    func preinstallCapturesUpdateClassificationEvidence() throws {
        let source = try script(named: "preinstall")

        #expect(source.contains("Print :CFBundleIdentifier"))
        #expect(source.contains("Print :InputMethodConnectionName"))
        #expect(source.contains("/usr/bin/plutil"))
        #expect(source.contains("-extract ComponentInputModeDict json -o -"))
        #expect(source.contains("HangyeolInstalledBundleIdentifier"))
        #expect(source.contains("HangyeolInstalledConnectionName"))
        #expect(source.contains("HangyeolInstalledInputModeSchema"))
        #expect(source.contains("HangyeolFallbackInputSourceID"))
        #expect(source.contains("HangyeolFallbackWasEnabled"))
        #expect(!source.contains("HangyeolRunningProcessIdentifierBeforeInstall"))
        #expect(!source.contains("pgrep -x -u \"$USER_ID\" Hangyeol"))
    }

    @Test("Signing paths do not attach the restricted InputMethodKit entitlement")
    func signingOmitsRestrictedInputMethodEntitlement() throws {
        let signingScripts = [
            "build_local.sh",
            "install.sh",
            "build_debug.sh",
            "build_release.sh",
            "distribute.sh"
        ]

        for scriptName in signingScripts {
            let source = try repositoryFile(named: scriptName)
            #expect(
                !source.contains("Hangyeol.entitlements"),
                "\(scriptName) must not create a signature that macOS terminates before launch"
            )
        }
    }

    @Test("Packaging replaces the retired identifier at the canonical bundle path")
    func packagingAllowsIdentifierMigrationWithoutRelocation() throws {
        for scriptName in ["build_local.sh", "build_debug.sh", "build_release.sh"] {
            let source = try repositoryFile(named: scriptName)
            let analyzeRange = try #require(source.range(of: "pkgbuild --analyze"))
            let strictIdentifierRange = try #require(
                source.range(of: "BundleHasStrictIdentifier -bool NO")
            )

            #expect(analyzeRange.lowerBound < strictIdentifierRange.lowerBound)
            #expect(source.contains("--product HangyeolInstallerHelper"))
            #expect(source.contains("Tools/stage_package_scripts.sh"))
            #expect(source.contains("--scripts \"$SCRIPTS_DIR\""))
        }

        let staging = try repositoryFile(named: "Tools/stage_package_scripts.sh")
        #expect(staging.contains("HangyeolInstallerHelper"))
        #expect(staging.contains("codesign --force --options runtime"))
        #expect(staging.contains("codesign --verify --strict --verbose=2"))
    }

    @Test("Installed app presents settings independently of Accessibility permission")
    func installedAppAlwaysPresentsSettings() throws {
        let source = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Sources/Hangyeol/main.swift"),
            encoding: .utf8
        )

        #expect(source.contains("if shouldShowSettingsAfterInstall {"))
        #expect(source.contains("case let .scheduleRepair"))
        #expect(source.contains("case .repairPending"))
        #expect(source.contains("case .waitForActivation"))
        #expect(source.contains("case let .phase(phase, sourceID)"))
        #expect(!source.contains("applicationShouldTerminate"))
        #expect(!source.contains("prepareForApplicationTermination"))
        #expect(!source.contains("Task.detached(priority: .utility) {\n            _ = InputSourceManager.shared.cleanupStaleInputSources()"))
        #expect(!source.contains("&& !IOKitManager.hasAccessibilityPermission()"))
    }

    @Test("Installer repair starts only after the normal IMK server")
    func repairedSessionStartsServerBeforeTISWrites() throws {
        let source = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Sources/Hangyeol/main.swift"),
            encoding: .utf8
        )
        let commandRange = try #require(
            source.range(of: "if let command = PostInstallPreparation.command")
        )
        let applicationRange = try #require(
            source.range(of: "let app = NSApplication.shared")
        )
        let serverRange = try #require(source.range(of: "_ = IMKServer("))
        let scheduledRepairRange = try #require(
            source.range(of: "schedulePendingInputSourceRepair()")
        )
        let repairRange = try #require(
            source.range(of: "PostInstallPreparation.repairPendingActivation(")
        )

        #expect(commandRange.lowerBound < serverRange.lowerBound)
        #expect(commandRange.lowerBound < applicationRange.lowerBound)
        #expect(serverRange.lowerBound < scheduledRepairRange.lowerBound)
        #expect(scheduledRepairRange.lowerBound < repairRange.lowerBound)
        #expect(source.contains("pendingInstallerRepair = PendingInstallerRepair("))
        #expect(source.contains("PostInstallPreparation.hasPendingActivation()"))
        #expect(source.contains("pending = Self.currentInstallerIdentity()"))
        #expect(source.contains("DispatchQueue.global(qos: .userInitiated).async"))
        #expect(!source.contains(
            "guard PostInstallPreparation.repairPendingActivation("
        ))
        #expect(!source.contains("exit(repaired ? EXIT_SUCCESS"))
        #expect(source.contains("exit(InputSourceManager.shared.runInstallerPhase"))
        #expect(!source.contains("--post-install-prepare"))
    }

    @Test("Installer retires its fallback and marker only after stable TIS verification")
    func stableActivationPrecedesInstallerCleanup() throws {
        let source = try String(
            contentsOf: repoRoot
                .appendingPathComponent(
                    "Sources/HangyeolCore/PostInstallPreparation.swift"
                ),
            encoding: .utf8
        )
        let stableRange = try #require(
            source.range(of: "let activated = convergeStableActivation(")
        )
        let activatedGuardRange = try #require(
            source.range(of: "guard activated else { return false }")
        )
        let fallbackRange = try #require(
            source.range(of: "if let fallbackBoundary {")
        )
        let readinessRange = try #require(
            source.range(of: "verifyFreshReadiness: {")
        )
        let schedulingLockRange = try #require(
            source.range(of: "operation: F_LOCK")
        )
        let repairLockRange = try #require(
            source.range(of: "at: paths.repairLock")
        )
        let finalGenerationLockRange = try #require(
            source.range(
                of: "try withActivationLock(\n"
                    + "                            at: paths.generationLock",
                range: readinessRange.upperBound..<source.endIndex
            )
        )
        let markerRemovalRange = try #require(
            source.range(of: "let retired = retireActivationRequest(")
        )

        #expect(stableRange.lowerBound < activatedGuardRange.lowerBound)
        #expect(activatedGuardRange.lowerBound < readinessRange.lowerBound)
        #expect(readinessRange.lowerBound < finalGenerationLockRange.lowerBound)
        #expect(finalGenerationLockRange.lowerBound < fallbackRange.lowerBound)
        #expect(finalGenerationLockRange.lowerBound < markerRemovalRange.lowerBound)
        #expect(schedulingLockRange.lowerBound < repairLockRange.lowerBound)
        #expect(
            source.components(separatedBy: "at: paths.generationLock").count
                == 4
        )
        #expect(source.components(separatedBy: "withActivationLock(").count == 5)
        #expect(!source.contains("operation: F_TLOCK"))
        #expect(source.contains("input-source-activation-repair.lock"))
        #expect(source.contains("input-source-activation-generation.lock"))
        #expect(!source.contains("refreshTextInputMenuAgent"))
        #expect(!source.contains("com.apple.TextInputMenuAgent"))
    }
}
