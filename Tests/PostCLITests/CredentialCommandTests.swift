import XCTest
import SwiftMail
@testable import post
@testable import PostServer

final class CredentialCommandTests: XCTestCase {
    func testSetDefaultsToIMAPWithoutSecurity() throws {
        let set = try PostCLI.Credential.Set.parse(["--server", "x"])
        XCTAssertEqual(set.credentialProtocol, .imap)
        XCTAssertNil(set.security)
    }

    func testSetParsesProtocolAndSecurity() throws {
        let set = try PostCLI.Credential.Set.parse(["--server", "x", "--protocol", "smtp", "--security", "tls"])
        XCTAssertEqual(set.credentialProtocol, .smtp)
        XCTAssertEqual(set.security, .tls)
    }

    func testSetRejectsUnknownValuesAndOldFlag() {
        XCTAssertThrowsError(try PostCLI.Credential.Set.parse(["--server", "x", "--protocol", "sieve"]))
        XCTAssertThrowsError(try PostCLI.Credential.Set.parse(["--server", "x", "--security", "ssl"]))
        XCTAssertThrowsError(try PostCLI.Credential.Set.parse(["--server", "x", "--smtp"]))
    }

    func testDeleteAndListProtocol() throws {
        XCTAssertEqual(try PostCLI.Credential.Delete.parse(["--server", "x"]).credentialProtocol, .imap)
        XCTAssertEqual(try PostCLI.Credential.Delete.parse(["--server", "x", "--protocol", "smtp"]).credentialProtocol, .smtp)
        XCTAssertNil(try PostCLI.Credential.List.parse([]).credentialProtocol)
        XCTAssertEqual(try PostCLI.Credential.List.parse(["--protocol", "smtp"]).credentialProtocol, .smtp)
    }

    func testDefaultPorts() {
        XCTAssertEqual(CredentialProtocol.imap.defaultPort, 993)
        XCTAssertEqual(CredentialProtocol.smtp.defaultPort, 465)
    }

    func testSMTPFallbackPrefersSMTPCredentialsThenIMAPHostAndUsername() {
        let imap = PostConfiguration.ServerConfiguration.Credentials(host: "imap.x", port: 993, username: "imap-user", password: "imap-pw")
        let smtp = PostConfiguration.ServerConfiguration.Credentials(
            host: "smtp.x", port: 587, username: "smtp-user", password: "smtp-pw", security: .starttls)

        let both = CredentialProtocol.fallbackCredentials(
            for: .smtp, server: .init(credentials: imap, smtp: .init(credentials: smtp)))
        XCTAssertEqual(both.host, "smtp.x")
        XCTAssertEqual(both.port, 587)
        XCTAssertEqual(both.username, "smtp-user")
        XCTAssertEqual(both.password, "smtp-pw")
        XCTAssertEqual(both.security, .starttls)

        let imapOnly = CredentialProtocol.fallbackCredentials(for: .smtp, server: .init(credentials: imap))
        XCTAssertEqual(imapOnly.host, "imap.x")
        XCTAssertEqual(imapOnly.username, "imap-user")
        XCTAssertNil(imapOnly.port, "an IMAP port is never right for SMTP")
        XCTAssertNil(imapOnly.password)

        let imapFallback = CredentialProtocol.fallbackCredentials(for: .imap, server: .init(credentials: imap, smtp: .init(credentials: smtp)))
        XCTAssertEqual(imapFallback.host, "imap.x")
        XCTAssertEqual(imapFallback.port, 993)
    }

    func testInferredSecurity() {
        XCTAssertEqual(ConnectionSecurity.inferred(port: 993, isSMTP: false), .tls)
        XCTAssertEqual(ConnectionSecurity.inferred(port: 143, isSMTP: false), .starttls)
        XCTAssertEqual(ConnectionSecurity.inferred(port: 465, isSMTP: true), .tls)
        XCTAssertEqual(ConnectionSecurity.inferred(port: 587, isSMTP: true), .starttls)
        XCTAssertEqual(ConnectionSecurity.inferred(port: 2525, isSMTP: true), .starttls)
        XCTAssertEqual(ConnectionSecurity.tls.transportSecurity, .implicitTLS)
        XCTAssertEqual(ConnectionSecurity.starttls.transportSecurity, .startTLS)
    }

    func testEffectiveSecurityPrefersStoredMode() {
        let stored = PostConfiguration.ResolvedCredentials(host: "h", port: 2525, username: "u", password: "p", security: .tls)
        XCTAssertEqual(stored.effectiveSecurity(isSMTP: true), .tls)
        let derived = PostConfiguration.ResolvedCredentials(host: "h", port: 465, username: "u", password: "p")
        XCTAssertEqual(derived.effectiveSecurity(isSMTP: true), .tls)
    }

    func testCredentialsDecodeWithAndWithoutSecurity() throws {
        let decoder = JSONDecoder()
        let without = try decoder.decode(
            PostConfiguration.ServerConfiguration.Credentials.self,
            from: Data(#"{"host":"h","port":1,"username":"u","password":"p"}"#.utf8))
        XCTAssertNil(without.security)
        let with = try decoder.decode(
            PostConfiguration.ServerConfiguration.Credentials.self,
            from: Data(#"{"host":"h","port":1,"username":"u","password":"p","security":"tls"}"#.utf8))
        XCTAssertEqual(with.security, .tls)
    }
}
