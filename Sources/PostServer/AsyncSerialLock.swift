import Foundation

/// A lock for async code: one holder at a time, waiters resume in arrival order.
///
/// IMAP keeps the selected mailbox per connection, and every Post operation selects
/// a mailbox and then awaits further commands. Actors don't serialize work across
/// those suspension points, so without this lock a concurrent request's SELECT can
/// land in between and the commands run in the wrong mailbox. The lock is held for
/// the whole operation, not per command.
actor AsyncSerialLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Number of callers waiting for the lock; for tests.
    var waiterCount: Int { waiters.count }

    func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            // Hand the lock straight to the next waiter; it stays held.
            waiters.removeFirst().resume()
        }
    }
}
