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

/// Presentation-only mode expected after a deferred ownership reconciliation.
/// This must never mutate the actual input mode or an IMK client.
protocol PendingInputModePresenting: AnyObject {
    func setPendingMode(_ mode: InputMode?)
}

struct InputModePresentationState: Equatable {
    private(set) var actualMode: InputMode?
    private(set) var pendingMode: InputMode?

    init(actualMode: InputMode? = nil, pendingMode: InputMode? = nil) {
        self.actualMode = actualMode
        self.pendingMode = pendingMode
    }

    var displayedMode: InputMode {
        pendingMode ?? actualMode ?? .korean
    }

    @discardableResult
    mutating func setActualMode(_ mode: InputMode) -> Bool {
        let changed = actualMode != mode || pendingMode != nil
        actualMode = mode
        pendingMode = nil
        return changed
    }

    @discardableResult
    mutating func setPendingMode(_ mode: InputMode?) -> Bool {
        guard pendingMode != mode else { return false }
        pendingMode = mode
        return true
    }
}

/// The currently active system-wide toggle-key monitor.
///
/// This is deliberately a small presentation contract. The monitor remains the
/// owner of its lifecycle; the status bar renders the central monitor status.
enum InputMonitorBackend: Sendable, Equatable {
    case starting
    case waitingForAccessibility
    case cgEventTap
    case iokitFallback
    case unavailable
}

struct InputHealthMetadata: Sendable {
    let monitorBackend: InputMonitorBackend
    let monitorHasLimitations: Bool
    let accessibilityGranted: Bool
    let secureInputActive: Bool

    var needsAttention: Bool {
        !accessibilityGranted || monitorBackend == .unavailable || monitorHasLimitations
    }

    var isStarting: Bool {
        monitorBackend == .starting || monitorBackend == .waitingForAccessibility
    }

    var usesFallback: Bool {
        monitorBackend == .iokitFallback
    }
}

struct InputMonitorPresentation: Equatable {
    let backend: InputMonitorBackend
    let limitations: [ToggleMonitorIssue]

    init(status: ToggleMonitorStatus) {
        switch status {
        case .stopped, .starting, .transitioning:
            backend = .starting
            limitations = []
        case .running(backend: .eventTap, limitations: let issues):
            backend = .cgEventTap
            limitations = issues
        case .running(backend: .iokit, limitations: let issues):
            backend = .iokitFallback
            limitations = issues
        case .unavailable(let issue):
            backend = issue == .accessibilityPermissionRequired
                ? .waitingForAccessibility
                : .unavailable
            limitations = [issue]
        }
    }
}

/// Delivers monitor changes synchronously on the main actor and resolves each
/// notification against the authoritative store snapshot.
@MainActor
func addToggleMonitorStatusObserver(
    store: ToggleMonitorStatusStore = .shared,
    notificationCenter: NotificationCenter = .default,
    receive: @escaping @MainActor @Sendable (ToggleMonitorStatus) -> Void
) -> NSObjectProtocol {
    let token = notificationCenter.addObserver(
        forName: .toggleMonitorStatusChanged,
        object: store,
        queue: .main
    ) { [store] _ in
        MainActor.assumeIsolated {
            receive(store.status)
        }
    }
    receive(store.status)
    return token
}

// MARK: - StatusBarManager

/// Manages a status bar item to show current input mode (한/A) and redacted
/// input-health metadata.
///
/// This class handles all UI updates on the main thread for thread safety.
public final class StatusBarManager: NSObject, StatusBarUpdating, PendingInputModePresenting, NSMenuDelegate, @unchecked Sendable {
    
    // MARK: - Singleton
    
    public static let shared = StatusBarManager()
    
    // MARK: - Properties
    
    private var statusItem: NSStatusItem?
    private var modePresentation = InputModePresentationState()
    private var monitorBackend: InputMonitorBackend = .starting
    private var monitorLimitations: [ToggleMonitorIssue] = []
    private var monitorStatusObserver: NSObjectProtocol?
    private var healthSummaryItem: NSMenuItem?
    private var currentModeItem: NSMenuItem?
    private var monitorBackendItem: NSMenuItem?
    private var monitorLimitationsItem: NSMenuItem?
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
            applyMode(modePresentation.displayedMode, to: button)
        }

        setupMenu()
        observeToggleMonitorStatus()
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
        monitorLimitationsItem = metadataMenuItem()
        accessibilityItem = metadataMenuItem()
        secureInputItem = metadataMenuItem()

        [healthSummaryItem, currentModeItem, monitorBackendItem, monitorLimitationsItem,
         accessibilityItem, secureInputItem]
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
        applyToggleMonitorStatus(ToggleMonitorStatusStore.shared.status)
    }

    @MainActor
    private func refreshInputHealth() {
        let mode = modePresentation.displayedMode
        let metadata = InputHealthMetadata(
            monitorBackend: monitorBackend,
            monitorHasLimitations: !monitorLimitations.isEmpty,
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
        monitorLimitationsItem?.isHidden = monitorLimitations.isEmpty
        monitorLimitationsItem?.title = "\(L10n.status.monitorLimitations): \(monitorLimitations.map(monitorIssueLabel).joined(separator: " · "))"
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

    @MainActor
    private func monitorIssueLabel(_ issue: ToggleMonitorIssue) -> String {
        switch issue {
        case .accessibilityPermissionRequired:
            return L10n.status.permissionRequired
        case .unsupportedIOKitToggleBinding(let binding):
            return String(format: L10n.status.unsupportedIOKitToggleBinding, binding)
        case .unsupportedIOKitHanjaBinding(let binding):
            return String(format: L10n.status.unsupportedIOKitHanjaBinding, binding)
        case .iokitOpenFailed(let code):
            return String(format: L10n.status.iokitOpenFailed, code)
        }
    }

    @MainActor
    private func observeToggleMonitorStatus() {
        guard monitorStatusObserver == nil else { return }
        monitorStatusObserver = addToggleMonitorStatusObserver { [weak self] status in
            self?.applyToggleMonitorStatus(status)
        }
    }

    @MainActor
    private func applyToggleMonitorStatus(_ status: ToggleMonitorStatus) {
        let presentation = InputMonitorPresentation(status: status)
        monitorBackend = presentation.backend
        monitorLimitations = presentation.limitations
        refreshInputHealth()
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
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                applyActualMode(mode)
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.applyActualMode(mode)
        }
    }

    /// Show the mode expected after a deferred system-ownership reconciliation.
    /// This changes presentation only; `setMode` remains the actual-mode writer.
    func setPendingMode(_ mode: InputMode?) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                applyPendingMode(mode)
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.applyPendingMode(mode)
        }
    }

    @MainActor
    private func applyActualMode(_ mode: InputMode) {
        guard modePresentation.setActualMode(mode) else { return }
        updateDisplayedMode()
        DebugLogger.log("StatusBarManager: Mode set to \(mode)")
    }

    @MainActor
    private func applyPendingMode(_ mode: InputMode?) {
        guard modePresentation.setPendingMode(mode) else { return }
        updateDisplayedMode()
    }

    @MainActor
    private func updateDisplayedMode() {
        if let button = statusItem?.button {
            applyMode(modePresentation.displayedMode, to: button)
        }
        refreshInputHealth()
    }

    // MARK: - Cleanup
    
    @MainActor
    public func remove() {
        if let monitorStatusObserver {
            NotificationCenter.default.removeObserver(monitorStatusObserver)
            self.monitorStatusObserver = nil
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        healthSummaryItem = nil
        currentModeItem = nil
        monitorBackendItem = nil
        monitorLimitationsItem = nil
        accessibilityItem = nil
        secureInputItem = nil
    }
}
