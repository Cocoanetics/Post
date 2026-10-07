import XCTest
@testable import PostServer

final class AsyncSerialLockTests: XCTestCase {
    /// Counts how many holders are inside the critical section at once.
    private actor Occupancy {
        private(set) var current = 0
        private(set) var maximum = 0

        func enter() {
            current += 1
            maximum = max(maximum, current)
        }

        func leave() {
            current -= 1
        }
    }

    private actor Recorder {
        private(set) var values: [Int] = []

        func append(_ value: Int) {
            values.append(value)
        }
    }

    func testHoldersNeverOverlap() async {
        let lock = AsyncSerialLock()
        let occupancy = Occupancy()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await lock.lock()
                    await occupancy.enter()
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    await occupancy.leave()
                    await lock.unlock()
                }
            }
        }

        let maximum = await occupancy.maximum
        XCTAssertEqual(maximum, 1)
    }

    func testWaitersAreServedInArrivalOrder() async {
        let lock = AsyncSerialLock()
        let order = Recorder()
        await lock.lock()

        var tasks: [Task<Void, Never>] = []
        for index in 0..<5 {
            tasks.append(Task {
                await lock.lock()
                await order.append(index)
                await lock.unlock()
            })
            // Queue the waiters one by one so their arrival order is known.
            while await lock.waiterCount < index + 1 {
                await Task.yield()
            }
        }

        await lock.unlock()
        for task in tasks {
            await task.value
        }

        let values = await order.values
        XCTAssertEqual(values, [0, 1, 2, 3, 4])
    }

    func testLockCanBeTakenAgainAfterUnlock() async {
        let lock = AsyncSerialLock()
        await lock.lock()
        await lock.unlock()
        await lock.lock()
        let waiting = await lock.waiterCount
        XCTAssertEqual(waiting, 0)
        await lock.unlock()
    }
}
