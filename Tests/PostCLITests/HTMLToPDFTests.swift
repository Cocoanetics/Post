import Logging
import XCTest
@testable import PostServer
import SwiftMail

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

    func testFindsInlineImageContentIDs() {
        let html = """
        <img src="cid:Logo@Example.com"><IMG SRC=' CID:banner%40example.com '>\
        <img src="https://example.com/p.gif"><a href="cid:not-an-image">x</a>
        """

        XCTAssertEqual(
            HTMLToPDF.inlineImageContentIDs(in: html), ["logo@example.com", "banner@example.com"])
    }

    func testEmbedsInlineImagesAsDataURIs() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let html = """
        <img alt="SimplePay" src="cid:Logo@Example.com"><img src='cid:unknown'>\
        <img src="cid:text"><img src="cid:quoted">
        """

        let embedded = HTMLToPDF.embeddingInlineImages([
            "logo@example.com": .init(contentType: "IMAGE/PNG; name=\"logo.png\"", data: png),
            "text": .init(contentType: "text/html", data: png),
            "quoted": .init(contentType: "image/png\" onerror=\"x", data: png),
        ], in: html)

        XCTAssertTrue(embedded.contains("src=\"data:image/png;base64,\(png.base64EncodedString())\""))
        XCTAssertTrue(embedded.contains("alt=\"SimplePay\""))
        // No matching part, not an image, or a media type that is no plain token: left
        // alone here and blanked before rendering.
        XCTAssertTrue(embedded.contains("src='cid:unknown'"))
        XCTAssertTrue(embedded.contains("src=\"cid:text\""))
        XCTAssertTrue(embedded.contains("src=\"cid:quoted\""))
        XCTAssertFalse(HTMLToPDF.removingLocalImageSources(from: embedded).contains("cid:"))
    }

    func testInlineImageIsDrawnIntoPDF() async throws {
        // A 1x1 red PNG.
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="))
        let html = "<p>Receipt</p><img src=\"cid:logo\" width=\"40\" height=\"40\">"
        let logger = Logger(label: "test")

        let without = try await HTMLToPDF.render(html: html, logger: logger)
        let with = try await HTMLToPDF.render(
            html: html, inlineImages: ["logo": .init(contentType: "image/png", data: png)], logger: logger)

        XCTAssertFalse(String(decoding: without, as: UTF8.self).contains("/Subtype /Image"))
        XCTAssertTrue(String(decoding: with, as: UTF8.self).contains("/Subtype /Image"))
    }

    /// A mail as payment providers send it: the logo travels as a `multipart/related`
    /// part and the HTML body shows it by Content-ID.
    func testInlineImagePartsOfAMessageAreEmbedded() async throws {
        let eml = """
        From: Shop <shop@example.com>
        Subject: Receipt
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="rel"

        --rel
        Content-Type: text/html; charset=utf-8

        <p>Receipt</p><img src="cid:logo-1" width="40" height="40"><img src="cid:notes">
        --rel
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-ID: <Logo-1>
        Content-Disposition: inline; filename="logo"

        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==
        --rel
        Content-Type: text/plain
        Content-ID: <notes>

        not an image
        --rel
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-ID: <unused>

        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==
        --rel--

        """.replacingOccurrences(of: "\n", with: "\r\n")
        let message = try EMLParser.parse(Data(eml.utf8))
        let html = try XCTUnwrap(message.htmlBody)

        let referenced = HTMLToPDF.inlineImageContentIDs(in: html)
        XCTAssertEqual(referenced, ["logo-1", "notes"])
        // Only the referenced image is downloaded: not the text part, not the unused image.
        XCTAssertEqual(
            PostServer.inlineImageParts(of: message, referencedBy: referenced).map(\.contentId), ["Logo-1"])

        let images = PostServer.inlineImages(of: message, referencedBy: referenced)
        XCTAssertEqual(Array(images.keys), ["logo-1"])

        let pdf = try await HTMLToPDF.render(html: html, inlineImages: images, logger: Logger(label: "test"))
        XCTAssertTrue(String(decoding: pdf, as: UTF8.self).contains("/Subtype /Image"))
    }

    func testInlineImageSizeLimitCountsTransferEncoding() throws {
        let limit = HTMLToPDF.maximumInlineImageBytes
        // A base64 image of exactly the limit, folded into 76-character CRLF lines.
        let base64 = (limit + 2) / 3 * 4
        let foldedBase64 = base64 + (base64 + 75) / 76 * 2
        func part(_ number: Int, _ id: String, encoding: String?, size: Int) -> MessagePart {
            MessagePart(section: Section([number]), contentType: "image/png", encoding: encoding,
                        contentId: "<\(id)>", size: size)
        }
        let message = Message(header: MessageInfo(sequenceNumber: SequenceNumber(1)), parts: [
            part(1, "folded", encoding: "base64", size: foldedBase64),
            part(2, "too-big", encoding: "BASE64", size: foldedBase64 + 2048),
            part(3, "binary", encoding: "binary", size: limit),
            part(4, "binary-too-big", encoding: nil, size: limit + 2048)
        ])
        let referenced: Set<String> = ["folded", "too-big", "binary", "binary-too-big"]
        XCTAssertEqual(
            PostServer.inlineImageParts(of: message, referencedBy: referenced).map(\.contentId),
            ["<folded>", "<binary>"])
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
