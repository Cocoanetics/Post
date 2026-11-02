import Foundation
import XCTest

/// Exercises `Scripts/check-swift-version.sh`, the guard the CI "Verify Swift version" steps run.
final class SwiftVersionGuardTests: XCTestCase {
    private var scriptPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/check-swift-version.sh").path
    }

    private func runGuard(_ input: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testAcceptsAppleAndLinuxOutput() throws {
        XCTAssertEqual(try runGuard("swift-driver version: 1.120.5 Apple Swift version 6.4 (swiftlang-6.4.0.1 clang-2100.0.1)\nTarget: arm64-apple-macosx27.0\n"), 0)
        XCTAssertEqual(try runGuard("Swift version 6.4.2 (swift-6.4.2-RELEASE)\nTarget: x86_64-unknown-linux-gnu\n"), 0)
        XCTAssertEqual(try runGuard("Swift version 6.4 (swift-6.4-RELEASE)\n"), 0)
    }

    func testRejectsOtherVersions() throws {
        for version in ["6.3", "6.3.1", "6.5", "6.40", "6.40.1", "5.4", "16.4"] {
            XCTAssertNotEqual(try runGuard("Swift version \(version) (swift-\(version)-RELEASE)\n"), 0, version)
        }
    }

    func testRejectsMalformedOutput() throws {
        XCTAssertNotEqual(try runGuard(""), 0)
        XCTAssertNotEqual(try runGuard("command not found: swift\n"), 0)
        XCTAssertNotEqual(try runGuard("Swift version six.four\n"), 0)
        XCTAssertNotEqual(try runGuard("Swift version 6\n"), 0)
    }
}
