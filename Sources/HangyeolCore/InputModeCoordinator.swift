import Foundation
import Carbon.HIToolbox

/// Records a physical toggle intent on the monitoring callback before a later
/// main-queue turn can be overtaken by the first keyDown. The callback may only
/// enqueue through `InputModeCoordinator.requestToggle`; client writes remain on
/// the coordinator's main-thread drain path.
enum PhysicalToggleIntentDelivery {
    static func record(
        _ trace: ToggleLatencyTrace,
        using callback: (@Sendable (ToggleLatencyTrace) -> Void)?
    ) {
        callback?(trace)
    }
}

/// A physical custom-toggle press is recorded before the coordinator hops to the
/// main queue. Keeping the intent outside any controller lets a short IMK handoff
/// finish without losing the user's mode change.
private final class PendingInputModeToggleQueue: @unchecked Sendable {
    struct Intent {
        let id: UInt64
        let source: InputModeCoordinator.ToggleSource
        let trace: ToggleLatencyTrace
    }

    private struct Entry {
        let intent: Intent
        var didReachMain = false
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var entries: [Entry] = []

    func append(source: InputModeCoordinator.ToggleSource, trace: ToggleLatencyTrace) {
        lock.withLock {
            nextID &+= 1
            entries.append(Entry(intent: Intent(
                id: nextID,
                source: source,
                trace: trace
            )))
        }
    }

    func firstForMainProcessing() -> (intent: Intent, shouldMarkMain: Bool)? {
        lock.withLock {
            guard !entries.isEmpty else { return nil }
            let shouldMarkMain = !entries[0].didReachMain
            entries[0].didReachMain = true
            return (entries[0].intent, shouldMarkMain)
        }
    }

    func remove(id: UInt64) {
        lock.withLock {
            guard entries.first?.intent.id == id else { return }
            entries.removeFirst()
        }
    }
}

/// Coordinates Hangyeol-owned language toggles.
///
/// Custom toggle keys must not select the real macOS ABC input source. Doing so
/// hands the active text session to another input source and reintroduces
/// first-key races. This coordinator keeps the custom toggle path inside
/// Hangyeol: key monitor -> controller -> composer.
public final class InputModeCoordinator: @unchecked Sendable {
    public static let shared = InputModeCoordinator()

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
    private var isReconcilingToggle = false
    private let pendingToggleQueue: PendingInputModeToggleQueue
    private let activeControllerProvider: () -> HangyeolInputController?
    private let capsLockOwnershipProvider: () -> Bool

    init(
        activeControllerProvider: @escaping () -> HangyeolInputController? = {
            HangyeolInputController.sharedController
        },
        capsLockOwnershipProvider: @escaping () -> Bool = {
            ConfigurationManager.shared.capsLockInputSourceSwitchEnabled
        }
    ) {
        pendingToggleQueue = PendingInputModeToggleQueue()
        self.activeControllerProvider = activeControllerProvider
        self.capsLockOwnershipProvider = capsLockOwnershipProvider
    }

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

        observe(Self.currentOwnershipSnapshot())

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

    public func requestToggle(source: ToggleSource) {
        requestToggle(source: source, trace: .begin(source: source))
    }

    public func requestToggle(source: ToggleSource, trace: ToggleLatencyTrace) {
        pendingToggleQueue.append(source: source, trace: trace)

        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.drainPendingToggleUsingActiveController()
            }
            return
        }

        drainPendingToggleUsingActiveController()
    }

    private func drainPendingToggleUsingActiveController() {
        assert(Thread.isMainThread, "Custom mode toggles must be drained on the main thread")

        if activeControllerProvider() != nil {
            observeHangyeolActivation()
        } else {
            observeCurrentSystemOwnership()
        }

        if let controller = activeControllerProvider() {
            _ = reconcilePendingToggleIfNeeded(for: controller)
            return
        }

        DebugLogger.event("toggle.deferred", metadata: [
            .state("reason", "controller_handoff")
        ])
        // Keep the physical intent queued. A new IMK client, such as a freshly
        // opened window, must apply it on the next activate/keyDown instead of
        // discarding the press because the previous field still owns the session.
    }

    /// Apply every queued physical toggle before the current controller interprets
    /// its first safe key. A failed/reentrant transaction leaves the head intent in
    /// place for the next controller or input boundary.
    @discardableResult
    func reconcilePendingToggleIfNeeded(for controller: HangyeolInputController) -> Bool {
        guard activeControllerProvider() === controller else { return false }
        return reconcilePendingToggleIfNeeded { source, trace in
            controller.applyPendingHangyeolModeTransition(source: source, trace: trace)
        }
    }

    @discardableResult
    func reconcilePendingToggleIfNeeded(
        perform: (ToggleSource, ToggleLatencyTrace) -> Bool
    ) -> Bool {
        assert(Thread.isMainThread, "Custom mode toggles must be reconciled on the main thread")
        guard !isReconcilingToggle else { return false }
        isReconcilingToggle = true
        defer { isReconcilingToggle = false }
        var appliedAny = false

        while let pending = pendingToggleQueue.firstForMainProcessing() {
            if pending.shouldMarkMain {
                pending.intent.trace.mark(.mainExecution)
            }

            if capsLockOwnershipProvider() {
                DebugLogger.event("toggle.ignored", metadata: [
                    .state("source", pending.intent.source.diagnosticLabel),
                    .state("reason", "caps_lock_owns_switching")
                ])
                pending.intent.trace.mark(.ignored)
                pendingToggleQueue.remove(id: pending.intent.id)
                continue
            }

            guard perform(pending.intent.source, pending.intent.trace) else {
                DebugLogger.event("toggle.deferred", metadata: [
                    .state("source", pending.intent.source.diagnosticLabel),
                    .state("reason", "input_boundary_changed")
                ])
                return appliedAny
            }

            pendingToggleQueue.remove(id: pending.intent.id)
            appliedAny = true
        }
        return appliedAny
    }

    /// An active IMK callback is stronger evidence than a potentially delayed TIS
    /// query that Hangyeol is the selected source. Repeated activation with unchanged
    /// ownership is a no-op in `InputModeOwnershipTracker`.
    func observeHangyeolActivation() {
        assert(Thread.isMainThread, "Input-mode ownership observation must run on the main thread")
        observe(InputModeOwnershipSnapshot(
            macOSOwnsSwitching: ConfigurationManager.shared.capsLockInputSourceSwitchEnabled,
            selectedInputSource: .hangyeol
        ))
    }

    /// Apply pending normalization only after the controller has passed its secure
    /// input gate. This prevents a preference/input-source callback from writing to
    /// a password field.
    @discardableResult
    func reconcileSystemOwnershipIfNeeded(for controller: HangyeolInputController) -> Bool {
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

    func observe(_ snapshot: InputModeOwnershipSnapshot) {
        assert(Thread.isMainThread, "Input-mode ownership observation must run on the main thread")
        let boundary = ownershipTracker.observe(snapshot)

        guard let boundary else { return }
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
        return SelectedInputSourceClassifier.classify(
            inputSourceID: inputSourceStringProperty(source, key: kTISPropertyInputSourceID),
            bundleID: inputSourceStringProperty(source, key: kTISPropertyBundleID)
        )
    }

    private static func inputSourceStringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
