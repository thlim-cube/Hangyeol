import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// MARK: - StatusBarUpdating Protocol

/// Protocol for updating the status bar mode indicator
/// Enables dependency injection and testability
public protocol StatusBarUpdating: AnyObject {
    /// Update the status bar to show current input mode
    func setMode(_ mode: InputMode)
}

/// The currently active system-wide toggle-key monitor.
///
/// This is deliberately a small presentation contract. The monitor remains the
/// owner of its lifecycle; the status bar only reports the backend selected by
/// the launch wiring.
public enum InputMonitorBackend: Sendable, Equatable {
    case starting
    case waitingForAccessibility
    case cgEventTap
    case iokitFallback
    case unavailable
}

struct InputHealthMetadata: Sendable {
    let monitorBackend: InputMonitorBackend
    let accessibilityGranted: Bool
    let secureInputActive: Bool

    var needsAttention: Bool {
        !accessibilityGranted || monitorBackend == .unavailable
    }

    var isStarting: Bool {
        monitorBackend == .starting || monitorBackend == .waitingForAccessibility
    }

    var usesFallback: Bool {
        monitorBackend == .iokitFallback
    }
}

// MARK: - StatusBarManager

/// Manages a status bar item to show current input mode (한/A) and redacted
/// input-health metadata.
///
/// This class handles all UI updates on the main thread for thread safety.
public final class StatusBarManager: NSObject, StatusBarUpdating, NSMenuDelegate, @unchecked Sendable {
    
    // MARK: - Singleton
    
    public static let shared = StatusBarManager()
    
    // MARK: - Properties
    
    private var statusItem: NSStatusItem?
    private var lastMode: InputMode?
    private var monitorBackend: InputMonitorBackend = .starting
    private var healthSummaryItem: NSMenuItem?
    private var currentModeItem: NSMenuItem?
    private var monitorBackendItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var secureInputItem: NSMenuItem?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Setup
    
    /// Initialize the status bar item
    @MainActor
    public func setup() {
        guard statusItem == nil else { return }

        // variableLength hugs the glyph like the system input-source indicator.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.autosaveName = "PriTypeInputModeIndicator"
        statusItem?.isVisible = true

        if let button = statusItem?.button {
            applyMode(lastMode ?? .korean, to: button)
        }

        setupMenu()
        refreshInputHealth()
        DebugLogger.log("StatusBarManager: Created status item with menu")
    }

    /// Render the menu-bar indicator natively: a PLAIN title (so the system applies
    /// menu-bar vibrancy — white on a dark bar, and an inverted highlight while the menu
    /// is open) in the system font. The Korean label is "한", matching macOS's own 2-Set
    /// Korean indicator; English mirrors ABC's "A".
    @MainActor
    private func applyMode(_ mode: InputMode, to button: NSStatusBarButton) {
        let isKorean = (mode == .korean)
        button.image = nil
        button.imagePosition = .noImage
        button.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        button.title = isKorean ? "한" : "A"
        button.toolTip = isKorean ? "한국어" : "English"
        button.setAccessibilityLabel(isKorean ? "한국어 입력" : "영문 입력")
    }

    @MainActor
    private func menuImage(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true   // tint to the native menu text color (light/dark/highlight)
        return image
    }

    @MainActor
    private func setupMenu() {
        let menu = NSMenu()

        healthSummaryItem = metadataMenuItem()
        currentModeItem = metadataMenuItem()
        monitorBackendItem = metadataMenuItem()
        accessibilityItem = metadataMenuItem()
        secureInputItem = metadataMenuItem()

        [healthSummaryItem, currentModeItem, monitorBackendItem, accessibilityItem, secureInputItem]
            .compactMap { $0 }
            .forEach(menu.addItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: L10n.settings.title + "...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = menuImage("gearshape")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: L10n.about.title, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = menuImage("info.circle")
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.app.quit, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = menuImage("power")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem?.menu = menu
    }

    @MainActor
    private func metadataMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @MainActor
    public func menuWillOpen(_ menu: NSMenu) {
        refreshInputHealth()
    }

    @MainActor
    private func refreshInputHealth() {
        let mode = lastMode ?? .korean
        let metadata = InputHealthMetadata(
            monitorBackend: monitorBackend,
            accessibilityGranted: AXIsProcessTrusted(),
            secureInputActive: IsSecureEventInputEnabled()
        )

        let health: (title: String, symbol: String)
        if metadata.needsAttention {
            health = (L10n.status.needsAttention, "exclamationmark.triangle")
        } else if metadata.isStarting {
            health = (L10n.status.starting, "clock")
        } else if metadata.secureInputActive {
            health = (L10n.status.secureInputActive, "lock.fill")
        } else if metadata.usesFallback {
            health = (L10n.status.fallbackActive, "arrow.triangle.2.circlepath")
        } else {
            health = (L10n.status.ready, "checkmark.circle")
        }

        healthSummaryItem?.title = "\(L10n.status.inputHealth): \(health.title)"
        healthSummaryItem?.image = menuImage(health.symbol)
        currentModeItem?.title = "\(L10n.status.currentMode): \(modeLabel(mode))"
        monitorBackendItem?.title = "\(L10n.status.monitor): \(monitorLabel(monitorBackend))"
        accessibilityItem?.title = "\(L10n.system.accessibility): \(metadata.accessibilityGranted ? L10n.system.accessibilityGranted : L10n.status.permissionRequired)"
        secureInputItem?.title = "\(L10n.status.systemSecureInput): \(metadata.secureInputActive ? L10n.status.active : L10n.status.inactive)"

        if let button = statusItem?.button {
            button.toolTip = "\(modeLabel(mode)) · \(health.title)"
        }
    }

    @MainActor
    private func modeLabel(_ mode: InputMode) -> String {
        switch mode {
        case .korean: return L10n.status.korean
        case .english: return L10n.status.english
        }
    }

    @MainActor
    private func monitorLabel(_ backend: InputMonitorBackend) -> String {
        switch backend {
        case .starting: return L10n.status.monitorStarting
        case .waitingForAccessibility: return L10n.status.monitorWaitingForPermission
        case .cgEventTap: return "CGEventTap"
        case .iokitFallback: return "IOKit"
        case .unavailable: return L10n.status.monitorUnavailable
        }
    }
    
    // MARK: - Menu Actions
    
    @objc private func openSettings() {
        DebugLogger.log("StatusBarManager: Opening settings")
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
    }
    
    @objc private func showAbout() {
        DebugLogger.log("StatusBarManager: Showing about")
        DispatchQueue.main.async {
            AboutInfo.showAlert()
        }
    }
    
    @MainActor
    @objc private func quitApp() {
        DebugLogger.log("StatusBarManager: Quitting")
        NSApp.terminate(nil)
    }
    
    // MARK: - Status Updates
    
    /// Update the menu-bar indicator to the current mode. The swap is instant, matching
    /// the system input-source indicator (no fade), and uses the native plain-title
    /// rendering set up in `applyMode`.
    public func setMode(_ mode: InputMode) {
        Task { @MainActor [weak self] in
            guard let self, self.lastMode != mode else { return }
            self.lastMode = mode
            if let button = self.statusItem?.button {
                self.applyMode(mode, to: button)
            }
            self.refreshInputHealth()
            DebugLogger.log("StatusBarManager: Mode set to \(mode)")
        }
    }

    /// Report which keyboard monitor owns custom toggle detection. No key or
    /// text payload is accepted, so the health UI cannot expose typed content.
    public func setMonitorBackend(_ backend: InputMonitorBackend) {
        Task { @MainActor [weak self] in
            guard let self, self.monitorBackend != backend else { return }
            self.monitorBackend = backend
            self.refreshInputHealth()
        }
    }
    
    // MARK: - Cleanup
    
    @MainActor
    public func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        healthSummaryItem = nil
        currentModeItem = nil
        monitorBackendItem = nil
        accessibilityItem = nil
        secureInputItem = nil
    }
}
