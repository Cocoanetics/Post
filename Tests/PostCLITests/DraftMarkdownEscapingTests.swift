import XCTest
@testable import post

final class DraftMarkdownEscapingTests: XCTestCase {
    func testMarkdownOptionUnescapesCommonSequences() throws {
        let parsed = try PostCLI.Draft.parse([
            "--from", "from@example.com",
            "--to", "to@example.com",
            "--subject", "Subject",
            "--markdown", "A\\nB\\rC\\tD\\\\E\\\"F\\'G"
        ])

        XCTAssertEqual(parsed.markdown, "A\nB\rC\tD\\E\"F'G")
    }

    func testMarkdownOptionPreservesEscapedBackslashBeforeN() throws {
        let parsed = try PostCLI.Draft.parse([
            "--from", "from@example.com",
            "--to", "to@example.com",
            "--subject", "Subject",
            "--markdown", "\\\\n"
        ])

        XCTAssertEqual(parsed.markdown, "\\n")
    }
}
