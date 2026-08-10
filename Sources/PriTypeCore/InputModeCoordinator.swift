import Foundation
import Carbon.HIToolbox

/// Coordinates PriType-owned language toggles.
///
/// Custom toggle keys must not select the real macOS ABC input source. Doing so
/// hands the active text session to another input source and reintroduces
/// first-key races. This coordinator keeps the custom toggle path inside
/// PriType: key monitor -> controller -> composer.
public final class InputModeCoordinator: @unchecked Sendable {
    public static let shared = InputModeCoordinator()

    private static let priTypeInputSourceID = "com.pritype.inputmethod.v2"

    public enum ToggleSource: Sendable {
        case customKey
        case iokitFallback

        var diagnosticLabel: StaticString {
            switch self {
            case .customKey: "event_tap"
            case .iokitFallback: "iokit"
            }
        }
    }

    private var ownershipTracker = InputModeOwnershipTracker()
    private var ownershipObserverTokens: [NSObjectProtocol] = []

    private init() {}

    /// Start process-wide observation of real ownership and TIS selection
    /// boundaries. Observers only record pending work; they never write mode state
    /// or commit a client's composition.
    public func startSystemOwnershipMonitoring() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.startSystemOwnershipMonitoring()
            }
            return
        }
        guard ownershipObserverTokens.isEmpty else { return }

        _ = ownershipTracker.observe(Self.currentOwnershipSnapshot())

        ownershipObserverTokens.append(NotificationCenter.default.addObserver(
            forName: .capsLockInputSourceSwitchChanged,
            object: ConfigurationManager.shared,
            queue: .main
        ) { [weak self] notification in
            let macOSOwnsSwitching = notification.userInfo?["isEnabled"] as? Bool
                ?? ConfigurationManager.shared.capsLockInputSourceSwitchEnabled
            self?.observe(InputModeOwnershipSnapshot(
                macOSOwnsSwitching: macOSOwnsSwitching,
                selectedInputSource: Self.currentSelectedInputSourceKind()
            ))
        })

        ownershipObserverTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.observeCurrentSystemOwnership()
        })
    }

    public func requestToggle(source: ToggleSource, trace: ToggleLatencyTrace) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.requestToggle(source: source, trace: trace)
            }
            return
        }

        trace.mark(.mainExecution)

        if PriTypeInputController.sharedController != nil {
            observePriTypeActivation()
        } else {
            observeCurrentSystemOwnership()
        }

        guard !ConfigurationManager.shared.capsLockInputSourceSwitchEnabled else {
            DebugLogger.event("toggle.ignored", metadata: [
                .state("source", source.diagnosticLabel),
                .state("reason", "caps_lock_owns_switching")
            ])
            trace.mark(.ignored)
            return
        }

        guard let controller = PriTypeInputController.sharedController else {
            DebugLogger.event("toggle.ignored", metadata: [
                .state("source", source.diagnosticLabel),
                .state("reason", "no_active_controller")
            ])
            trace.mark(.ignored)
            return
        }

        controller.performPriTypeModeTransition(source: source, trace: trace)
    }

    /// An active IMK callback is stronger evidence than a potentially delayed TIS
    /// query that PriType is the selected source. Repeated activation with unchanged
    /// ownership is a no-op in `InputModeOwnershipTracker`.
    func observePriTypeActivation() {
        assert(Thread.isMainThread, "Input-mode ownership observation must run on the main thread")
        observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: ConfigurationManager.shared.capsLockInputSourceSwitchEnabled,
            selectedInputSource: .priType
        ))
    }

    /// Apply pending normalization only after the controller has passed its secure
    /// input gate. This prevents a preference/input-source callback from writing to
    /// a password field.
    @discardableResult
    func reconcileSystemOwnershipIfNeeded(for controller: PriTypeInputController) -> Bool {
        assert(Thread.isMainThread, "Input-mode ownership reconciliation must run on the main thread")
        guard ownershipTracker.hasPendingKoreanReconciliation else { return false }
        guard controller.reconcileMacOSOwnedInputSourceBoundary() else { return false }

        ownershipTracker.markReconciled()
        DebugLogger.event("input_mode.ownership_reconciled", metadata: [
            .state("mode", "korean")
        ])
        return true
    }

    private func observeCurrentSystemOwnership() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.observeCurrentSystemOwnership()
            }
            return
        }
        observe(Self.currentOwnershipSnapshot())
    }

    private func observe(_ snapshot: InputModeOwnershipSnapshot) {
        guard let boundary = ownershipTracker.observe(snapshot) else { return }
        DebugLogger.event("input_mode.ownership_boundary", metadata: [
            .state("boundary", boundary.diagnosticLabel)
        ])
    }

    private static func currentOwnershipSnapshot() -> InputModeOwnershipSnapshot {
        InputModeOwnershipSnapshot(
            macOSOwnsSwitching: ConfigurationManager.shared.capsLockInputSourceSwitchEnabled,
            selectedInputSource: currentSelectedInputSourceKind()
        )
    }

    private static func currentSelectedInputSourceKind() -> SelectedInputSourceKind {
        guard let sourceReference = TISCopyCurrentKeyboardInputSource() else {
            return .unavailable
        }
        let source = sourceReference.takeRetainedValue()
        guard let identifierPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return .unavailable
        }
        let identifier = Unmanaged<CFString>
            .fromOpaque(identifierPointer)
            .takeUnretainedValue() as String
        return identifier == priTypeInputSourceID ? .priType : .other
    }
}
