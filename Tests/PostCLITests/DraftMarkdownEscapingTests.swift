import XCTest
@testable import post

final class DraftMarkdownEscapingTests: XCTestCase {
    func testBodyOptionUnescapesCommonSequences() throws {
        let parsed = try PostCLI.Draft.parse([
            "--from", "from@example.com",
            "--to", "to@example.com",
            "--subject", "Subject",
            "--body", "A\\nB\\rC\\tD\\\\E\\\"F\\'G"
        ])

        XCTAssertEqual(parsed.body, "A\nB\rC\tD\\E\"F'G")
    }

    func testBodyOptionPreservesEscapedBackslashBeforeN() throws {
        let parsed = try PostCLI.Draft.parse([
            "--from", "from@example.com",
            "--to", "to@example.com",
            "--subject", "Subject",
            "--body", "\\\\n"
        ])

        XCTAssertEqual(parsed.body, "\\n")
    }
}
