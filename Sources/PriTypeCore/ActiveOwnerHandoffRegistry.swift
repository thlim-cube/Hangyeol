import Foundation

/// Tracks one process-wide active owner and retires it before installing a different
/// owner. InputMethodKit creates a controller per client input session, so controller
/// instance storage alone cannot enforce this ordering.
final class ActiveOwnerHandoffRegistry<Owner: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedOwner: Owner?
    private weak var pendingOwner: Owner?
    private var claimGeneration: UInt64 = 0

    var owner: Owner? {
        lock.withLock { storedOwner }
    }

    func claim(_ owner: Owner, retire: (Owner) -> Void) {
        let (previous, generation) = lock.withLock {
            // Record every claim intent, including a claim by the currently visible
            // owner. A retire callback can synchronously trigger a newer activation;
            // only that newest claim may publish after callbacks unwind.
            claimGeneration &+= 1
            pendingOwner = storedOwner === owner ? nil : owner
            return (storedOwner, claimGeneration)
        }
        guard previous !== owner else { return }

        if let previous {
            retire(previous)
        }
        lock.withLock {
            guard claimGeneration == generation, pendingOwner === owner else { return }
            storedOwner = owner
            pendingOwner = nil
        }
    }

    func release(_ owner: Owner) {
        lock.withLock {
            if pendingOwner === owner {
                // The claimant was released before its retire callback returned. Its
                // predecessor is already being retired, so neither owner remains
                // active and the outer claim must not publish after unwinding.
                claimGeneration &+= 1
                pendingOwner = nil
                storedOwner = nil
                return
            }
            guard storedOwner === owner else { return }
            storedOwner = nil
        }
    }
}
