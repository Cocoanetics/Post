import Foundation
import XCTest
@testable import PostServer

/// A mail's remote images must never make `postd` reach its own machine or network.
final class PublicImageLoaderTests: XCTestCase {
    func testRefusesLoopbackPrivateAndLinkLocalHosts() throws {
        let refused = [
            "http://127.0.0.1/pixel.png", "http://localhost:8080/admin", "http://10.1.2.3/x.png",
            "http://172.16.5.4/x.png", "http://192.168.1.1/reboot", "http://169.254.169.254/latest/meta-data",
            "http://100.64.0.1/x.png", "http://0.0.0.0/x.png", "http://224.0.0.251/x.png",
            "http://[::1]/x.png", "http://[fe80::1]/x.png", "http://[fd12:3456::1]/x.png",
            "http://[::ffff:127.0.0.1]/x.png", "http://[64:ff9b::a00:1]/x.png"
        ]
        for string in refused {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertThrowsError(try PublicImageLoader.checkDestination(url), string) { error in
                guard case PublicImageLoader.Failure.privateAddress = error else {
                    return XCTFail("\(string): \(error)")
                }
            }
        }
    }

    func testAllowsPublicAddresses() throws {
        for string in ["https://93.184.216.34/logo.png", "https://8.8.8.8/x.png", "https://[2606:4700:4700::1111]/x.png"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertNoThrow(try PublicImageLoader.checkDestination(url), string)
        }
    }

    func testFetchesOnlyHTTP() throws {
        for string in ["file:///etc/passwd", "ftp://93.184.216.34/x.png", "cid:logo@example.com"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertThrowsError(try PublicImageLoader.checkDestination(url), string) { error in
                guard case PublicImageLoader.Failure.unsupportedScheme = error else {
                    return XCTFail("\(string): \(error)")
                }
            }
        }
    }

    func testJudgesAnIPv4AddressInIPv6FormByTheIPv4Address() {
        XCTAssertTrue(IPAddress.v6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 8, 8, 8, 8]).isPublic)
        XCTAssertFalse(IPAddress.v6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 192, 168, 0, 1]).isPublic)
        XCTAssertFalse(IPAddress.v6([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 1]).isPublic)
    }

    #if canImport(Darwin)
    func testDoesNotFollowARedirectToAPrivateAddress() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectToLocalhostStub.self]
        let url = try XCTUnwrap(URL(string: "https://93.184.216.34/logo.png"))
        do {
            _ = try await PublicImageLoader.download(url, configuration: configuration)
            XCTFail("followed a redirect to localhost")
        } catch let failure as PublicImageLoader.Failure {
            XCTAssertEqual(failure, .privateAddress("127.0.0.1"))
        }
    }
    #endif
}

#if canImport(Darwin)
/// Answers a public address with a redirect to localhost, and localhost with an
/// image — which a download that follows the redirect would return.
private final class RedirectToLocalhostStub: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let target = URL(string: "http://127.0.0.1:9/admin") else { return }
        if url.host == "127.0.0.1" {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "image/png"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4E, 0x47]))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                             headerFields: ["Location": target.absoluteString]) else { return }
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
