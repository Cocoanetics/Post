import XCTest
@testable import PostServer

/// Concurrent requests on one account must return exactly what the same requests return one
/// at a time. Before the per-account lock and the extra connections, a search in one mailbox
/// returned another mailbox's results whenever requests overlapped.
///
/// Runs against a real account and only reads: set POST_LIVE_TEST_SERVER to a server ID from
/// ~/.post.json, optionally POST_LIVE_TEST_MAILBOXES (comma-separated, default INBOX,Sent,Archive).
final class ConcurrentMailboxAccessLiveTests: XCTestCase {
    private struct Snapshot: Equatable, Sendable {
        var searchUIDs: [String: [Int]] = [:]
        var counts: [String: Int] = [:]
        var rawMessages: [String: Data] = [:]
    }

    func testConcurrentRequestsMatchSerialOnes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serverId = environment["POST_LIVE_TEST_SERVER"], !serverId.isEmpty else {
            throw XCTSkip("Set POST_LIVE_TEST_SERVER to run against a real account")
        }
        let mailboxes = (environment["POST_LIVE_TEST_MAILBOXES"] ?? "INBOX,Sent,Archive")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let server = PostServer(configuration: try PostConfiguration.load())

        // One request at a time.
        var baseline = Snapshot()
        for mailbox in mailboxes {
            let uids = try await server.searchMessages(serverId: serverId, mailbox: mailbox, limit: 200).messages.map(\.uid)
            baseline.searchUIDs[mailbox] = uids
            baseline.counts[mailbox] = try await server.countMessages(serverId: serverId, mailbox: mailbox).count ?? -1
            if let uid = uids.min() {
                baseline.rawMessages[mailbox] = try await server.downloadEml(serverId: serverId, uid: uid, mailbox: mailbox)
            }
        }

        // The same requests all at once, mixed with listings on the primary connection.
        for round in 0..<3 {
            let concurrent = try await withThrowingTaskGroup(of: Snapshot.self) { group in
                for mailbox in mailboxes {
                    group.addTask {
                        let uids = try await server.searchMessages(serverId: serverId, mailbox: mailbox, limit: 200).messages.map(\.uid)
                        return Snapshot(searchUIDs: [mailbox: uids])
                    }
                    group.addTask {
                        let count = try await server.countMessages(serverId: serverId, mailbox: mailbox).count ?? -1
                        return Snapshot(counts: [mailbox: count])
                    }
                    if let uid = baseline.searchUIDs[mailbox]?.min() {
                        group.addTask {
                            let data = try await server.downloadEml(serverId: serverId, uid: uid, mailbox: mailbox)
                            return Snapshot(rawMessages: [mailbox: data])
                        }
                    }
                    group.addTask {
                        _ = try await server.listMessages(serverId: serverId, mailbox: mailbox, limit: 3)
                        return Snapshot()
                    }
                }

                var merged = Snapshot()
                for try await part in group {
                    merged.searchUIDs.merge(part.searchUIDs) { $1 }
                    merged.counts.merge(part.counts) { $1 }
                    merged.rawMessages.merge(part.rawMessages) { $1 }
                }
                return merged
            }

            XCTAssertEqual(concurrent.searchUIDs, baseline.searchUIDs, "search results differ in round \(round)")
            XCTAssertEqual(concurrent.counts, baseline.counts, "counts differ in round \(round)")
            XCTAssertEqual(concurrent.rawMessages.mapValues { $0.count }, baseline.rawMessages.mapValues { $0.count }, "raw message sizes differ in round \(round)")
            XCTAssertTrue(concurrent.rawMessages == baseline.rawMessages, "raw messages differ in round \(round)")
        }

        await server.shutdown()
    }
}
