import Cocoa

/// IMK's legacy bridge can reconstruct NSEvent with a new timestamp and without
/// CGEvent user data. Keep a bounded, in-memory queue of key identities (no text)
/// so a delayed key still observes the mode at its physical input boundary.
final class PhysicalKeyDelivery: @unchecked Sendable {
    static let shared = PhysicalKeyDelivery()

    struct Key: Equatable {
        let keyCode: UInt16
        let modifiers: UInt
        let isRepeat: Bool
        let timestamp: TimeInterval
        let targetPID: pid_t
        let isHostReplay: Bool
    }

    private let lock = NSLock()
    private var keys: [Key] = []
    private static let modifierMask = NSEvent.ModifierFlags([.shift, .control, .option, .command]).rawValue

    func record(_ event: CGEvent, isHostReplay: Bool = false) {
        record(Key(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: UInt(event.flags.rawValue) & Self.modifierMask,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            timestamp: Double(event.timestamp) / 1_000_000_000,
            targetPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)),
            isHostReplay: isHostReplay
        ))
    }

    func record(_ key: Key) {
        lock.withLock {
            keys.removeAll { key.timestamp - $0.timestamp > 2 }
            keys.append(key)
            if keys.count > 128 { keys.removeFirst(keys.count - 128) }
        }
    }

    func consume(_ event: NSEvent, targetPID: pid_t) -> Key? {
        consume(keyCode: event.keyCode,
                modifiers: event.modifierFlags.rawValue & Self.modifierMask,
                isRepeat: event.isARepeat, deliveredAt: event.timestamp,
                targetPID: targetPID)
    }

    func consume(keyCode: UInt16, modifiers: UInt, isRepeat: Bool,
                 deliveredAt: TimeInterval, targetPID: pid_t) -> Key? {
        lock.withLock {
            keys.removeAll { deliveredAt - $0.timestamp > 2 }
            guard let index = keys.firstIndex(where: {
                $0.keyCode == keyCode && $0.modifiers == modifiers
                    && $0.isRepeat == isRepeat && $0.timestamp <= deliveredAt
                    && ($0.targetPID == 0 || $0.targetPID == targetPID)
            }) else { return nil }
            let key = keys[index]
            // Host shortcuts need not reach IMK. Once a later physical key has
            // arrived here, the unmatched earlier records cannot arrive in order.
            keys.removeFirst(index + 1)
            return key
        }
    }

    func reset() {
        lock.withLock { keys.removeAll(keepingCapacity: true) }
    }
}
