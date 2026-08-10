import Foundation
import Testing
@testable import PriTypeCore

@MainActor
private final class MonitorStatusRecorder {
    private(set) var statuses: [ToggleMonitorStatus] = []

    func record(_ status: ToggleMonitorStatus) {
        statuses.append(status)
    }
}

@Suite("Status Bar Health")
struct StatusBarHealthTests {
    @Test("Launch initializes the status bar exactly once")
    func launchInitializesStatusBarExactlyOnce() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/PriType/main.swift"),
            encoding: .utf8
        )
        let setupCalls = source.components(separatedBy: "StatusBarManager.shared.setup()").count - 1

        #expect(setupCalls == 1)
    }

    @Test("Missing permission or monitor marks health as needing attention")
    func unavailableInputMonitoringNeedsAttention() {
        let missingPermission = InputHealthMetadata(
            monitorBackend: .waitingForAccessibility,
            monitorHasLimitations: false,
            accessibilityGranted: false,
            secureInputActive: false
        )
        let unavailableMonitor = InputHealthMetadata(
            monitorBackend: .unavailable,
            monitorHasLimitations: false,
            accessibilityGranted: true,
            secureInputActive: false
        )

        #expect(missingPermission.needsAttention)
        #expect(unavailableMonitor.needsAttention)
    }

    @Test("Working primary and fallback monitors remain distinguishable")
    func primaryAndFallbackMonitoringMetadata() {
        let primary = InputHealthMetadata(
            monitorBackend: .cgEventTap,
            monitorHasLimitations: false,
            accessibilityGranted: true,
            secureInputActive: false
        )
        let fallback = InputHealthMetadata(
            monitorBackend: .iokitFallback,
            monitorHasLimitations: false,
            accessibilityGranted: true,
            secureInputActive: true
        )

        #expect(!primary.needsAttention)
        #expect(!primary.usesFallback)
        #expect(!fallback.needsAttention)
        #expect(fallback.usesFallback)
        #expect(fallback.secureInputActive)
    }

    @Test("IOKit limitations are mapped to visible degraded health")
    func fallbackLimitationsNeedAttention() {
        let status = ToggleMonitorStatus.running(
            backend: .iokit,
            limitations: [.unsupportedIOKitToggleBinding("Control+Space")]
        )
        let presentation = InputMonitorPresentation(status: status)
        let health = InputHealthMetadata(
            monitorBackend: presentation.backend,
            monitorHasLimitations: !presentation.limitations.isEmpty,
            accessibilityGranted: true,
            secureInputActive: false
        )

        #expect(presentation.backend == .iokitFallback)
        #expect(presentation.limitations == [.unsupportedIOKitToggleBinding("Control+Space")])
        #expect(health.needsAttention)
        #expect(health.usesFallback)
    }

    @Test("Monitor notifications synchronously apply the authoritative store status")
    @MainActor
    func monitorNotificationOrdering() {
        let store = ToggleMonitorStatusStore()
        let recorder = MonitorStatusRecorder()
        let observer = addToggleMonitorStatusObserver(store: store, receive: recorder.record)
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(recorder.statuses == [.stopped])

        #expect(store.reserveStart(.eventTap))
        #expect(recorder.statuses.last == .starting(.eventTap))

        store.markRunning(.eventTap)
        let runningStatus = ToggleMonitorStatus.running(backend: .eventTap, limitations: [])
        #expect(recorder.statuses.last == runningStatus)

        let countBeforeStaleNotification = recorder.statuses.count
        NotificationCenter.default.post(
            name: .toggleMonitorStatusChanged,
            object: store,
            userInfo: ["status": ToggleMonitorStatus.starting(.eventTap)]
        )

        #expect(recorder.statuses.count == countBeforeStaleNotification + 1)
        #expect(recorder.statuses.last == runningStatus)
    }
}
