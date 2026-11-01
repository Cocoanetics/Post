import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit) && canImport(Network)
import CryptoKit
import Network

/// PKCE (RFC 7636) verifier and its S256 challenge.
public struct PKCEChallenge: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public static func generate() -> PKCEChallenge {
        let verifier = OAuthRandom.urlSafeString(byteCount: 32)
        return PKCEChallenge(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

enum OAuthRandom {
    static func urlSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Classifies one request to the loopback redirect listener.
public enum OAuthCallbackRequest: Equatable, Sendable {
    public static let path = "/callback"

    /// The authorization code, delivered with the expected `state`.
    case code(String)
    /// The provider reported an error, delivered with the expected `state`.
    case denied(String)
    /// A request to the callback path with a missing or wrong `state`, or neither code nor error.
    case rejected
    /// Anything else (favicon, scanners); answered with 404 and otherwise ignored.
    case unrelated

    /// Evaluates an HTTP request target such as `/callback?code=…&state=…`.
    public static func evaluate(target: String, expectedState: String) -> OAuthCallbackRequest {
        guard let components = URLComponents(string: target), components.path == path else {
            return .unrelated
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        // A request without the state this flow generated is not ours, whatever else it carries.
        guard let state = value("state"), state == expectedState else { return .rejected }
        if let error = value("error") { return .denied(error) }
        if let code = value("code"), !code.isEmpty { return .code(code) }
        return .rejected
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that waits for the OAuth redirect.
///
/// Binds an ephemeral port (Google accepts any loopback port for installed apps),
/// serves until the first valid callback, an authorization error, or `timeout`.
final class LoopbackCallbackListener: @unchecked Sendable {
    private let expectedState: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.cocoanetics.Post.OAuthCallback")
    private var listener: NWListener?
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var resultContinuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(expectedState: String, timeout: TimeInterval) {
        self.expectedState = expectedState
        self.timeout = timeout
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw OAuthError.listenerFailed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state, listener: listener)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.listener = listener
                self.portContinuation = continuation
                listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + self.timeout) {
                    self.finish(.failure(OAuthError.callbackTimedOut))
                }
            }
        }
    }

    /// Waits for the authorization code.
    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result {
                    continuation.resume(with: result)
                } else {
                    self.resultContinuation = continuation
                }
            }
        }
    }

    private func stateChanged(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                portContinuation?.resume(returning: port)
                portContinuation = nil
            }
        case .failed(let error):
            let failure = OAuthError.listenerFailed(error.localizedDescription)
            portContinuation?.resume(throwing: failure)
            portContinuation = nil
            finish(.failure(failure))
        default:
            break
        }
    }

    private func finish(_ outcome: Result<String, Error>) {
        guard result == nil else { return }
        result = outcome
        listener?.cancel()
        if let portContinuation {
            if case .failure(let error) = outcome { portContinuation.resume(throwing: error) }
            self.portContinuation = nil
        }
        resultContinuation?.resume(with: outcome)
        resultContinuation = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Reads until the request line is complete: TCP may split it across reads.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            let hasLine = buffer.range(of: Data("\r\n".utf8)) != nil
            if !hasLine && buffer.count < 8192 && !isComplete && error == nil {
                return self.receiveRequest(on: connection, buffer: buffer)
            }
            self.respond(to: String(decoding: buffer, as: UTF8.self), on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        let outcome: OAuthCallbackRequest
        if parts.count >= 2, parts[0] == "GET" {
            outcome = OAuthCallbackRequest.evaluate(target: String(parts[1]), expectedState: self.expectedState)
        } else {
            outcome = .unrelated
        }

        let status: String
        let message: String
        switch outcome {
        case .code:
            status = "200 OK"
            message = "Post is authorized. You can close this tab."
        case .denied:
            status = "200 OK"
            message = "Authorization was not granted. You can close this tab."
        case .rejected:
            status = "400 Bad Request"
            message = "Invalid authorization response."
        case .unrelated:
            status = "404 Not Found"
            message = "Not found."
        }
        let body = "<html><body><p>\(message)</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        switch outcome {
        case .code(let code): self.finish(.success(code))
        case .denied(let reason): self.finish(.failure(OAuthError.authorizationDenied(reason)))
        case .rejected, .unrelated: break
        }
    }
}

/// Browser-based authorization: installed-app loopback redirect with PKCE S256 (RFC 8252).
public enum OAuthAuthorizationFlow {
    public struct Request: Sendable {
        public var email: String
        public var clientID: String
        public var clientSecret: String?
        public var provider: OAuthProvider
        public var smtpHost: String?
        public var smtpPort: Int?
        public var timeout: TimeInterval

        public init(
            email: String, clientID: String, clientSecret: String? = nil,
            provider: OAuthProvider = .google, smtpHost: String? = nil, smtpPort: Int? = nil,
            timeout: TimeInterval = 300
        ) {
            self.email = email
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.provider = provider
            self.smtpHost = smtpHost
            self.smtpPort = smtpPort
            self.timeout = timeout
        }
    }

    /// Builds the URL the user opens in a browser.
    public static func authorizationURL(
        request: Request, redirectURI: String, state: String, pkce: PKCEChallenge
    ) -> URL {
        var components = URLComponents(url: request.provider.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "client_id", value: request.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: request.provider.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Google only issues a refresh token to offline requests that ask for consent.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "login_hint", value: request.email)
        ]
        components.queryItems = items
        return components.url!
    }

    /// Runs the whole flow. `present` receives the authorization URL (open it in a browser).
    public static func authorize(
        _ request: Request,
        transport: @escaping OAuthHTTPTransport = OAuthTokenEndpoint.defaultTransport,
        now: @Sendable () -> Date = { Date() },
        present: @Sendable (URL) -> Void
    ) async throws -> OAuthCredentials {
        let pkce = PKCEChallenge.generate()
        let state = OAuthRandom.urlSafeString(byteCount: 24)
        let listener = LoopbackCallbackListener(expectedState: state, timeout: request.timeout)
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)\(OAuthCallbackRequest.path)"

        present(authorizationURL(request: request, redirectURI: redirectURI, state: state, pkce: pkce))
        let code = try await listener.waitForCode()

        var fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", request.clientID),
            ("code_verifier", pkce.verifier)
        ]
        if let secret = request.clientSecret, !secret.isEmpty {
            fields.append(("client_secret", secret))
        }
        let tokenRequest = OAuthTokenEndpoint.request(endpoint: request.provider.tokenEndpoint, fields: fields)
        let response = try await OAuthTokenEndpoint.perform(tokenRequest, transport: transport, label: nil)
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.missingRefreshToken
        }
        return OAuthCredentials(
            email: request.email,
            clientID: request.clientID,
            clientSecret: request.clientSecret,
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: response.expiresIn.map { now().addingTimeInterval($0) },
            tokenEndpoint: request.provider.tokenEndpoint,
            smtpHost: request.smtpHost,
            smtpPort: request.smtpPort
        )
    }
}
#endif
