import Foundation
import InputMethodKit
import Cocoa
import HangyeolCore

private func isInputSourceAuthoritativelyReady() -> Bool {
    guard let executableURL = Bundle.main.executableURL else { return false }
    let probe = Process()
    let completion = DispatchSemaphore(value: 0)
    probe.executableURL = executableURL
    probe.arguments = [PostInstallPreparation.statusArgument]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    probe.terminationHandler = { _ in completion.signal() }
    do {
        try probe.run()
        guard completion.wait(timeout: .now() + 2) == .success else {
            probe.terminate()
            return false
        }
        return probe.terminationStatus == EXIT_SUCCESS
    } catch {
        return false
    }
}

private func openInputSourceSettingsAfterPreparationFailure() {
    guard let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.keyboard?InputSources"
    ) else {
        return
    }
    _ = NSWorkspace.shared.open(settingsURL)
}

if PostInstallPreparation.shouldRunLaunchProbe(arguments: CommandLine.arguments) {
    exit(EXIT_SUCCESS)
}

if PostInstallPreparation.shouldMarkPending(arguments: CommandLine.arguments) {
    PostInstallPreparation.markPending()
    exit(EXIT_SUCCESS)
}

if PostInstallPreparation.shouldCheckStatus(arguments: CommandLine.arguments) {
    let status = InputSourceManager.shared.installedInputSourceStatus()
    print(
        "Hangyeol post-install status: candidates=\(status.hasRequiredCandidates) "
            + "enabled=\(status.isEnabled) ready=\(status.isReady)"
    )
    exit(status.isReady ? EXIT_SUCCESS : PostInstallPreparation.failureExitCode)
}

_ = Legacy3xSettingsMigration.migrateInstalledPreferences()
_ = Legacy2xSettingsMigration.migrateInstalledPreferences()

let kConnectionName = ProductIdentity.connectionName

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    
    private var hasLaunchedBefore = false
    private var workspaceActivationObserver: NSObjectProtocol?
    private let shouldShowSettingsAfterInstall: Bool

    init(shouldShowSettingsAfterInstall: Bool) {
        self.shouldShowSettingsAfterInstall = shouldShowSettingsAfterInstall
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
        RightCommandSuppressor.shared.onToggle = { trace in
            InputModeCoordinator.shared.requestToggle(source: .customKey, trace: trace)
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

// MARK: - Main Entry Point

if PostInstallPreparation.shouldPrepare(arguments: CommandLine.arguments) {
    let restorePreviousSelection = PostInstallPreparation.selectedBeforeInstall()
    let wasInstalledBeforeUpdate = PostInstallPreparation.installedBeforeInstall()
    let result = InputSourceManager.shared.prepareInstalledInputSource(
        at: Bundle.main.bundleURL
    )
    let authoritativeReady = PostInstallPreparation.waitForAuthoritativeStatus {
        isInputSourceAuthoritativelyReady()
    }
    let shouldSelect = PostInstallPreparation.shouldSelectAfterActivation(
        wasInstalledBeforeUpdate: wasInstalledBeforeUpdate,
        restorePreviousSelection: restorePreviousSelection
    )
    let selection = authoritativeReady && shouldSelect
        ? InputSourceManager.shared.selectInstalledInputSource()
        : nil
    let selectionSucceeded = !shouldSelect || selection?.isSelected == true
    let isReady = authoritativeReady && selectionSucceeded
    if isReady {
        PostInstallPreparation.clearInstallationSnapshot()
    } else {
        openInputSourceSettingsAfterPreparationFailure()
    }
    let enableFailure = result.firstEnableFailure.map(String.init) ?? "none"
    let selectionStatus = selection.map { String($0.status) } ?? "preserved"
    print(
        "Hangyeol post-install: registration=\(result.registrationStatus) "
            + "enableFailure=\(enableFailure) "
            + "locallyEnabled=\(result.isLocallyVisibleAndEnabled) "
            + "authoritativeReady=\(authoritativeReady) "
            + "selection=\(selectionStatus) "
            + "selected=\(selection?.isSelected.description ?? "preserved") "
            + "ready=\(isReady)"
    )
    exit(isReady ? EXIT_SUCCESS : PostInstallPreparation.failureExitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate(
    shouldShowSettingsAfterInstall: PostInstallPreparation.consumePending()
)
app.delegate = delegate
app.run()
