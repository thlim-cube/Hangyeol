import Cocoa
import Testing
@testable import HangyeolCore

@Suite("Physical key delivery across the IMK bridge")
struct PhysicalKeyDeliveryTests {
    private func key(_ code: UInt16 = 51, at time: TimeInterval,
                     pid: pid_t = 42, replay: Bool = false) -> PhysicalKeyDelivery.Key {
        .init(keyCode: code, modifiers: 0, isRepeat: false,
              timestamp: time, targetPID: pid, isHostReplay: replay)
    }

    private func consume(_ queue: PhysicalKeyDelivery, _ code: UInt16 = 51,
                         at time: TimeInterval = 11, pid: pid_t = 42) -> PhysicalKeyDelivery.Key? {
        queue.consume(keyCode: code, modifiers: 0, isRepeat: false,
                      deliveredAt: time, targetPID: pid)
    }

    @Test("Rewritten delivery timestamps preserve the physical toggle boundary")
    @MainActor
    func physicalOrder() {
        let queue = PhysicalKeyDelivery()
        let coordinator = InputModeCoordinator(activeControllerProvider: { nil },
                                               capsLockOwnershipProvider: { false })
        queue.record(key(at: 9.9))
        queue.record(key(7, at: 10.1))
        queue.record(key(1, at: 10.3))
        for time in [10.0, 10.2] {
            coordinator.requestToggle(source: .customKey, trace: .begin(source: .customKey),
                                      eventTimestamp: time)
        }
        var mode = InputMode.korean
        for (code, expected) in [(UInt16(51), InputMode.korean), (7, .english), (1, .korean)] {
            let original = consume(queue, code)
            #expect(original != nil)
            _ = coordinator.reconcilePendingToggleIfNeeded(through: original?.timestamp) { _, _ in
                mode = mode.toggled
                return true
            }
            #expect(mode == expected)
        }
    }

    @Test("Repeated key identities retain FIFO order and are consumed once")
    func repeatedKeys() {
        let queue = PhysicalKeyDelivery()
        queue.record(key(at: 10))
        queue.record(key(at: 10.1))
        #expect(consume(queue)?.timestamp == 10)
        #expect(consume(queue)?.timestamp == 10.1)
        #expect(consume(queue) == nil)
    }

    @Test("Unmatched host shortcuts can be skipped while PID and expiry remain bounded")
    func unmatchedKeys() {
        let queue = PhysicalKeyDelivery()
        queue.record(key(8, at: 10))
        queue.record(key(at: 10.1))
        #expect(consume(queue, pid: 99) == nil)
        #expect(consume(queue)?.timestamp == 10.1)
        #expect(consume(queue, 8) == nil)
        queue.record(key(at: 10))
        #expect(consume(queue, at: 12.1) == nil)
        queue.record(key(at: 14))
        #expect(consume(queue, at: 13) == nil)
        queue.reset()
        #expect(consume(queue, at: 14) == nil)
    }

    @Test("Host replay identity survives loss of CGEvent user data")
    func hostReplay() {
        let queue = PhysicalKeyDelivery()
        queue.record(key(36, at: 10, replay: true))
        #expect(consume(queue, 36)?.isHostReplay == true)
        #expect(consume(queue, 36) == nil)
    }
}
