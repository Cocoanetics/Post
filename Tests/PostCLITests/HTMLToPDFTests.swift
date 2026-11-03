import Logging
import XCTest
@testable import PostServer

final class HTMLToPDFTests: XCTestCase {
    func testRendersMailHTMLAsPDF() async throws {
        let html = """
        <html><body>
        <h1>Rechnung</h1>
        <p>Grüße aus Wien — <b>bold</b>, <i>italic</i>, and a table:</p>
        <table><tr><td>Item</td><td>€ 12,00</td></tr></table>
        </body></html>
        """

        let pdf = try await HTMLToPDF.render(html: html, logger: Logger(label: "test"))

        XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
        XCTAssertGreaterThan(pdf.count, 500)
    }

    func testBlanksLocalAndRemoteImageSources() {
        let html = """
        <p><img src="/dev/zero"><IMG alt="a>b" SRC='file:///etc/hosts'>\
        <img data-src="x" src=https://example.com/p.gif width=1>\
        <img src="data:image/png;base64,AAAA"></p>
        """

        let sanitized = HTMLToPDF.removingNonInlineImageSources(from: html)

        XCTAssertFalse(sanitized.contains("/dev/zero"))
        XCTAssertFalse(sanitized.contains("/etc/hosts"))
        XCTAssertFalse(sanitized.contains("example.com"))
        XCTAssertTrue(sanitized.contains("data-src=\"x\""))
        XCTAssertTrue(sanitized.contains("src=\"data:image/png;base64,AAAA\""))
    }

    func testLocalImageRendersAsPlaceholder() async throws {
        let pdf = try await HTMLToPDF.render(
            html: "<img src=\"/dev/zero\"><img src=\"file:///dev/zero\">", logger: Logger(label: "test"))

        XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
    }
}
