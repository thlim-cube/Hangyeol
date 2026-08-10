import Foundation

/// Tracks one process-wide active owner and retires it before installing a different
/// owner. InputMethodKit creates a controller per client input session, so controller
/// instance storage alone cannot enforce this ordering.
final class ActiveOwnerHandoffRegistry<Owner: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedOwner: Owner?

    var owner: Owner? {
        lock.withLock { storedOwner }
    }

    func claim(_ owner: Owner, retire: (Owner) -> Void) {
        let previous = lock.withLock { storedOwner }
        guard previous !== owner else { return }

        if let previous {
            retire(previous)
        }
        lock.withLock {
            storedOwner = owner
        }
    }

    func release(_ owner: Owner) {
        lock.withLock {
            guard storedOwner === owner else { return }
            storedOwner = nil
        }
    }
}
