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

    @Test("Every action is followed by an external verifier before advancing")
    func verifiesEveryActivationBoundary() {
        let boundaries = InputSourceLifecycleRules.activationBoundaries(
            shouldSelect: false
        )
        var phases: [InstallerActivationPhase] = []
        var installedVerifierCount = 0
        var waitAttempts: [Int] = []

        let ready = PostInstallPreparation.convergeActivation(
            boundaries: boundaries,
            attempts: 3,
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
            .register,
            .verifyInstalled,
            .register,
            .verifyInstalled,
            .enableParent,
            .verifyParent,
            .enableMode,
            .verifyMode
        ])
        #expect(waitAttempts == [1])
    }

    @Test("A failed boundary cannot execute later TIS writes")
    func stopsAfterFailedBoundary() {
        var phases: [InstallerActivationPhase] = []
        let ready = PostInstallPreparation.convergeActivation(
            boundaries: InputSourceLifecycleRules.activationBoundaries(
                shouldSelect: true
            ),
            attempts: 2,
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
            version: "3.0.7",
            build: "90",
            homeDirectory: home
        ))

        #expect(PostInstallPreparation.scheduleActivationRepair(
            installationKind: .ordinaryUpdate,
            shouldSelect: true,
            temporaryFallbackSourceID: "com.apple.keylayout.ABC",
            executableURL: executable,
            version: "3.0.7",
            build: "90",
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
        #expect(request.version == "3.0.7")
        #expect(agentValues["RunAtLoad"] as? Bool == true)
        #expect(agentValues["KeepAlive"] == nil)
        #expect((agentValues["ProgramArguments"] as? [String]) == [
            executable.path,
            PostInstallPreparation.repairPendingArgument
        ])
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

    @Test("Postinstall delegates every installation kind to a one-shot user repair job")
    func postinstallDelegatesActivationOutsidePackageKit() throws {
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
        #expect(scheduleRange.lowerBound < bootoutRange.lowerBound)
        #expect(bootoutRange.lowerBound < bootstrapRange.lowerBound)
        #expect(!source.contains("--post-install-prepare"))
        #expect(!source.contains("--installer-register"))
        #expect(!source.contains("open -W"))
        #expect(!source.contains("pkill"))
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
        #expect(source.contains("case let .phase(phase, sourceID)"))
        #expect(!source.contains("applicationShouldTerminate"))
        #expect(!source.contains("prepareForApplicationTermination"))
        #expect(!source.contains("Task.detached(priority: .utility) {\n            _ = InputSourceManager.shared.cleanupStaleInputSources()"))
        #expect(!source.contains("&& !IOKitManager.hasAccessibilityPermission()"))
    }

    @Test("Private installer commands exit before the normal IMK server starts")
    func privateCommandsStayOutsideTheInteractiveRuntime() throws {
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

        #expect(commandRange.lowerBound < serverRange.lowerBound)
        #expect(commandRange.lowerBound < applicationRange.lowerBound)
        #expect(source.contains("exit(repaired ? EXIT_SUCCESS"))
        #expect(source.contains("exit(InputSourceManager.shared.runInstallerPhase"))
        #expect(!source.contains("--post-install-prepare"))
    }
}
