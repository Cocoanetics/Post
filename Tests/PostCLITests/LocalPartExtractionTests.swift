import XCTest
@testable import post

/// `--list-parts` and `--part` on a local file, shared by `eml` and `msg`.
final class LocalPartExtractionTests: XCTestCase {

    // A multipart/mixed with an alternative body and a base64 attachment, so
    // the sections are nested and extraction has transfer encoding to undo.
    private static let sampleEML = """
    From: Anna Beispiel <anna@example.com>
    To: Bernd Muster <bernd@example.org>
    Subject: Parts
    Date: Tue, 15 Apr 2025 09:12:30 +0200
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="outer"

    --outer
    Content-Type: multipart/alternative; boundary="inner"

    --inner
    Content-Type: text/plain; charset=utf-8

    plain body
    --inner
    Content-Type: text/html; charset=utf-8

    <html><body><p>html body</p></body></html>
    --inner--

    --outer
    Content-Type: application/pdf; name="vertrag.pdf"
    Content-Disposition: attachment; filename="vertrag.pdf"
    Content-Transfer-Encoding: base64

    JVBERi0xLjcgZmFrZQ==

    --outer--
    """

    private func writeSampleEML() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("post-parts-\(UUID().uuidString).eml")
        try Data(Self.sampleEML.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func makeOutputDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("post-parts-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Argument parsing

    func testListPartsAndPartAreMutuallyExclusive() {
        for arguments in [["a.eml", "--list-parts", "--part", "1"], ["a.msg", "--list-parts", "--part", "1"]] {
            XCTAssertThrowsError(try PostCLI.EML.parse(arguments)) { error in
                XCTAssertTrue(PostCLI.EML.message(for: error).contains("Use either --list-parts or --part, not both."))
            }
        }
    }

    func testPartDefaultsToCurrentDirectory() throws {
        let parsed = try PostCLI.MSG.parse(["a.msg", "--part", "4.2"])
        XCTAssertEqual(parsed.options.part, "4.2")
        XCTAssertEqual(parsed.options.output, ".")
        XCTAssertFalse(parsed.options.listParts)
    }

    func testBodyRemainsTheDefaultMode() throws {
        let parsed = try PostCLI.EML.parse(["a.eml"])
        XCTAssertNil(parsed.options.part)
        XCTAssertFalse(parsed.options.listParts)
        XCTAssertEqual(parsed.options.body, .markdown)
    }

    // MARK: - Listing

    func testListingAddressesEveryPartBySection() throws {
        let message = try LocalMessageFile.read(try writeSampleEML(), as: .eml)
        let rows = LocalMessageFile.listings(for: message)

        XCTAssertEqual(rows.map(\.section), ["1.1", "1.2", "2"])
        XCTAssertTrue(rows[0].contentType.hasPrefix("text/plain"))
        XCTAssertTrue(rows[1].contentType.hasPrefix("text/html"))
        XCTAssertEqual(rows[2].filename, "vertrag.pdf")
        // The size is of the decoded bytes, not the base64 on the wire.
        XCTAssertEqual(rows[2].size, 13)
    }

    // MARK: - Extraction

    func testExtractUndoesTransferEncoding() throws {
        let message = try LocalMessageFile.read(try writeSampleEML(), as: .eml)
        let directory = try makeOutputDirectory()

        try LocalMessageFile.extract(message, section: "2", to: directory.path)

        let written = directory.appendingPathComponent("vertrag.pdf")
        XCTAssertEqual(try Data(contentsOf: written), Data("%PDF-1.7 fake".utf8))
    }

    func testExtractHonoursAnExplicitFilename() throws {
        let message = try LocalMessageFile.read(try writeSampleEML(), as: .eml)
        let destination = try makeOutputDirectory().appendingPathComponent("renamed.pdf")

        try LocalMessageFile.extract(message, section: "2", to: destination.path)

        XCTAssertEqual(try Data(contentsOf: destination), Data("%PDF-1.7 fake".utf8))
    }

    func testExtractNamesTheAvailableSectionsWhenOneIsWrong() throws {
        let message = try LocalMessageFile.read(try writeSampleEML(), as: .eml)
        let directory = try makeOutputDirectory()

        XCTAssertThrowsError(try LocalMessageFile.extract(message, section: "9", to: directory.path)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("No part 9"), message)
            XCTAssertTrue(message.contains("1.1, 1.2, 2"), message)
        }
    }
}
