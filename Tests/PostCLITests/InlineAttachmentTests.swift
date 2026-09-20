import Foundation
import XCTest
@testable import PostServer

final class InlineAttachmentTests: XCTestCase {
    func testMarkdownAttachmentReferenceBecomesInlineCID() throws {
        let imageURL = try makeTemporaryFile(named: "code.png")
        let body = "Before\n\n![Payment code](attachment:code.png)\n\nAfter"

        let prepared = try PostServer.prepareAttachments(
            from: [imageURL],
            resolvingReferencesIn: body,
            format: .markdown
        )

        let attachment = try XCTUnwrap(prepared.attachments.first)
        let contentID = try XCTUnwrap(attachment.contentID)
        XCTAssertEqual(
            prepared.body,
            "Before\n\n![Payment code](cid:\(contentID))\n\nAfter"
        )
        XCTAssertEqual(attachment.filename, "code.png")
        XCTAssertTrue(attachment.isInline)
    }

    func testUnreferencedMarkdownAttachmentRemainsRegularAttachment() throws {
        let imageURL = try makeTemporaryFile(named: "code.png")
        let body = "No inline image here."

        let prepared = try PostServer.prepareAttachments(
            from: [imageURL],
            resolvingReferencesIn: body,
            format: .markdown
        )

        let attachment = try XCTUnwrap(prepared.attachments.first)
        XCTAssertEqual(prepared.body, body)
        XCTAssertNil(attachment.contentID)
        XCTAssertFalse(attachment.isInline)
    }

    func testRepeatedReferencesUseTheSameContentID() throws {
        let imageURL = try makeTemporaryFile(named: "code.png")
        let body = "![First](attachment:code.png) ![Second](attachment:code.png)"

        let prepared = try PostServer.prepareAttachments(
            from: [imageURL],
            resolvingReferencesIn: body,
            format: .markdown
        )

        let contentID = try XCTUnwrap(prepared.attachments.first?.contentID)
        XCTAssertEqual(
            prepared.body,
            "![First](cid:\(contentID)) ![Second](cid:\(contentID))"
        )
    }

    func testFilenamePrefixDoesNotRewriteLongerTarget() throws {
        let shortURL = try makeTemporaryFile(named: "code")
        let imageURL = try makeTemporaryFile(named: "code.png")
        let body = "![Payment code](attachment:code.png)"

        let prepared = try PostServer.prepareAttachments(
            from: [shortURL, imageURL],
            resolvingReferencesIn: body,
            format: .markdown
        )

        XCTAssertFalse(prepared.attachments[0].isInline)
        XCTAssertNil(prepared.attachments[0].contentID)
        let contentID = try XCTUnwrap(prepared.attachments[1].contentID)
        XCTAssertTrue(prepared.attachments[1].isInline)
        XCTAssertEqual(prepared.body, "![Payment code](cid:\(contentID))")
    }

    func testReferencesOutsideMarkdownDestinationsRemainUnchanged() throws {
        let imageURL = try makeTemporaryFile(named: "code.png")
        let body = """
        Mention attachment:code.png in prose or `![example](attachment:code.png)` in code.

        ```markdown
        ![example](attachment:code.png)
        ```
        """

        let prepared = try PostServer.prepareAttachments(
            from: [imageURL],
            resolvingReferencesIn: body,
            format: .markdown
        )

        let attachment = try XCTUnwrap(prepared.attachments.first)
        XCTAssertEqual(prepared.body, body)
        XCTAssertNil(attachment.contentID)
        XCTAssertFalse(attachment.isInline)
    }

    func testAttachmentReferenceIsOnlyResolvedForMarkdown() throws {
        let imageURL = try makeTemporaryFile(named: "code.png")
        let body = "<img src=\"attachment:code.png\">"

        let prepared = try PostServer.prepareAttachments(
            from: [imageURL],
            resolvingReferencesIn: body,
            format: .html
        )

        let attachment = try XCTUnwrap(prepared.attachments.first)
        XCTAssertEqual(prepared.body, body)
        XCTAssertNil(attachment.contentID)
        XCTAssertFalse(attachment.isInline)
    }

    func testOnlyReferencedFilesBecomeInline() throws {
        let imageURL = try makeTemporaryFile(named: "code.png")
        let documentURL = try makeTemporaryFile(named: "invoice.pdf")
        let body = "![Payment code](attachment:code.png)"

        let prepared = try PostServer.prepareAttachments(
            from: [imageURL, documentURL],
            resolvingReferencesIn: body,
            format: .markdown
        )

        XCTAssertTrue(prepared.attachments[0].isInline)
        XCTAssertFalse(prepared.attachments[1].isInline)
    }

    func testMarkdownLinkTitleIsPreserved() throws {
        let documentURL = try makeTemporaryFile(named: "invoice.pdf")
        let body = "[Invoice](attachment:invoice.pdf \"Download\")"

        let prepared = try PostServer.prepareAttachments(
            from: [documentURL],
            resolvingReferencesIn: body,
            format: .markdown
        )

        let attachment = try XCTUnwrap(prepared.attachments.first)
        let contentID = try XCTUnwrap(attachment.contentID)
        XCTAssertEqual(prepared.body, "[Invoice](cid:\(contentID) \"Download\")")
        XCTAssertTrue(attachment.isInline)
    }

    private func makeTemporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let fileURL = directory.appendingPathComponent(name)
        try Data("test".utf8).write(to: fileURL)
        return fileURL
    }
}
