import SwiftMCP

extension MCPServerProxy {
    func setAccessTokenMeta(_ token: String) {
        meta["accessToken"] = .string(token)
    }
}
