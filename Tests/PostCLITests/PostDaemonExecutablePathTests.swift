import XCTest
@testable import postd

final class PostDaemonExecutablePathTests: XCTestCase {
    func testResolveExecutableURLFindsBareCommandOnPath() throws {
        let executableURL = try makeExecutable(named: "postd")

        let resolvedURL = try XCTUnwrap(
            ExecutablePathResolver.resolveExecutableURL(
                argv0: "postd",
                pathEnvironment: executableURL.deletingLastPathComponent().path,
                currentDirectoryPath: "/"
            )
        )

        XCTAssertEqual(resolvedURL.path, executableURL.standardizedFileURL.path)
    }

    func testCurrentExecutableURLPrefersAbsoluteBundleExecutableURL() throws {
        let executableURL = try makeExecutable(named: "postd")

        let resolvedURL = try ExecutablePathResolver.currentExecutableURL(
            bundleExecutableURL: executableURL,
            argv0: "postd",
            environment: [:],
            currentDirectoryPath: "/"
        )

        XCTAssertEqual(resolvedURL.path, executableURL.standardizedFileURL.path)
    }

    private func makeExecutable(named name: String) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableDirectoryURL = directoryURL.appendingPathComponent("bin", isDirectory: true)
        let executableURL = executableDirectoryURL.appendingPathComponent(name)

        try fileManager.createDirectory(at: executableDirectoryURL, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\n".utf8)))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        addTeardownBlock {
            try? fileManager.removeItem(at: directoryURL)
        }

        return executableURL
    }
}
