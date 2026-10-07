import Foundation

/// Leases a fixed number of slots, each to one holder at a time.
///
/// Each slot stands for one of an account's extra IMAP connections. A search or raw
/// download leases a slot for its whole duration, so no two operations ever share an
/// extra connection and its selected mailbox. The lowest free slot is handed out first,
/// so one-at-a-time use keeps a single extra connection open.
actor ConnectionSlotPool {
    let size: Int
    private var free: Set<Int>
    private var waiters: [CheckedContinuation<Int, Never>] = []

    init(size: Int) {
        precondition(size > 0, "A connection slot pool needs at least one slot")
        self.size = size
        self.free = Set(0..<size)
    }

    /// Number of callers waiting for a slot; for tests.
    var waiterCount: Int { waiters.count }

    func acquire() async -> Int {
        if let slot = free.min() {
            free.remove(slot)
            return slot
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ slot: Int) {
        if waiters.isEmpty {
            free.insert(slot)
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume(returning: slot)
        }
    }
}
