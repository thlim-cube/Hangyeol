import Foundation
import Testing
@testable import PriTypeCore

@Suite("Post-install Preparation")
struct PostInstallPreparationTests {
    @Test("Recognizes only the private installer preparation argument")
    func recognizesPreparationArgument() {
        #expect(PostInstallPreparation.shouldPrepare(arguments: ["PriType", "--post-install-prepare"]))
        #expect(!PostInstallPreparation.shouldPrepare(arguments: ["PriType"]))
        #expect(!PostInstallPreparation.shouldPrepare(arguments: ["PriType", "--unrelated"]))
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

    @Test("Keeps the preinstall selection snapshot until preparation succeeds")
    func keepsSelectionSnapshotUntilCleared() throws {
        let suiteName = "PostInstallPreparationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PostInstallPreparation.selectedBeforeInstallKey)

        #expect(PostInstallPreparation.selectedBeforeInstall(in: defaults))
        #expect(PostInstallPreparation.selectedBeforeInstall(in: defaults))

        PostInstallPreparation.clearSelectedBeforeInstall(in: defaults)
        #expect(!PostInstallPreparation.selectedBeforeInstall(in: defaults))
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

    @Test("Preinstall only stops the console user's exact PriType processes")
    func preinstallIsUserScoped() throws {
        let source = try script(named: "preinstall")
        let snapshotRange = try #require(source.range(of: "PriTypeSelectedBeforeInstall"))
        let installedVersionRange = try #require(
            source.range(of: "Print :CFBundleShortVersionString")
        )
        let stopRange = try #require(source.range(of: "/usr/bin/pkill"))

        #expect(source.contains("pkill -x -u"))
        #expect(source.contains("AppleSelectedInputSources"))
        #expect(source.contains("2.8.24|2.8.25"))
        #expect(installedVersionRange.lowerBound < snapshotRange.lowerBound)
        #expect(snapshotRange.lowerBound < stopRange.lowerBound)
        #expect(!source.contains("/bin/rm -rf \"/Library/Input Methods/PriType.app\""))
        #expect(!source.contains("killall"))
        #expect(!source.contains("sleep "))
        #expect(!source.contains("for user_home in /Users/*"))
    }

    @Test("Postinstall prepares and launches PriType in the GUI user session")
    func postinstallUsesGUIUserSession() throws {
        let source = try script(named: "postinstall")

        #expect(source.contains("launchctl asuser"))
        #expect(source.contains("sudo -H -u"))
        #expect(source.components(separatedBy: "--post-install-prepare").count - 1 == 2)
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

    @Test("Installed app presents settings independently of Accessibility permission")
    func installedAppAlwaysPresentsSettings() throws {
        let source = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Sources/PriType/main.swift"),
            encoding: .utf8
        )

        #expect(source.contains("if shouldShowSettingsAfterInstall {"))
        #expect(!source.contains("&& !IOKitManager.hasAccessibilityPermission()"))
    }
}
