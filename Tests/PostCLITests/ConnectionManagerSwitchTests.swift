import XCTest
@testable import PostServer

/// A configuration reload replaces the connection manager. The per-account lock and the
/// extra-connection leases must survive that, or an operation that started before the reload
/// and one that starts after it could use the same new connection at the same time.
final class ConnectionManagerSwitchTests: XCTestCase {
    private let configuration = PostConfiguration(servers: ["mail": .init()], httpPort: nil)

    func testLockAndLeasesSurviveAManagerSwitch() async {
        let server = PostServer(configuration: configuration)
        let lock = await server.primaryLock(for: "mail")
        let pool = await server.extraConnectionPool(for: "mail")

        await server.replaceConnectionManager(configuration: configuration)

        let lockAfter = await server.primaryLock(for: "mail")
        let poolAfter = await server.extraConnectionPool(for: "mail")
        XCTAssertTrue(lock === lockAfter)
        XCTAssertTrue(pool === poolAfter)
    }

    func testHolderFromBeforeASwitchStillExcludesLaterCallers() async {
        let server = PostServer(configuration: configuration)
        let lock = await server.primaryLock(for: "mail")
        await lock.lock()

        await server.replaceConnectionManager(configuration: configuration)

        let lockAfter = await server.primaryLock(for: "mail")
        let later = Task {
            await lockAfter.lock()
            await lockAfter.unlock()
        }
        while await lock.waiterCount < 1 {
            await Task.yield()
        }
        let waiting = await lock.waiterCount
        XCTAssertEqual(waiting, 1, "a caller after the switch must wait for the holder from before it")

        await lock.unlock()
        await later.value
    }
}
