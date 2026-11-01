import XCTest
#if canImport(Network)
import Network
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PostServer

/// In-memory store and fake token endpoint: no keychain, network or real accounts.
private final class MemoryOAuthStore: OAuthCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OAuthCredentialKey: OAuthCredentials] = [:]
    private(set) var saveCount = 0

    func load(_ key: OAuthCredentialKey) throws -> OAuthCredentials? {
        lock.withLock { items[key] }
    }

    func save(_ credentials: OAuthCredentials, for key: OAuthCredentialKey) throws {
        lock.withLock {
            items[key] = credentials
            saveCount += 1
        }
    }
}

private final class FakeTokenEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [[String: String]] = []
    var status = 200
    var body: [String: Any] = ["access_token": "new-access", "expires_in": 3600]
    var delay: UInt64 = 0

    var transport: OAuthHTTPTransport {
        { [self] request in
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            var fields: [String: String] = [:]
            for pair in form.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
            }
            lock.withLock { requests.append(fields) }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }
}

final class OAuthTokenServiceTests: XCTestCase {
    private let key = OAuthCredentialKey(label: "test")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func credentials(accessToken: String? = "old-access", refreshToken: String? = "refresh-1", expiresAt: Date?) -> OAuthCredentials {
        OAuthCredentials(
            email: "user@example.com", clientID: "client", clientSecret: "s3cret",
            accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt,
            tokenEndpoint: URL(string: "https://oauth.example.com/token")!
        )
    }

    private func service(_ store: MemoryOAuthStore, _ endpoint: FakeTokenEndpoint) -> OAuthTokenService {
        let now = self.now
        return OAuthTokenService(store: store, transport: endpoint.transport, now: { now })
    }

    func testValidTokenIsReturnedWithoutRefreshing() async throws {
        let store = MemoryOAuthStore()
        try store.save(credentials(expiresAt: now.addingTimeInterval(3600)), for: key)
        let endpoint = FakeTokenEndpoint()
        let token = try await service(store, endpoint).accessToken(for: key)
        XCTAssertEqual(token, "old-access")
        XCTAssertTrue(endpoint.requests.isEmpty)
    }

    func testTokenNearExpiryIsRefreshedAndPersisted() async throws {
        let store = MemoryOAuthStore()
        try store.save(credentials(expiresAt: now.addingTimeInterval(30)), for: key)
        let endpoint = FakeTokenEndpoint()
        let token = try await service(store, endpoint).accessToken(for: key)
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(endpoint.requests.first?["grant_type"], "refresh_token")
        XCTAssertEqual(endpoint.requests.first?["refresh_token"], "refresh-1")
        XCTAssertEqual(endpoint.requests.first?["client_secret"], "s3cret")
        let saved = try XCTUnwrap(store.load(key))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(saved.refreshToken, "refresh-1")
    }

    func testRotatedRefreshTokenIsStored() async throws {
        let store = MemoryOAuthStore()
        try store.save(credentials(expiresAt: now.addingTimeInterval(-10)), for: key)
        let endpoint = FakeTokenEndpoint()
        endpoint.body = ["access_token": "a2", "expires_in": 60, "refresh_token": "refresh-2"]
        _ = try await service(store, endpoint).accessToken(for: key)
        XCTAssertEqual(try store.load(key)?.refreshToken, "refresh-2")
    }

    func testImportedRefreshTokenWithoutAccessTokenRefreshesOnFirstUse() async throws {
        let store = MemoryOAuthStore()
        try store.save(credentials(accessToken: nil, expiresAt: nil), for: key)
        let endpoint = FakeTokenEndpoint()
        let token = try await service(store, endpoint).accessToken(for: key)
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(endpoint.requests.count, 1)
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let store = MemoryOAuthStore()
        try store.save(credentials(expiresAt: now.addingTimeInterval(-10)), for: key)
        let endpoint = FakeTokenEndpoint()
        endpoint.delay = 100_000_000
        let service = service(store, endpoint)
        let key = self.key
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await service.accessToken(for: key) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(tokens), ["new-access"])
        XCTAssertEqual(endpoint.requests.count, 1)
        XCTAssertEqual(store.saveCount, 2) // the test's seed plus one refresh
    }

    func testRevokedGrantAsksForReauthorization() async throws {
        let store = MemoryOAuthStore()
        try store.save(credentials(expiresAt: now.addingTimeInterval(-10)), for: key)
        let endpoint = FakeTokenEndpoint()
        endpoint.status = 400
        endpoint.body = ["error": "invalid_grant", "error_description": "Token has been revoked"]
        do {
            _ = try await service(store, endpoint).accessToken(for: key)
            XCTFail("expected failure")
        } catch let error as OAuthError {
            guard case .reauthorizationRequired(let label, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(label, "test")
            XCTAssertTrue(reason.contains("revoked"))
            XCTAssertTrue(error.localizedDescription.contains("add-oauth"))
        }
        XCTAssertEqual(try store.load(key)?.accessToken, "old-access")
    }

    func testExpiredTokenWithoutRefreshTokenAsksForReauthorization() async throws {
        let store = MemoryOAuthStore()
        try store.save(credentials(refreshToken: nil, expiresAt: now.addingTimeInterval(-10)), for: key)
        let endpoint = FakeTokenEndpoint()
        do {
            _ = try await service(store, endpoint).accessToken(for: key)
            XCTFail("expected failure")
        } catch let error as OAuthError {
            guard case .reauthorizationRequired = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(endpoint.requests.isEmpty)
    }
}

#if canImport(CryptoKit) && canImport(Network)
final class OAuthAuthorizationTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Vector() {
        XCTAssertEqual(
            PKCEChallenge.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        let generated = PKCEChallenge.generate()
        XCTAssertGreaterThanOrEqual(generated.verifier.count, 43)
        XCTAssertEqual(PKCEChallenge.challenge(for: generated.verifier), generated.challenge)
    }

    func testCallbackAcceptsOnlyTheExpectedState() {
        XCTAssertEqual(OAuthCallbackRequest.evaluate(target: "/callback?code=abc&state=S", expectedState: "S"), .code("abc"))
        XCTAssertEqual(OAuthCallbackRequest.evaluate(target: "/callback?code=abc&state=X", expectedState: "S"), .rejected)
        XCTAssertEqual(OAuthCallbackRequest.evaluate(target: "/callback?code=abc", expectedState: "S"), .rejected)
        XCTAssertEqual(OAuthCallbackRequest.evaluate(target: "/callback?error=access_denied", expectedState: "S"), .rejected)
        XCTAssertEqual(OAuthCallbackRequest.evaluate(target: "/callback?error=access_denied&state=S", expectedState: "S"), .denied("access_denied"))
        XCTAssertEqual(OAuthCallbackRequest.evaluate(target: "/callback?state=S", expectedState: "S"), .rejected)
        XCTAssertEqual(OAuthCallbackRequest.evaluate(target: "/favicon.ico", expectedState: "S"), .unrelated)
    }

    func testAuthorizationURLCarriesPKCEAndState() throws {
        let request = OAuthAuthorizationFlow.Request(email: "user@example.com", clientID: "cid")
        let pkce = PKCEChallenge(verifier: "v", challenge: "c")
        let url = OAuthAuthorizationFlow.authorizationURL(
            request: request, redirectURI: "http://127.0.0.1:5000/callback", state: "st", pkce: pkce)
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], "c")
        XCTAssertEqual(items["state"], "st")
        XCTAssertEqual(items["client_id"], "cid")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5000/callback")
        XCTAssertEqual(items["scope"], "https://mail.google.com/")
    }

    func testListenerRejectsWrongStateThenAcceptsRightOne() async throws {
        let listener = LoopbackCallbackListener(expectedState: "good", timeout: 20)
        let port = try await listener.start()

        func get(_ query: String) async throws -> Int {
            let url = URL(string: "http://127.0.0.1:\(port)/callback?\(query)")!
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as! HTTPURLResponse).statusCode
        }
        let bad = try await get("code=evil&state=bad")
        XCTAssertEqual(bad, 400)
        let ok = try await get("code=real-code&state=good")
        XCTAssertEqual(ok, 200)
        let code = try await listener.waitForCode()
        XCTAssertEqual(code, "real-code")
    }

    func testListenerBuffersRequestSplitAcrossReads() async throws {
        let listener = LoopbackCallbackListener(expectedState: "good", timeout: 20)
        let port = try await listener.start()
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data("GET /callback?code=split-code&sta".utf8), completion: .contentProcessed { _ in })
        try await Task.sleep(nanoseconds: 300_000_000)
        connection.send(content: Data("te=good HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        let code = try await listener.waitForCode()
        connection.cancel()
        XCTAssertEqual(code, "split-code")
    }

    func testListenerTimesOut() async throws {
        let listener = LoopbackCallbackListener(expectedState: "s", timeout: 0.3)
        _ = try await listener.start()
        do {
            _ = try await listener.waitForCode()
            XCTFail("expected timeout")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .callbackTimedOut)
        }
    }

    func testAuthorizationFlowExchangesCodeWithVerifier() async throws {
        let endpoint = FakeTokenEndpoint()
        endpoint.body = ["access_token": "acc", "refresh_token": "ref", "expires_in": 3600]
        let request = OAuthAuthorizationFlow.Request(email: "user@example.com", clientID: "cid", timeout: 20)
        let credentials = try await OAuthAuthorizationFlow.authorize(request, transport: endpoint.transport) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            let state = items.first { $0.name == "state" }!.value!
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?code=the-code&state=\(state)")!) }
        }
        XCTAssertEqual(credentials.refreshToken, "ref")
        XCTAssertEqual(credentials.accessToken, "acc")
        let sent = try XCTUnwrap(endpoint.requests.first)
        XCTAssertEqual(sent["grant_type"], "authorization_code")
        XCTAssertEqual(sent["code"], "the-code")
        XCTAssertNotNil(sent["code_verifier"])
        XCTAssertTrue(sent["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
    }
}
#endif

final class OAuthAuthenticationSelectionTests: XCTestCase {
    func testPasswordCredentialsSelectLogin() {
        let resolved = PostConfiguration.ResolvedCredentials(host: "h", port: 993, username: "u", password: "p")
        XCTAssertEqual(resolved.authentication, .password("p"))
    }

    func testOAuthCredentialsSelectXOAUTH2() {
        let key = OAuthCredentialKey(label: "gmail")
        let resolved = PostConfiguration.ResolvedCredentials(host: "h", port: 993, username: "u", password: "", oauth: key)
        XCTAssertEqual(resolved.authentication, .xoauth2(key))
    }
}

#if canImport(Security)
final class KeychainOAuthCompatibilityTests: XCTestCase {
    func testOAuthItemRoundTripsAndStaysApartFromPasswords() throws {
        let store = KeychainCredentialStore()
        let id = "post-test-\(UUID().uuidString)"
        addTeardownBlock { try? store.delete(label: id) }
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let oauth = OAuthCredentials(
            email: "user@example.com", clientID: "cid", accessToken: "a", refreshToken: "r", expiresAt: expiry,
            tokenEndpoint: URL(string: "https://oauth.example.com/token")!, smtpHost: "smtp.example.com", smtpPort: 465)

        try store.storeOAuth(id: id, host: "imap.example.com", port: 993, credentials: oauth)
        XCTAssertEqual(try store.oauthCredentials(forLabel: id)?.oauth, oauth)
        XCTAssertNil(try store.fullCredentials(forLabel: id), "OAuth JSON must never be handed out as a password")
        XCTAssertEqual(try store.list().filter { $0.id == id }.count, 1)

        var refreshed = oauth
        refreshed.accessToken = "b"
        try KeychainOAuthCredentialStore().save(refreshed, for: OAuthCredentialKey(label: id))
        XCTAssertEqual(try store.oauthCredentials(forLabel: id)?.oauth.accessToken, "b")

        // A password item under the same label replaces it and is not mistaken for OAuth.
        try store.store(id: id, host: "imap.example.com", port: 993, username: "user", password: "pw")
        XCTAssertNil(try store.oauthCredentials(forLabel: id))
        XCTAssertEqual(try store.fullCredentials(forLabel: id)?.password, "pw")
    }

    func testOAuthOutranksRetainedSMTPPassword() async throws {
        let store = KeychainCredentialStore()
        let id = "post-test-\(UUID().uuidString)"
        addTeardownBlock {
            try? store.delete(label: id)
            try? store.delete(label: id, type: .smtp)
        }
        try store.store(id: id, host: "smtp.example.com", port: 465, username: "user", password: "old", type: .smtp)
        let oauth = OAuthCredentials(
            email: "user@example.com", clientID: "cid", refreshToken: "r",
            tokenEndpoint: URL(string: "https://oauth.example.com/token")!, smtpHost: "smtp.example.com", smtpPort: 465)
        try store.storeOAuth(id: id, host: "imap.example.com", port: 993, credentials: oauth)

        let configuration = PostConfiguration(servers: [id: .init()], httpPort: nil)
        let manager = IMAPConnectionManager(configuration: configuration)
        let resolved = try await manager.resolveSMTPCredentials(forServer: id)
        XCTAssertEqual(resolved.authentication, .xoauth2(OAuthCredentialKey(label: id, service: .imap)))
    }
}
#endif
