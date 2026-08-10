import Foundation
import Testing
@testable import PriTypeCore

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
            accessibilityGranted: false,
            secureInputActive: false
        )
        let unavailableMonitor = InputHealthMetadata(
            monitorBackend: .unavailable,
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
            accessibilityGranted: true,
            secureInputActive: false
        )
        let fallback = InputHealthMetadata(
            monitorBackend: .iokitFallback,
            accessibilityGranted: true,
            secureInputActive: true
        )

        #expect(!primary.needsAttention)
        #expect(!primary.usesFallback)
        #expect(!fallback.needsAttention)
        #expect(fallback.usesFallback)
        #expect(fallback.secureInputActive)
    }
}
