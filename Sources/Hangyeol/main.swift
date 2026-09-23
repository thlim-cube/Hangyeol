import Foundation
import InputMethodKit
import Cocoa
import HangyeolCore
import HangyeolInstallerSupport

struct PendingInstallerRepair: Sendable {
    let executableURL: URL
    let version: String
    let build: String
}

var pendingInstallerRepair: PendingInstallerRepair?

if let command = PostInstallPreparation.command(
    arguments: CommandLine.arguments
) {
    let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? ""
    let build = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? ""
    guard let executableURL = Bundle.main.executableURL else {
        exit(PostInstallPreparation.failureExitCode)
    }

    switch command {
    case .launchProbe:
        exit(EXIT_SUCCESS)
    case .waitForActivation:
        let completed = PostInstallPreparation.waitForActivationCompletion()
        exit(completed ? EXIT_SUCCESS : PostInstallPreparation.failureExitCode)
    case .status:
        let status = InputSourceManager.shared.installedInputSourceStatus()
        print(
            "Hangyeol post-install status: candidates=\(status.hasRequiredCandidates) "
                + "enabled=\(status.isEnabled) ready=\(status.isReady)"
        )
        exit(status.isReady ? EXIT_SUCCESS : PostInstallPreparation.failureExitCode)
    case let .scheduleRepair(
        installationKind,
        shouldSelect,
        temporaryFallbackSourceID,
        waitForPackageReceipt,
        nextLoginOnly
    ):
        let scheduled = PostInstallPreparation.scheduleActivationRepair(
            installationKind: installationKind,
            shouldSelect: shouldSelect,
            temporaryFallbackSourceID: temporaryFallbackSourceID,
            waitForPackageReceipt: waitForPackageReceipt,
            nextLoginOnly: nextLoginOnly,
            executableURL: executableURL,
            version: version,
            build: build
        )
        exit(scheduled ? EXIT_SUCCESS : PostInstallPreparation.failureExitCode)
    case .repairPending:
        guard PostInstallPreparation.hasMatchingPendingActivation(version: version, build: build) else {
            exit(EXIT_SUCCESS)
        }
        pendingInstallerRepair = PendingInstallerRepair(
            executableURL: executableURL,
            version: version,
            build: build
        )
    case let .phase(phase, sourceID):
        exit(InputSourceManager.shared.runInstallerPhase(
            phase,
            fallbackSourceID: sourceID,
            appURL: Bundle.main.bundleURL
        ))
    case .invalid:
        exit(EX_USAGE)
    }
}

// LaunchServices may remember the last session copy for this bundle identifier.
// On a later login, redirect to the durable app before creating an IMK server.
if SessionRuntimeLease.isSessionApp(Bundle.main.bundleURL),
   let lease = SessionRuntimeLease.load(for: Bundle.main.bundleURL),
   !lease.permits(userID: getuid(), sessionID: SessionRuntimeLease.currentSessionID()) {
    let installedExecutable = "/Library/Input Methods/Hangyeol.app/Contents/MacOS/Hangyeol"
    func installedRuntimeIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: ProductIdentity.bundleID)
            .contains { $0.executableURL?.path == installedExecutable && !$0.isTerminated }
    }
    // More than one client can ask LaunchServices to reopen the expired copy.
    // Serialize redirects so those requests do not start duplicate IMK servers.
    let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hangyeol")
    do {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    } catch { exit(EXIT_FAILURE) }
    let lockFD = open(support.appendingPathComponent("session-redirect.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else { exit(EXIT_FAILURE) }
    let deadline = Date().addingTimeInterval(5)
    while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK, Date() < deadline else { exit(EXIT_FAILURE) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if installedRuntimeIsRunning() { exit(EXIT_SUCCESS) }
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = ["-n", "-g", "/Library/Input Methods/Hangyeol.app"]
    do {
        try launcher.run()
        while Date() < deadline {
            if installedRuntimeIsRunning() { exit(EXIT_SUCCESS) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if launcher.isRunning { launcher.terminate() }
        exit(EXIT_FAILURE)
    } catch {
        exit(EXIT_FAILURE)
    }
}

_ = Legacy3xSettingsMigration.migrateInstalledPreferences()
_ = Legacy2xSettingsMigration.migrateInstalledPreferences()

let kConnectionName = ProductIdentity.connectionName

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    
    private var hasLaunchedBefore = false
    private var workspaceActivationObserver: NSObjectProtocol?
    private let shouldShowSettingsAfterInstall: Bool
    private let pendingInstallerRepair: PendingInstallerRepair?

    init(
        shouldShowSettingsAfterInstall: Bool,
        pendingInstallerRepair: PendingInstallerRepair?
    ) {
        self.shouldShowSettingsAfterInstall = shouldShowSettingsAfterInstall
        self.pendingInstallerRepair = pendingInstallerRepair
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLogger.log("AppDelegate: applicationDidFinishLaunching")

        // System Settings writes TISRomanSwitchState outside this process.
        // Refresh low-frequency system preference snapshots whenever application
        // focus changes; key handling reads only their in-memory values.
        ConfigurationManager.shared.refreshCapsLockInputSourceSwitchState()
        ConfigurationManager.shared.refreshSystemTextFeatureSnapshot()
        ConfigurationManager.shared.refreshInputPolicySnapshot()
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            ConfigurationManager.shared.refreshCapsLockInputSourceSwitchState()
            ConfigurationManager.shared.refreshSystemTextFeatureSnapshot()
            ConfigurationManager.shared.refreshInputPolicySnapshot()
        }
        
        // Initialize IMK Server
        _ = IMKServer(name: kConnectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
        DebugLogger.log("IMKServer initialized")

        schedulePendingInputSourceRepair()

        // Observe only real TIS ownership/input-source transitions. Ordinary app,
        // tab, and field activation must keep Hangyeol's process-wide mode intact.
        InputModeCoordinator.shared.startSystemOwnershipMonitoring()
        
        if shouldShowSettingsAfterInstall {
            DispatchQueue.main.async {
                SettingsWindowController.shared.showSettings()
            }
        }
        
        // Setup toggle key monitoring
        setupIOKit()
        
        // Pre-load Hanja dictionary in background for instant lookup
        DispatchQueue.global(qos: .utility).async {
            HanjaManager.shared.loadIfNeeded()
        }
        
        // Setup update notifications
        UpdateNotifier.shared.setup()
        
        // Check for updates in background (respects user preference and 24h throttle)
        if ConfigurationManager.shared.autoUpdateCheckEnabled {
            Task.detached(priority: .utility) {
                let result = await UpdateChecker.shared.checkForUpdatesIfNeeded()
                if case .updateAvailable(let info) = result {
                    UpdateNotifier.shared.notifyUpdateAvailable(info)
                }
            }
        }
        
        // Mark as launched (don't show settings on first boot)
        hasLaunchedBefore = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLogger.log("AppDelegate: applicationShouldHandleReopen")
        // Only show settings when explicitly launched from Launchpad/Finder (reopen)
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
        return true
    }

    private func schedulePendingInputSourceRepair() {
        // The current-session copy serves input only. The canonical app owns
        // the durable repair request at the next login.
        guard PostInstallPreparation.canRepairFromCurrentBundle(Bundle.main.bundleURL) else {
            return
        }
        let pending: PendingInstallerRepair?
        if let pendingInstallerRepair {
            pending = pendingInstallerRepair
        } else if PostInstallPreparation.hasPendingActivation(),
                  PostInstallPreparation.shouldRepairOnOrdinaryLaunch() {
            pending = Self.currentInstallerIdentity()
        } else {
            pending = nil
        }
        guard let pending else { return }

        // Ordinary launches consume a matching marker if PackageKit started the
        // replacement IMK with `open`. `--repair-pending-input-source` still
        // owns the next-login retry. Do not look at the LaunchAgent plist
        // alone: that file is written before the marker.
        DispatchQueue.main.async {
            DispatchQueue.global(qos: .userInitiated).async {
                let repaired = PostInstallPreparation.repairPendingActivation(
                    executableURL: pending.executableURL,
                    version: pending.version,
                    build: pending.build
                )
                DebugLogger.log(
                    "Post-install input-source repair completed = \(repaired)"
                )
            }
        }
    }

    private static func currentInstallerIdentity() -> PendingInstallerRepair? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? ""
        guard !version.isEmpty, !build.isEmpty else { return nil }
        return PendingInstallerRepair(
            executableURL: executableURL,
            version: version,
            build: build
        )
    }
    
    private func setupIOKit() {
        // Check/request Accessibility permission
        if !IOKitManager.hasAccessibilityPermission() {
            // Record the permission failure in the same ownership state machine used
            // by both monitoring backends.
            _ = RightCommandSuppressor.shared.start()
            DebugLogger.log("Requesting Accessibility permission...")
            IOKitManager.requestAccessibilityPermission()
            
            // Poll until user grants permission from the system popup
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                DebugLogger.log("Accessibility granted via system popup — starting key monitoring")
                self.setupIOKit()
            }
            return
        }
        
        // Set callback for CGEventTap toggle handler (handles all toggle keys)
        RightCommandSuppressor.shared.onToggle = { trace, eventTimestamp in
            InputModeCoordinator.shared.requestToggle(
                source: .customKey, trace: trace, eventTimestamp: eventTimestamp
            )
        }
        
        // Set callback for Right Option key → Hanja lookup
        RightCommandSuppressor.shared.onHanjaLookup = {
            HangyeolInputController.sharedController?.triggerHanjaLookup()
        }

        IOKitManager.shared.onRightCommandToggle = { trace in
            InputModeCoordinator.shared.requestToggle(source: .iokitFallback, trace: trace)
        }
        IOKitManager.shared.onRightOptionHanja = {
            HangyeolInputController.sharedController?.triggerHanjaLookup()
        }

        // Install the handoff before starting the tap. The suppressor tears the
        // tap down first and invokes this callback at most once.
        RightCommandSuppressor.shared.onTapFailed = {
            DebugLogger.log("CGEventTap stopped repeatedly — activating IOKit fallback")
            let started = IOKitManager.shared.start()
            DebugLogger.log("IOKit fallback start = \(started)")
        }
        
        // Track if CGEventTap started successfully
        let eventTapStarted = RightCommandSuppressor.shared.start()
        
        // IOKit backup: Only start and activate actual toggle if CGEventTap failed
        if eventTapStarted {
            DebugLogger.log("Primary: CGEventTap started successfully")
        } else {
            DebugLogger.log("Primary: CGEventTap FAILED - IOKit taking over as primary")
            let started = IOKitManager.shared.start()
            DebugLogger.log("Primary: IOKit fallback start = \(started)")
        }
        
        DebugLogger.log("Toggle key monitoring initialized")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(
    shouldShowSettingsAfterInstall: PostInstallPreparation.consumePending(),
    pendingInstallerRepair: pendingInstallerRepair
)
app.delegate = delegate
app.run()
