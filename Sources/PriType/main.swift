import Foundation
import InputMethodKit
import Cocoa
import PriTypeCore

let kConnectionName = "PriType_InputString_v2"

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    
    private var hasLaunchedBefore = false
    private var workspaceActivationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLogger.log("AppDelegate: applicationDidFinishLaunching")

        // The single registered input source cannot expose PriType's internal
        // Korean/English mode through the macOS input-source icon. Create the
        // authoritative 한/A indicator once at process launch instead.
        StatusBarManager.shared.setup()

        // System Settings writes TISRomanSwitchState outside this process.
        // Refresh whenever application focus changes so both keyboard-monitor
        // backends and the settings UI share the current ownership snapshot.
        ConfigurationManager.shared.refreshCapsLockInputSourceSwitchState()
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            ConfigurationManager.shared.refreshCapsLockInputSourceSwitchState()
        }
        
        // Initialize IMK Server
        _ = IMKServer(name: kConnectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
        DebugLogger.log("IMKServer initialized")

        // Observe only real TIS ownership/input-source transitions. Ordinary app,
        // tab, and field activation must keep PriType's process-wide mode intact.
        InputModeCoordinator.shared.startSystemOwnershipMonitoring()
        
        Task.detached(priority: .utility) {
            InputSourceManager.shared.cleanupStaleInputSources()
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
            // Let the monitor owner publish the permission failure through the same
            // authoritative store observed by the status UI.
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
            PriTypeInputController.sharedController?.triggerHanjaLookup()
        }

        IOKitManager.shared.onRightCommandToggle = { trace in
            InputModeCoordinator.shared.requestToggle(source: .iokitFallback, trace: trace)
        }
        IOKitManager.shared.onRightOptionHanja = {
            PriTypeInputController.sharedController?.triggerHanjaLookup()
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
