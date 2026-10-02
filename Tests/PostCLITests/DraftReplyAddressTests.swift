import PostServer
import XCTest
@testable import post

final class DraftReplyAddressTests: XCTestCase {
    func testExplicitRecipientDoesNotBecomeSenderWhenReplyingToSentMessage() throws {
        let addresses = try PostCLI.Draft.replyAddresses(
            for: message(
                from: "oliver@example.com",
                to: ["sylvia@example.com"],
                cc: nil
            ),
            accountAddress: "oliver@example.com",
            from: nil,
            to: "sylvia@example.com",
            cc: nil,
            replyAll: false
        )

        XCTAssertEqual(addresses.from, "oliver@example.com")
        XCTAssertEqual(addresses.to, "sylvia@example.com")
    }

    func testReplyToSentMessageKeepsOriginalSenderAndRecipients() throws {
        let addresses = try PostCLI.Draft.replyAddresses(
            for: message(
                from: "Oliver <oliver@example.com>",
                to: ["Sylvia <sylvia@example.com>", "other@example.com"],
                cc: ["copy@example.com"]
            ),
            accountAddress: "oliver@example.com",
            from: nil,
            to: nil,
            cc: nil,
            replyAll: false
        )

        XCTAssertEqual(addresses.from, "Oliver <oliver@example.com>")
        XCTAssertEqual(addresses.to, "Sylvia <sylvia@example.com>, other@example.com")
        XCTAssertNil(addresses.cc)
    }

    func testReplyAllToSentMessageKeepsOriginalCCRecipients() throws {
        let addresses = try PostCLI.Draft.replyAddresses(
            for: message(
                from: "oliver@example.com",
                to: ["sylvia@example.com"],
                cc: ["copy@example.com"]
            ),
            accountAddress: "OLIVER@example.com",
            from: nil,
            to: nil,
            cc: nil,
            replyAll: true
        )

        XCTAssertEqual(addresses.from, "oliver@example.com")
        XCTAssertEqual(addresses.to, "sylvia@example.com")
        XCTAssertEqual(addresses.cc, "copy@example.com")
    }

    func testReplyToReceivedMessageRetainsExistingAddressDerivation() throws {
        let addresses = try PostCLI.Draft.replyAddresses(
            for: message(
                from: "sender@example.com",
                to: ["me@example.com"],
                cc: ["copy@example.com"]
            ),
            accountAddress: "me@example.com",
            from: nil,
            to: nil,
            cc: nil,
            replyAll: true
        )

        XCTAssertEqual(addresses.from, "me@example.com")
        XCTAssertEqual(addresses.to, "sender@example.com")
        XCTAssertEqual(addresses.cc, "copy@example.com")
    }

    private func message(from: String, to: [String], cc: [String]?) -> MessageDetail {
        MessageDetail(
            uid: 1,
            from: from,
            to: to,
            cc: cc,
            subject: "Subject",
            date: "2026-10-01T00:00:00.000Z",
            textBody: nil,
            htmlBody: nil,
            attachments: []
        )
    }
}
