import ArgumentParser
import PostServer

extension Optional where Wrapped == String {
    func resolveServerID(using client: PostProxy) async throws -> String {
        if let explicit = self {
            return explicit
        }

        let servers = try await client.listServers()
        guard !servers.isEmpty else {
            throw PostCLIError.noServersConfigured
        }

        if servers.count == 1, let only = servers.first {
            return only.id
        }

        let available = servers.map(\.id).sorted().joined(separator: ", ")
        throw ValidationError("Multiple servers configured (\(servers.count)): --server is required. Available: \(available)")
    }
}
