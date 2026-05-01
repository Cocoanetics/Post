import XCTest
@testable import post

final class FetchOutputPathTests: XCTestCase {
    func testExistingDirectoryWithDotIsNotExplicitFile() throws {
        let directoryURL = try makeTemporaryDirectory(named: "tmp.output")

        XCTAssertFalse(PostCLI.Fetch.isExplicitOutputFile(directoryURL))
    }

    func testNonExistingPathWithExtensionIsExplicitFile() throws {
        let directoryURL = try makeTemporaryDirectory(named: "output-root")
        let fileURL = directoryURL.appendingPathComponent("message.eml")

        XCTAssertTrue(PostCLI.Fetch.isExplicitOutputFile(fileURL))
    }

    func testNilOutputIsNotExplicitFile() {
        XCTAssertFalse(PostCLI.Fetch.isExplicitOutputFile(nil))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent(name, isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        return directoryURL
    }
}
