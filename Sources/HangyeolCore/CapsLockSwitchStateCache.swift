import Foundation

/// In-memory snapshot of macOS's Caps Lock input-source ownership setting.
///
/// Keyboard monitor callbacks read `value` for every event, so the preference
/// reader must stay outside that hot path. Explicit refresh boundaries update
/// the snapshot when macOS settings may have changed.
final class CapsLockSwitchStateCache: @unchecked Sendable {
    struct Change: Equatable, Sendable {
        let previousValue: Bool
        let currentValue: Bool
    }

    private let stateLock = NSLock()
    private let refreshLock = NSLock()
    private let reader: @Sendable () -> Bool
    private var cachedValue: Bool

    init(reader: @escaping @Sendable () -> Bool) {
        self.reader = reader
        self.cachedValue = reader()
    }

    var value: Bool {
        stateLock.withLock { cachedValue }
    }

    /// Re-read the system preference and atomically replace the snapshot.
    /// Refreshes are serialized so an older read cannot overwrite a newer one,
    /// while hot-path getters remain available during the preference I/O.
    @discardableResult
    func refresh() -> Change? {
        refreshLock.withLock {
            let currentValue = reader()
            return stateLock.withLock {
                let previousValue = cachedValue
                cachedValue = currentValue

                guard previousValue != currentValue else { return nil }
                return Change(previousValue: previousValue, currentValue: currentValue)
            }
        }
    }
}
