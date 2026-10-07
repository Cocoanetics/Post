import XCTest
import SwiftMail
@testable import PostServer

/// Listing, `post fetch`, attachment downloads and PDF export now download only the parts they
/// use instead of every part. Their results must equal what full downloads produce.
///
/// Runs against a real account and only reads: set POST_LIVE_TEST_SERVER to a server ID from
/// ~/.post.json; optionally POST_LIVE_TEST_LEAN_MAILBOX (default INBOX), and
/// POST_LIVE_TEST_ATTACHMENT=<mailbox>:<uid> for a message with an attachment.
final class LeanFetchLiveTests: XCTestCase {
    private func liveServerID() throws -> String {
        guard let serverId = ProcessInfo.processInfo.environment["POST_LIVE_TEST_SERVER"], !serverId.isEmpty else {
            throw XCTSkip("Set POST_LIVE_TEST_SERVER to run against a real account")
        }
        return serverId
    }

    /// A separate connection that downloads messages the previous way: every part.
    private func referenceServer(for serverId: String, configuration: PostConfiguration) async throws -> IMAPServer {
        let credentials = try configuration.resolveCredentials(forServer: serverId)
        let server = IMAPServer(host: credentials.host, port: credentials.port)
        try await server.connect()
        try await server.login(username: credentials.username, password: credentials.password)
        return server
    }

    private func fullMessages(_ set: MessageIdentifierSet<some MessageIdentifier>, using server: IMAPServer) async throws -> [Message] {
        var messages: [Message] = []
        for try await message in server.fetchMessages(using: set) {
            messages.append(message)
        }
        return messages
    }

    /// JSON with sorted keys, for comparing values that aren't Equatable.
    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testListingAndFetchMatchFullDownloads() async throws {
        let serverId = try liveServerID()
        let mailbox = ProcessInfo.processInfo.environment["POST_LIVE_TEST_LEAN_MAILBOX"] ?? "INBOX"
        let configuration = try PostConfiguration.load()
        let post = PostServer(configuration: configuration)
        let reference = try await referenceServer(for: serverId, configuration: configuration)

        let selection = try await reference.selectMailbox(mailbox)
        guard let latest = selection.latest(8) else {
            throw XCTSkip("\(mailbox) is empty")
        }
        let full = try await fullMessages(latest, using: reference)

        // Listing: header data only.
        let listed = try await post.listMessages(serverId: serverId, mailbox: mailbox, limit: 8)
        var expectedHeaders: [MessageHeader] = []
        for message in full {
            expectedHeaders.append(await post.messageHeader(from: message))
        }
        XCTAssertEqual(
            try listed.sorted { $0.uid > $1.uid }.map { try json($0) },
            try expectedHeaders.sorted { $0.uid > $1.uid }.map { try json($0) }
        )

        // post fetch: text and HTML bodies only, additional headers included.
        let uids = full.compactMap(\.uid).map { String($0.value) }.joined(separator: ",")
        let details = try await post.fetchMessage(serverId: serverId, uids: uids, mailbox: mailbox)
        var expectedDetails: [MessageDetail] = []
        for message in full {
            expectedDetails.append(await post.messageDetail(from: message))
        }
        XCTAssertEqual(details.count, expectedDetails.count)
        // A message may have nothing left after the noise filter, but the sample must have some.
        XCTAssertTrue(details.contains { !($0.additionalHeaders ?? [:]).isEmpty }, "additional headers missing")
        XCTAssertEqual(
            try details.sorted { $0.uid < $1.uid }.map { try json($0) },
            try expectedDetails.sorted { $0.uid < $1.uid }.map { try json($0) }
        )

        await post.shutdown()
        try? await reference.disconnect()
    }

    /// A wide UID range must go to the server as one compact FETCH, not be expanded into one
    /// request per 200 UIDs.
    func testWideRangeFetchesOnlyExistingMessages() async throws {
        let serverId = try liveServerID()
        let mailbox = ProcessInfo.processInfo.environment["POST_LIVE_TEST_LEAN_MAILBOX"] ?? "INBOX"
        let post = PostServer(configuration: try PostConfiguration.load())

        let newest = try await post.listMessages(serverId: serverId, mailbox: mailbox, limit: 3).map(\.uid).sorted()
        guard let lowest = newest.first, let highest = newest.last else {
            throw XCTSkip("\(mailbox) is empty")
        }

        let start = ContinuousClock.now
        let details = try await post.fetchMessage(serverId: serverId, uids: "\(lowest)-\(highest + 1_000_000)", mailbox: mailbox)
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(details.map(\.uid).sorted(), newest)
        XCTAssertLessThan(elapsed, .seconds(30))

        await post.shutdown()
    }

    func testAttachmentMatchesFullDownload() async throws {
        let serverId = try liveServerID()
        guard let spec = ProcessInfo.processInfo.environment["POST_LIVE_TEST_ATTACHMENT"],
              let separator = spec.lastIndex(of: ":"),
              let uid = Int(spec[spec.index(after: separator)...]) else {
            throw XCTSkip("Set POST_LIVE_TEST_ATTACHMENT=<mailbox>:<uid> for a message with an attachment")
        }
        let mailbox = String(spec[..<separator])
        let configuration = try PostConfiguration.load()
        let post = PostServer(configuration: configuration)
        let reference = try await referenceServer(for: serverId, configuration: configuration)

        _ = try await reference.selectMailbox(mailbox)
        let full = try await fullMessages(MessageIdentifierSet<UID>(UID(UInt32(uid))), using: reference)
        let expectedPart = try XCTUnwrap(full.first?.attachments.first, "message \(uid) has no attachment")
        let expectedData = try XCTUnwrap(expectedPart.decodedData() ?? expectedPart.data)

        let downloaded = try await post.downloadAttachment(serverId: serverId, uid: uid, mailbox: mailbox)
        XCTAssertEqual(downloaded.filename, expectedPart.filename ?? expectedPart.suggestedFilename)
        XCTAssertEqual(downloaded.contentType, expectedPart.contentType)
        XCTAssertEqual(downloaded.size, expectedData.count)
        XCTAssertTrue(downloaded.data == expectedData.base64EncodedString(), "attachment data differs")

        await post.shutdown()
        try? await reference.disconnect()
    }
}
