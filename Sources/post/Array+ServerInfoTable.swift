import PostServer

extension Array where Element == ServerInfo {
    func printTable() {
        guard !isEmpty else {
            print("No servers configured.")
            return
        }

        let idWidth = Swift.max("ID".count, map(\.id.count).max() ?? 0)
        let userWidth = Swift.max("Username".count, map { ($0.username ?? "<unresolved>").count }.max() ?? 0)

        print("\("ID".padded(to: idWidth))  \("Username".padded(to: userWidth))  Host")
        print("\(String(repeating: "-", count: idWidth))  \(String(repeating: "-", count: userWidth))  \(String(repeating: "-", count: 4))")

        for server in self {
            let host: String
            if let resolvedHost = server.host, let resolvedPort = server.port {
                host = "\(resolvedHost):\(resolvedPort)"
            } else if let resolvedHost = server.host {
                host = resolvedHost
            } else {
                host = "<unresolved>"
            }

            let username = server.username ?? "<unresolved>"
            print("\(server.id.padded(to: idWidth))  \(username.padded(to: userWidth))  \(host)")
        }
    }
}
