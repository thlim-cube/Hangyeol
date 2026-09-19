import Cocoa
import Testing
@testable import HangyeolCore

@Suite("Chrome navigation physical event ordering")
struct ChromeInputHandoffGateTests {
    final class Harness: @unchecked Sendable {
        var selected = true
        var secure = false
        var pid: pid_t? = 42
        var jobs: [(Double, @Sendable () -> Void)] = []
        var clock = 0.0
        var posted: [CGEvent] = []
        lazy var gate = ChromeInputHandoffGate(selected: { self.selected }, chromePID: { self.pid },
            secure: { self.secure }, schedule: { delay, action in self.jobs.append((self.clock + delay, action)) },
            post: { self.posted.append($0) })
        func run() {
            var count = 0
            while !jobs.isEmpty && count < 1000 {
                jobs.sort { $0.0 < $1.0 }
                let next = jobs.removeFirst(); clock = next.0; next.1(); count += 1
            }
            #expect(jobs.isEmpty)
        }
        func event(_ code: CGKeyCode, _ type: CGEventType = .keyDown, at time: Double = 10.01,
                   flags: CGEventFlags = []) -> CGEvent {
            let value = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)!
            value.type = type; value.timestamp = UInt64(time * 1_000_000_000); value.flags = flags
            return value
        }
        func arm(browser: Bool = false) {
            gate.observeNavigation(event(48, at: 10, flags: browser ? .maskControl : []))
        }
        func capture(at time: Double = 10.01) -> Bool {
            gate.capture(.init(keyCode: 0, modifiers: 0, isRepeat: false,
                timestamp: time, targetPID: 42, isHostReplay: false))
        }
    }

    @Test("Only the exact post-navigation physical key is consumed; later edges replay once in order")
    func orderedReplay() {
        let h = Harness(); h.arm()
        #expect(!h.gate.intercept(h.event(0), type: .keyDown))
        #expect(!h.capture(at: 9.9)) // Older queued IMK callbacks belong to the old field.
        #expect(h.gate.intercept(h.event(0, .keyUp), type: .keyUp))
        #expect(h.gate.intercept(h.event(51), type: .keyDown))
        #expect(h.gate.intercept(h.event(51, .keyUp), type: .keyUp))
        #expect(h.capture())
        #expect(!h.capture())
        h.run()
        #expect(h.posted.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [0,0,51,51])
        #expect(h.posted.map(\.type) == [.keyDown,.keyUp,.keyDown,.keyUp])
        for event in h.posted {
            #expect(event.getIntegerValueField(.eventSourceUserData) == ChromeInputHandoffGate.marker)
            #expect(!h.gate.intercept(event, type: event.type))
        }
    }

    @Test("Missing IMK callback never duplicates the first key or strands its release")
    func noCallback() {
        let h = Harness(); h.arm()
        _ = h.gate.intercept(h.event(0), type: .keyDown)
        #expect(h.gate.intercept(h.event(0, .keyUp), type: .keyUp))
        h.run()
        #expect(h.posted.map(\.type) == [.keyUp])
    }

    @Test("Stopping while waiting releases the swallowed key exactly once and cancels timers")
    func stopping() {
        let h = Harness(); h.arm()
        _ = h.gate.intercept(h.event(0), type: .keyDown)
        #expect(h.capture())
        _ = h.gate.intercept(h.event(0, .keyUp), type: .keyUp)
        h.gate.releasePending(); h.run()
        #expect(h.posted.map(\.type) == [.keyDown,.keyUp])
    }

    @Test("Other sources, apps, secure input and expired boundaries pass through", arguments: 0..<4)
    func scope(reason: Int) {
        let h = Harness(); h.arm()
        if reason == 0 { h.selected = false }
        if reason == 1 { h.pid = nil }
        if reason == 2 { h.secure = true }
        _ = h.gate.intercept(h.event(0, at: reason == 3 ? 12 : 10.01), type: .keyDown)
        #expect(!h.capture())
        #expect(!h.gate.intercept(h.event(0, .keyUp), type: .keyUp))
        h.run(); #expect(h.posted.isEmpty)
    }

    @Test("Clicking a new browser tab preserves its first-key guard; normal field clicks cancel it")
    func clicks() {
        for browser in [false, true] {
            let h = Harness(); h.arm(browser: browser)
            _ = h.gate.intercept(h.event(0, .leftMouseDown), type: .leftMouseDown)
            _ = h.gate.intercept(h.event(0), type: .keyDown)
            #expect(h.capture() == browser)
            h.run(); #expect(h.posted.count == (browser ? 1 : 0))
        }
    }
    @Test("A full pending queue fails open without losing the consumed first key")
    func boundedQueue() {
        let h = Harness(); h.arm()
        _ = h.gate.intercept(h.event(0), type: .keyDown)
        #expect(h.capture())
        for index in 0..<256 {
            #expect(h.gate.intercept(h.event(0, index % 2 == 0 ? .keyUp : .keyDown),
                type: index % 2 == 0 ? .keyUp : .keyDown))
        }
        h.run()
        #expect(h.posted.count == 257)
        #expect(h.posted.first?.type == .keyDown)
        #expect(!h.gate.intercept(h.event(0, .keyUp), type: .keyUp))
    }

    @Test("Modifiers and default host keys keep their original flags and timestamps")
    func hostActions() {
        let h = Harness(); h.arm()
        _ = h.gate.intercept(h.event(0), type: .keyDown)
        #expect(h.capture())
        let events = [h.event(0, .keyUp), h.event(55, .flagsChanged, at: 10.02, flags: .maskCommand),
            h.event(0, at: 10.03, flags: .maskCommand), h.event(36, at: 10.04),
            h.event(117, at: 10.05)]
        for event in events { #expect(h.gate.intercept(event, type: event.type)) }
        h.run()
        #expect(h.posted.count == events.count + 1)
        for (actual, expected) in zip(h.posted.dropFirst(), events) {
            #expect(actual.type == expected.type)
            #expect(actual.flags == expected.flags)
            #expect(actual.timestamp == expected.timestamp)
        }
    }

}
