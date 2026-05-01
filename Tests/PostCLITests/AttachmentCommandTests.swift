import XCTest
@testable import post

final class AttachmentCommandTests: XCTestCase {
    func testCIDSelectorParsesSuccessfully() throws {
        let parsed = try PostCLI.Attachment.parse([
            "14434",
            "--cid", "C159B852-FFB2-4456-9D77-C4476E2E2D2C"
        ])

        XCTAssertEqual(parsed.uid, 14434)
        XCTAssertEqual(parsed.cid, "C159B852-FFB2-4456-9D77-C4476E2E2D2C")
        XCTAssertNil(parsed.filename)
    }

    func testFilenameAndCIDAreMutuallyExclusive() {
        XCTAssertThrowsError(try PostCLI.Attachment.parse([
            "14434",
            "--filename", "invoice.pdf",
            "--cid", "C159B852-FFB2-4456-9D77-C4476E2E2D2C"
        ])) { error in
            let message = PostCLI.Attachment.message(for: error)
            XCTAssertTrue(message.contains("Use either --filename or --cid, not both."))
        }
    }
}
