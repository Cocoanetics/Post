import XCTest
@testable import post

/// The one rule every `--output` option follows: an existing directory or a
/// trailing slash is a directory, anything else is the filename to write.
final class OutputPathTests: XCTestCase {

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("post-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Existing directories

    func testExistingDirectoryWithAnExtensionIsStillADirectory() throws {
        // `exports.v1` is a plausible directory name; keying on pathExtension
        // treated it as a file and the write failed because it was not one.
        let directory = try makeTemporaryDirectory().appendingPathComponent("exports.v1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertTrue(OutputPath.namesDirectory(directory.path))
        XCTAssertEqual(try OutputPath.destination(for: directory.path, named: "vertrag.pdf"),
                       directory.appendingPathComponent("vertrag.pdf"))
    }

    func testExistingDirectoryNamedLikeAPDFIsStillADirectory() throws {
        // `post pdf` used to key on the `.pdf` extension alone, so a directory
        // called `archive.pdf` was handed to `Data.write` as a file.
        let directory = try makeTemporaryDirectory().appendingPathComponent("archive.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertTrue(OutputPath.namesDirectory(directory.path))
        XCTAssertEqual(try OutputPath.destination(for: directory.path, named: "12345.pdf"),
                       directory.appendingPathComponent("12345.pdf"))
    }

    // MARK: - Filenames

    func testExtensionlessNameIsAFilename() throws {
        // `README` is a plausible filename; it used to become a directory with
        // a generated child inside it.
        let destination = try makeTemporaryDirectory().appendingPathComponent("README")

        XCTAssertFalse(OutputPath.namesDirectory(destination.path))
        XCTAssertEqual(try OutputPath.destination(for: destination.path, named: "vertrag.pdf"), destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFilenameWithAnExtensionIsAFilename() throws {
        let destination = try makeTemporaryDirectory().appendingPathComponent("renamed.pdf")

        XCTAssertFalse(OutputPath.namesDirectory(destination.path))
        XCTAssertEqual(try OutputPath.destination(for: destination.path, named: "vertrag.pdf"), destination)
    }

    func testFilenameWhoseExtensionIsNotTheExpectedOneIsStillAFilename() throws {
        // `post pdf` used to accept only `.pdf` as a filename, so `report.pdf.bak`
        // became a directory.
        let destination = try makeTemporaryDirectory().appendingPathComponent("report.pdf.bak")

        XCTAssertFalse(OutputPath.namesDirectory(destination.path))
        XCTAssertEqual(try OutputPath.destination(for: destination.path, named: "12345.pdf"), destination)
    }

    func testFilenameInAMissingDirectoryCreatesTheParent() throws {
        let parent = try makeTemporaryDirectory().appendingPathComponent("deeper")
        let destination = parent.appendingPathComponent("message.eml")

        XCTAssertEqual(try OutputPath.destination(for: destination.path, named: "1.eml"), destination)
        XCTAssertTrue(isDirectory(parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Trailing slash

    func testTrailingSlashMeansADirectoryEvenWhenMissing() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("newdir")

        XCTAssertTrue(OutputPath.namesDirectory(directory.path + "/"))
        let resolved = try OutputPath.destination(for: directory.path + "/", named: "vertrag.pdf")

        XCTAssertEqual(resolved.lastPathComponent, "vertrag.pdf")
        XCTAssertEqual(resolved.deletingLastPathComponent().lastPathComponent, "newdir")
        XCTAssertTrue(isDirectory(directory))
    }

    func testNamesDirectoryTouchesNothingOnDisk() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("untouched")

        XCTAssertTrue(OutputPath.namesDirectory(directory.path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
