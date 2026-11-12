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

    /// Billings Pro's payment notice centres its column in `<td style="display: block">`.
    /// Before SwiftText 2.8.0 that column was dropped and the export was an empty
    /// page, whose PDF uses no font at all.
    func testKeepsColumnInBlockStyledCell() async throws {
        let html = """
        <table width="100%"><tr><td></td>\
        <td style="display: block; max-width: 600px; margin: 0 auto">Payment Declined</td>\
        <td></td></tr></table>
        """

        let pdf = try await HTMLToPDF.render(html: html, logger: Logger(label: "test"))

        XCTAssertTrue(String(decoding: pdf, as: UTF8.self).contains("/BaseFont"))
    }

    func testBlanksLocalImageSources() {
        let html = """
        <p><img src="/dev/zero"><IMG alt="a>b" SRC='file:///etc/hosts'>\
        <img src="//etc/passwd"><img src=" relative/logo.png ">\
        <img data-src="x" src=https://example.com/p.gif width=1>\
        <img src=" HTTP://Example.com/Logo.PNG ">\
        <img src="data:image/png;base64,AAAA"></p>
        """

        let sanitized = HTMLToPDF.removingLocalImageSources(from: html)

        XCTAssertFalse(sanitized.contains("/dev/zero"))
        XCTAssertFalse(sanitized.contains("/etc/hosts"))
        XCTAssertFalse(sanitized.contains("/etc/passwd"))
        XCTAssertFalse(sanitized.contains("relative/logo.png"))
        // Remote images stay: PublicImageLoader fetches them from public hosts only.
        XCTAssertTrue(sanitized.contains("src=https://example.com/p.gif"))
        XCTAssertTrue(sanitized.contains("src=\" HTTP://Example.com/Logo.PNG \""))
        XCTAssertTrue(sanitized.contains("data-src=\"x\""))
        XCTAssertTrue(sanitized.contains("src=\"data:image/png;base64,AAAA\""))
    }

    func testLocalImageRendersAsPlaceholder() async throws {
        let pdf = try await HTMLToPDF.render(
            html: "<img src=\"/dev/zero\"><img src=\"file:///dev/zero\">", logger: Logger(label: "test"))

        XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
    }

    func testDisablesFontFaces() {
        let css = """
        @font-face{src:url(/dev/zero)} @FONT-FACE{} @\\66 ont-face{} @fo\\nt-face{} \
        @media print{} @font-feature-values x{} @x-font-face{}
        """

        let sanitized = HTMLToPDF.removingFontFaces(from: css)

        XCTAssertEqual(sanitized, """
        @x-font-face{src:url(/dev/zero)} @x-FONT-FACE{} @x-\\66 ont-face{} @x-fo\\nt-face{} \
        @media print{} @font-feature-values x{} @x-font-face{}
        """)
    }

    func testLocalFontFaceIsNotRead() async throws {
        let html = """
        <style>@font-face{font-family:x;src:url(/dev/zero)}\
        @font-face{font-family:y;src:url(file:///dev/zero)}</style>\
        <p style="font-family:x">hi</p><p style="font-family:y">there</p>
        """

        let pdf = try await HTMLToPDF.render(html: html, logger: Logger(label: "test"))

        XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
    }
}
