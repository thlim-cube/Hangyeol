import Foundation
import Testing
@testable import HangyeolCore

@Suite("Post-install Preparation")
struct PostInstallPreparationTests {
    @Test("Recognizes only the private installer preparation argument")
    func recognizesPreparationArgument() {
        #expect(PostInstallPreparation.shouldPrepare(arguments: ["Hangyeol", "--post-install-prepare"]))
        #expect(!PostInstallPreparation.shouldPrepare(arguments: ["Hangyeol"]))
        #expect(!PostInstallPreparation.shouldPrepare(arguments: ["Hangyeol", "--unrelated"]))
    }

    @Test("Recognizes only the private external status argument")
    func recognizesStatusArgument() {
        #expect(PostInstallPreparation.shouldCheckStatus(
            arguments: ["Hangyeol", "--post-install-status"]
        ))
        #expect(!PostInstallPreparation.shouldCheckStatus(arguments: ["Hangyeol"]))
        #expect(!PostInstallPreparation.shouldCheckStatus(
            arguments: ["Hangyeol", "--post-install-prepare"]
        ))
    }

    @Test("Recognizes only the private signed-app launch probe argument")
    func recognizesLaunchProbeArgument() {
        #expect(PostInstallPreparation.shouldRunLaunchProbe(
            arguments: ["Hangyeol", "--verify-launch"]
        ))
        #expect(!PostInstallPreparation.shouldRunLaunchProbe(arguments: ["Hangyeol"]))
        #expect(!PostInstallPreparation.shouldRunLaunchProbe(
            arguments: ["Hangyeol", "--post-install-prepare"]
        ))
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
        defaults.set(true, forKey: PostInstallPreparation.selectedBeforeInstallKey)
        defaults.set(true, forKey: PostInstallPreparation.installedBeforeInstallKey)

        #expect(PostInstallPreparation.selectedBeforeInstall(in: defaults))
        #expect(PostInstallPreparation.installedBeforeInstall(in: defaults))

        PostInstallPreparation.clearInstallationSnapshot(in: defaults)
        #expect(!PostInstallPreparation.selectedBeforeInstall(in: defaults))
        #expect(!PostInstallPreparation.installedBeforeInstall(in: defaults))
    }

    @Test("Activation waits for a separate authoritative success")
    func waitsForAuthoritativeActivation() {
        var probes = [false, true, true]
        var waitCount = 0

        let ready = PostInstallPreparation.settleAuthoritativeStatus(
            attempts: 5,
            probe: { probes.removeFirst() },
            waitAfterIncompleteProbe: { waitCount += 1 }
        )

        #expect(ready)
        #expect(waitCount == 2)
        #expect(probes.isEmpty)
    }

    @Test("Activation rejects an isolated external success")
    func rejectsTransientExternalSuccess() {
        var probes = [true, false, true, true]
        var waitCount = 0

        let ready = PostInstallPreparation.settleAuthoritativeStatus(
            attempts: 4,
            probe: { probes.removeFirst() },
            waitAfterIncompleteProbe: { waitCount += 1 }
        )

        #expect(ready)
        #expect(waitCount == 3)
        #expect(probes.isEmpty)
    }

    @Test("Activation never accepts caller-local success after the probe budget")
    func rejectsUnpersistedActivation() {
        var probeCount = 0
        var waitCount = 0

        let ready = PostInstallPreparation.settleAuthoritativeStatus(
            attempts: 3,
            probe: {
                probeCount += 1
                return false
            },
            waitAfterIncompleteProbe: { waitCount += 1 }
        )

        #expect(!ready)
        #expect(probeCount == 3)
        #expect(waitCount == 2)
    }

    @Test("First install selects Hangyeol while updates restore only prior selection")
    func selectionPolicyUsesThePreinstallSnapshot() {
        #expect(PostInstallPreparation.shouldSelectAfterActivation(
            wasInstalledBeforeUpdate: false,
            restorePreviousSelection: false
        ))
        #expect(PostInstallPreparation.shouldSelectAfterActivation(
            wasInstalledBeforeUpdate: true,
            restorePreviousSelection: true
        ))
        #expect(!PostInstallPreparation.shouldSelectAfterActivation(
            wasInstalledBeforeUpdate: true,
            restorePreviousSelection: false
        ))
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

    @Test("Preinstall migrates only the console user's current and retired product")
    func preinstallIsUserScoped() throws {
        let source = try script(named: "preinstall")
        let snapshotRange = try #require(source.range(of: "HangyeolSelectedBeforeInstall"))
        let installedVersionRange = try #require(
            source.range(of: "Print :CFBundleShortVersionString")
        )
        let retiredStopRange = try #require(
            source.range(of: "pkill -x -u \"$USER_ID\" PriType")
        )

        #expect(source.contains("pkill -x -u"))
        #expect(source.contains("AppleSelectedInputSources"))
        #expect(source.contains("HangyeolInstalledBeforeInstall"))
        #expect(source.contains("defaults write com.thlim.inputmethod.Hangyeol"))
        #expect(source.contains(Misordered3xIdentity.bundleID))
        #expect(source.contains("com.meapri.hangyeol.inputmethod"))
        #expect(source.contains(Legacy2xIdentity.bundleID))
        #expect(source.contains("/Library/Input Methods/PriType.app"))
        #expect(source.contains("/Library/Input Methods/Hangyeol.localized"))
        #expect(source.contains("pkgutil --forget com.meapri.hangyeol"))
        #expect(source.contains("pkgutil --forget com.meapri.PriTypeV2"))
        #expect(source.contains("tccutil reset Accessibility"))
        #expect(source.contains("2.8.24|2.8.25"))
        #expect(installedVersionRange.lowerBound < snapshotRange.lowerBound)
        #expect(snapshotRange.lowerBound < retiredStopRange.lowerBound)
        #expect(!source.contains("pkill -x -u \"$USER_ID\" Hangyeol"))
        #expect(!source.contains("/bin/rm -rf \"/Library/Input Methods/Hangyeol.app\""))
        #expect(!source.contains("killall"))
        #expect(!source.contains("sleep "))
        #expect(!source.contains("for user_home in /Users/*"))
    }

    @Test("Postinstall prepares and launches Hangyeol in the GUI user session")
    func postinstallUsesGUIUserSession() throws {
        let source = try script(named: "postinstall")

        #expect(source.contains("launchctl asuser"))
        #expect(source.contains("sudo -H -u"))
        #expect(source.components(separatedBy: "--post-install-prepare").count - 1 == 1)
        #expect(source.components(separatedBy: "--post-install-status").count - 1 == 1)
        #expect(!source.contains("pkill -x -u \"$USER_ID\" Hangyeol"))
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
        }
    }

    @Test("Installed app presents settings independently of Accessibility permission")
    func installedAppAlwaysPresentsSettings() throws {
        let source = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Sources/Hangyeol/main.swift"),
            encoding: .utf8
        )

        #expect(source.contains("if shouldShowSettingsAfterInstall {"))
        #expect(source.contains("waitForAuthoritativeStatus"))
        #expect(source.contains("shouldSelectAfterActivation"))
        #expect(!source.contains("Task.detached(priority: .utility) {\n            _ = InputSourceManager.shared.cleanupStaleInputSources()"))
        #expect(!source.contains("&& !IOKitManager.hasAccessibilityPermission()"))
    }
}
