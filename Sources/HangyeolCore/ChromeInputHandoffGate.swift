import Cocoa
import Carbon.HIToolbox
/// Chrome can deliver the first key to its retiring IMK context after Tab.
/// Consume only that exact physical key as an activation primer, then return
/// its original down/up edges and following events to macOS in order. No composed text
/// or old client is cached, and host shortcuts retain their normal OS route.
/// Owned by the main run loop, like the IMK controller and event tap.
final class ChromeInputHandoffGate: @unchecked Sendable {
    static let shared = ChromeInputHandoffGate()
    typealias Schedule = (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let selected: () -> Bool
    private let chromePID: () -> pid_t?
    private let secure: () -> Bool
    private let schedule: Schedule
    private let post: (CGEvent) -> Void
    init(selected: @escaping () -> Bool = ChromeInputHandoffGate.isSelected,
         chromePID: @escaping () -> pid_t? = {
             let app = NSWorkspace.shared.frontmostApplication
             return app?.bundleIdentifier == "com.google.Chrome" ? app?.processIdentifier : nil
         }, secure: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         schedule: @escaping Schedule = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }, post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.selected = selected; self.chromePID = chromePID; self.secure = secure
        self.schedule = schedule; self.post = post
    }
    static let marker: Int64 = 0x4847494d4551
    private enum State { case idle, armed, priming, waiting, draining }
    private var state = State.idle
    private var first: CGEvent?
    private var queue: [CGEvent] = []
    private var generation = 0
    private var firstPID: pid_t = 0
    private var browserNavigation = false
    private var armedAt: TimeInterval = 0
    static func isSelected() -> Bool {
        guard let reference = TISCopyCurrentKeyboardInputSource() else { return false }
        let source = reference.takeRetainedValue()
        func property(_ key: CFString) -> String? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        return SelectedInputSourceClassifier.classify(
            inputSourceID: property(kTISPropertyInputSourceID),
            bundleID: property(kTISPropertyBundleID)
        ) == .hangyeol
    }
    func releasePending() {
        generation += 1
        if state == .waiting, let first { queue.insert(first, at: 0) }
        first = nil
        let pending = queue
        queue.removeAll(keepingCapacity: true)
        state = .idle
        for event in pending {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            post(event)
        }
    }
    func observeNavigation(_ event: CGEvent) {
        guard state == .idle || state == .armed,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              chromePID() != nil else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let browser = code == 48 && event.flags.contains(.maskControl)
            || [17, 13].contains(code) && event.flags.contains(.maskCommand)
        if code == 48 || browser {
            guard selected(), !secure() else { state = .idle; return }
            state = .armed; browserNavigation = browser
            armedAt = Double(event.timestamp) / 1_000_000_000
        }
    }
    func intercept(_ event: CGEvent, type: CGEventType) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
        if state == .priming || state == .waiting || state == .draining {
            guard let copy = event.copy() else { releasePending(); return false }
            queue.append(copy)
            if queue.count >= 256 { releasePending() }
            return true
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if !browserNavigation { state = .idle }
            return false
        }
        guard state == .armed, type == .keyDown else { return false }
        guard Double(event.timestamp) / 1_000_000_000 - armedAt < (browserNavigation ? 5 : 1), selected() else {
            state = .idle
            return false
        }
        guard chromePID() != nil, !secure() else { state = .idle; return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code < 51, ![36,48,49].contains(code), event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty else { return false }
        let config = ConfigurationManager.shared
        guard ShortcutBindingRouter.routeRegularKey(keyCode: code, modifiers: event.flags.rawValue,
            toggleBinding: config.toggleKeyBinding, hanjaBinding: config.hanjaKeyBinding,
            hangyeolToggleEnabled: !config.capsLockInputSourceSwitchEnabled) == nil,
            let copy = event.copy() else { return false }
        first = copy; firstPID = chromePID() ?? 0
        state = .priming; generation += 1
        let ticket = generation
        schedule(0.1) { [self] in
            guard generation == ticket, state == .priming else { return }
            first = nil; state = .draining; drain()
        }
        return false
    }
    func capture(_ key: PhysicalKeyDelivery.Key) -> Bool {
        guard state == .priming, let first,
              key.keyCode == UInt16(first.getIntegerValueField(.keyboardEventKeycode)),
              abs(key.timestamp - Double(first.timestamp) / 1_000_000_000) < 0.000001,
              chromePID() == firstPID else { return false }
        state = .waiting
        let ticket = generation
        schedule(browserNavigation ? 0.06 : 0.025) { [self] in
            guard generation == ticket, state == .waiting, let first = self.first else { return }
            queue.insert(first, at: 0)
            self.first = nil; state = .draining; drain()
        }
        return true
    }
    private func drain() {
        guard !queue.isEmpty else { state = .idle; return }
        let event = queue.removeFirst()
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        post(event)
        let ticket = generation
        schedule(0.002) { [self] in
            guard generation == ticket else { return }
            drain()
        }
    }
}
