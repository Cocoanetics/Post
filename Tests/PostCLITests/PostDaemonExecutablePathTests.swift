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

final class PIDFileManagerIdentityTests: XCTestCase {
    func testIsPostdProcessReturnsFalseForNonExistentPID() {
        // A PID vanishingly unlikely to be in use.
        XCTAssertFalse(PIDFileManager.isPostdProcess(Int32.max - 1))
    }

    func testIsPostdProcessReturnsFalseForRunningProcessThatIsNotPostd() {
        // The test runner's own PID exists, but its executable isn't named "postd" —
        // this is the stale-PID-after-reboot scenario from the bug report.
        XCTAssertFalse(PIDFileManager.isPostdProcess(getpid()))
    }

    func testIsPostdProcessReturnsTrueForProcessNamedPostd() throws {
        let scriptURL = try makeScript(named: "postd")

        let process = Process()
        process.executableURL = scriptURL
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        addTeardownBlock {
            process.terminate()
            process.waitUntilExit()
        }

        XCTAssertTrue(PIDFileManager.isPostdProcess(process.processIdentifier))
    }

    /// Copies the `sleep` binary to a file named `name` so the running process's
    /// own executable path (as `proc_pidpath` reports it) ends in `name` — a `#!/bin/sh`
    /// script wouldn't do, since the kernel execs the interpreter, not the script.
    private func makeScript(named name: String) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binaryURL = directoryURL.appendingPathComponent(name)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        addTeardownBlock {
            try? fileManager.removeItem(at: directoryURL)
        }

        return binaryURL
    }

    func testStrippingDeletedSuffixRemovesKernelAnnotation() {
        XCTAssertEqual(
            PIDFileManager.strippingDeletedSuffix(from: "/usr/local/bin/postd (deleted)"),
            "/usr/local/bin/postd"
        )
    }

    func testStrippingDeletedSuffixLeavesOrdinaryPathUnchanged() {
        XCTAssertEqual(
            PIDFileManager.strippingDeletedSuffix(from: "/usr/local/bin/postd"),
            "/usr/local/bin/postd"
        )
    }
}
