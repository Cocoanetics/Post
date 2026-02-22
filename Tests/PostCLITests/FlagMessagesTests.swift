import XCTest
@testable import post

final class FlagMessagesTests: XCTestCase {
    func testHelpIncludesColorAndUnflagOptions() {
        let help = PostCLI.helpMessage(for: PostCLI.FlagMessages.self)
        XCTAssertTrue(help.contains("--color <color>"))
        XCTAssertTrue(help.contains("--unflag"))
    }

    func testColorModeParsesSuccessfully() throws {
        let parsed = try PostCLI.FlagMessages.parse(["1", "--color", "green"])
        XCTAssertEqual(parsed.uids, "1")
        XCTAssertEqual(parsed.color?.lowercased(), "green")
        XCTAssertFalse(parsed.unflag)
    }

    func testMutuallyExclusiveModesAreRejected() {
        XCTAssertThrowsError(try PostCLI.FlagMessages.parse(["1", "--add", "seen", "--unflag"])) { error in
            let message = PostCLI.FlagMessages.message(for: error)
            XCTAssertTrue(message.contains("Exactly one of --add, --remove, --color, or --unflag is required."))
        }
    }

    func testInvalidColorIsRejected() {
        XCTAssertThrowsError(try PostCLI.FlagMessages.parse(["1", "--color", "teal"])) { error in
            let message = PostCLI.FlagMessages.message(for: error)
            XCTAssertTrue(message.contains("Invalid --color 'teal'."))
            XCTAssertTrue(message.contains("red, orange, yellow, green, blue, purple, gray"))
        }
    }
}
