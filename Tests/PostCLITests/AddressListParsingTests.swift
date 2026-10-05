import Foundation
import SwiftMail
import XCTest
@testable import PostServer

final class AddressListParsingTests: XCTestCase {
    func testBareAddressHasNoName() throws {
        let address = try PostServer.parseAddress("jane@example.com")

        XCTAssertNil(address.name)
        XCTAssertEqual(address.address, "jane@example.com")
    }

    func testAsciiNameIsKeptAndNotEncoded() throws {
        let address = try PostServer.parseAddress("John Doe <john@example.com>")

        XCTAssertEqual(address.name, "John Doe")
        XCTAssertEqual(address.address, "john@example.com")
        XCTAssertEqual(address.description, "John Doe <john@example.com>")
    }

    func testNonAsciiNameIsParsedAndEncodedForHeader() throws {
        let address = try PostServer.parseAddress("Jiří Novák <jiri@example.com>")

        XCTAssertEqual(address.name, "Jiří Novák")
        XCTAssertEqual(address.address, "jiri@example.com")
        XCTAssertTrue(address.description.hasSuffix("<jiri@example.com>"))
        XCTAssertTrue(address.description.contains("=?UTF-8?"))
    }

    func testQuotedNameWithCommaStaysOneEntry() throws {
        let addresses = try PostServer.parseAddressList(
            "\"Doe, Jane\" <jane@example.com>, John Doe <john@example.com>"
        )

        XCTAssertEqual(addresses.count, 2)
        XCTAssertEqual(addresses[0].name, "Doe, Jane")
        XCTAssertEqual(addresses[0].address, "jane@example.com")
        XCTAssertEqual(addresses[1].name, "John Doe")
        XCTAssertEqual(addresses[1].address, "john@example.com")
    }

    func testIssueReproSplitsIntoTwoMailboxes() throws {
        let addresses = try PostServer.parseAddressList(
            "Jane Roe <jane@example.com>, Jiří Novák <jiri@example.com>"
        )

        XCTAssertEqual(addresses.count, 2)
        XCTAssertEqual(addresses[0].description, "Jane Roe <jane@example.com>")
        XCTAssertTrue(addresses[1].description.hasSuffix("<jiri@example.com>"))
        XCTAssertTrue(addresses[1].description.contains("=?UTF-8?"))
    }

    func testEmptyListProducesNoAddresses() throws {
        let addresses = try PostServer.parseAddressList("")

        XCTAssertEqual(addresses, [])
    }

    func testMalformedAddressThrowsInvalidAddress() {
        XCTAssertThrowsError(try PostServer.parseAddress("not an email")) { error in
            guard case PostServerError.invalidAddress = error else {
                return XCTFail("Expected PostServerError.invalidAddress, got \(error)")
            }
        }
    }

    func testIssueReproKeepsSenderAddressInTheClear() throws {
        let sender = try PostServer.parseAddress("John Doe <john@example.com>")

        XCTAssertEqual(sender.description, "John Doe <john@example.com>")
    }
}
