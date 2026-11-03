import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import SwiftTextRender

/// Fetches the remote images of a mail being exported to PDF, but only from the
/// public internet.
///
/// Mail is untrusted input. Without this, an `<img>` aimed at a router's admin page
/// or a service on localhost would make `postd` send that request for whoever wrote
/// the mail. Every host a download touches — the first and each redirect target —
/// must resolve to public addresses only. A DNS answer that changes between that
/// check and the connection is not covered.
enum PublicImageLoader {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedScheme(String)
        case unresolvable(String)
        case privateAddress(String)
        case httpStatus(Int)
        case tooLarge(Int)

        var description: String {
            switch self {
            case .unsupportedScheme(let scheme): return "the URL scheme '\(scheme)' is not fetched"
            case .unresolvable(let host): return "\(host) does not resolve"
            case .privateAddress(let host): return "\(host) is not on the public internet"
            case .httpStatus(let status): return "the server answered HTTP \(status)"
            case .tooLarge(let bytes): return "the image is at least \(bytes) bytes"
            }
        }
    }

    /// The `RenderOptions.imageLoader` for mail.
    static let load: ImageLoader = { url in
        try await download(url)
    }

    /// Download an image, at most `limit` bytes of it, within 15 seconds of silence
    /// and 30 in all.
    static func download(
        _ url: URL,
        limit: Int = HTMLRenderer.maximumRemoteImageBytes,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        // getaddrinfo blocks, so it runs off the cooperative thread pool.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try checkDestination(url) })
            }
        }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        // Only the formats SwiftText embeds; content-negotiating CDNs otherwise
        // answer with WebP or AVIF.
        request.setValue("image/png,image/jpeg;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        configuration.timeoutIntervalForResource = 30
        let (data, status) = try await GuardedDownload(limit: limit).run(request, configuration: configuration)
        if let status, !(200...299).contains(status) {
            throw Failure.httpStatus(status)
        }
        return data
    }

    /// Throws unless `url` is `http` or `https` and its host resolves to public
    /// addresses only.
    static func checkDestination(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw Failure.unsupportedScheme(scheme) }
        guard var host = url.host, !host.isEmpty else { throw Failure.unresolvable(url.absoluteString) }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let addresses = resolve(host)
        guard !addresses.isEmpty else { throw Failure.unresolvable(host) }
        guard addresses.allSatisfy(\.isPublic) else { throw Failure.privateAddress(host) }
    }

    /// The addresses `host` resolves to; an IP literal resolves to itself.
    static func resolve(_ host: String) -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        addresses.append(.v4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)))
                    }
                case AF_INET6:
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        var raw = $0.pointee.sin6_addr
                        addresses.append(.v6(withUnsafeBytes(of: &raw) { Array($0) }))
                    }
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}

/// An IPv4 or IPv6 address as `getaddrinfo` reports it.
enum IPAddress: Equatable {
    case v4(UInt32)
    case v6([UInt8])

    /// IPv4 ranges that are not the public internet: "this network", private,
    /// shared (CGNAT), loopback, link-local (cloud metadata lives there), IETF
    /// protocol assignments, documentation, the 6to4 relay, benchmarking,
    /// multicast and reserved.
    private static let nonPublicV4: [(prefix: UInt32, length: UInt32)] = [
        (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8),
        (0xA9FE_0000, 16), (0xAC10_0000, 12), (0xC000_0000, 24), (0xC000_0200, 24),
        (0xC058_6300, 24), (0xC0A8_0000, 16), (0xC612_0000, 15), (0xC633_6400, 24),
        (0xCB00_7100, 24), (0xE000_0000, 4), (0xF000_0000, 4)
    ]

    /// Whether this address is on the public internet.
    var isPublic: Bool {
        switch self {
        case .v4(let address):
            return !Self.nonPublicV4.contains { range in
                address & (UInt32.max << (32 - range.length)) == range.prefix
            }
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            // An IPv4 address in IPv6 form — mapped (::ffff:0:0/96), compatible
            // (::/96, which also holds :: and ::1) or NAT64 (64:ff9b::/96) — is
            // judged as the IPv4 address it carries.
            let head = bytes[0 ..< 12]
            if head.elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF])
                || head.allSatisfy({ $0 == 0 })
                || head.elementsEqual([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) {
                let embedded = bytes[12 ..< 16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                return IPAddress.v4(embedded).isPublic
            }
            switch bytes[0] {
            case 0xFC, 0xFD, 0xFE, 0xFF:
                // Unique local (fc00::/7), link- and site-local (fe80::/10,
                // fec0::/10) and multicast (ff00::/8).
                return false
            default:
                break
            }
            // Documentation (2001:db8::/32) and discard-only (100::/64).
            if bytes[0 ..< 4].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false }
            if bytes[0] == 0x01, bytes[1 ..< 8].allSatisfy({ $0 == 0 }) { return false }
            return true
        }
    }
}

/// One image download that stops as soon as its body outgrows the limit or a
/// redirect leads off the public internet. URLSession calls the delegate on its
/// own queue; the lock guards the state it shares with the awaiting task.
private final class GuardedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var received = Data()
    private var refusal: PublicImageLoader.Failure?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, Int?), any Error>?
    private var isCancelled = false

    init(limit: Int) {
        self.limit = limit
    }

    /// The body and HTTP status of `request`.
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, Int?) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let cancelled = locked { () -> Bool in
                    self.continuation = continuation
                    self.task = task
                    return isCancelled
                }
                if cancelled {
                    task.cancel()
                    finish(.failure(CancellationError()))
                } else {
                    task.resume()
                }
                // Releases the session, and with it this delegate, once the task ends.
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            let task = locked { () -> URLSessionDataTask? in
                isCancelled = true
                return self.task
            }
            task?.cancel()
            finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let size = locked { () -> Int in
            received.append(data)
            return received.count
        }
        let declared = dataTask.response?.expectedContentLength ?? -1
        guard size > limit || declared > Int64(limit) else { return }
        dataTask.cancel()
        finish(.failure(PublicImageLoader.Failure.tooLarge(max(size, Int(clamping: declared)))))
    }

    #if canImport(Darwin)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        redirect(to: request)
    }
    #else
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(redirect(to: request))
    }
    #endif

    /// The redirect to follow, or `nil` — refusing it — when it leads off the
    /// public internet.
    private func redirect(to request: URLRequest) -> URLRequest? {
        guard let url = request.url else { return nil }
        do {
            try PublicImageLoader.checkDestination(url)
            return request
        } catch {
            locked { refusal = error as? PublicImageLoader.Failure ?? .unresolvable(url.absoluteString) }
            return nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (body, refusal) = locked { (received, self.refusal) }
        if let refusal {
            finish(.failure(refusal))
        } else if let error {
            finish(.failure(error))
        } else {
            finish(.success((body, (task.response as? HTTPURLResponse)?.statusCode)))
        }
    }

    /// Resume the waiting task exactly once; whatever comes after, such as the
    /// completion of a transfer this cancelled, is dropped.
    private func finish(_ outcome: Result<(Data, Int?), any Error>) {
        let continuation = locked { () -> CheckedContinuation<(Data, Int?), any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: outcome)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
