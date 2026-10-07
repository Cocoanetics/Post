import XCTest
@testable import PostServer

final class ConnectionSlotPoolTests: XCTestCase {
    /// Tracks which slots are leased and whether any slot was leased twice at once.
    private actor Leases {
        private var held: Set<Int> = []
        private(set) var doubleLeases = 0
        private(set) var maximum = 0

        func take(_ slot: Int) {
            if held.contains(slot) {
                doubleLeases += 1
            }
            held.insert(slot)
            maximum = max(maximum, held.count)
        }

        func give(_ slot: Int) {
            held.remove(slot)
        }
    }

    func testNoSlotIsLeasedTwiceAtOnce() async {
        let pool = ConnectionSlotPool(size: 2)
        let leases = Leases()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let slot = await pool.acquire()
                    await leases.take(slot)
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    await leases.give(slot)
                    await pool.release(slot)
                }
            }
        }

        let doubleLeases = await leases.doubleLeases
        let maximum = await leases.maximum
        XCTAssertEqual(doubleLeases, 0)
        XCTAssertLessThanOrEqual(maximum, 2)
    }

    func testOneAtATimeUseKeepsTheFirstSlot() async {
        let pool = ConnectionSlotPool(size: 2)
        for _ in 0..<3 {
            let slot = await pool.acquire()
            XCTAssertEqual(slot, 0)
            await pool.release(slot)
        }
    }

    func testWaiterReceivesTheReleasedSlot() async {
        let pool = ConnectionSlotPool(size: 1)
        let first = await pool.acquire()

        let waiter = Task { await pool.acquire() }
        while await pool.waiterCount < 1 {
            await Task.yield()
        }

        await pool.release(first)
        let second = await waiter.value
        XCTAssertEqual(second, first)
        await pool.release(second)
    }
}
