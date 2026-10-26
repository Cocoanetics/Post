#if canImport(Security)
import XCTest
@testable import PostServer

/// `store` replaces an existing entry internally; it must not re-take its own lock.
final class KeychainCredentialStoreTests: XCTestCase {

    func testStoreTwiceReplacesAndDeleteRemoves() async throws {
        let store = KeychainCredentialStore()
        let id = "post-test-\(UUID().uuidString)"
        addTeardownBlock { try? store.delete(label: id) }

        // Run off the test thread so a deadlock fails the test instead of hanging it.
        let finished = expectation(description: "store/delete complete")
        DispatchQueue.global().async {
            do {
                try store.store(id: id, host: "imap.example.com", port: 993, username: "first", password: "one")
                try store.store(id: id, host: "imap.example.com", port: 993, username: "second", password: "two")
                let found = try store.fullCredentials(forLabel: id)
                XCTAssertEqual(found?.credential.username, "second")
                XCTAssertEqual(found?.password, "two")
                XCTAssertEqual(try store.list().filter { $0.id == id }.count, 1)
                try store.delete(label: id)
                XCTAssertNil(try store.fullCredentials(forLabel: id))
            } catch {
                XCTFail("Keychain operation failed: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 30)
    }
}
#endif
