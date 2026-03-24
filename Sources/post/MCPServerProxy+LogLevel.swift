import ArgumentParser
import Foundation
import SwiftMCP

extension MCPServerProxy {
    func setLogLevel(_ level: LogLevel) async throws {
        let request = JSONRPCMessage.request(
            id: UUID().uuidString,
            method: "logging/setLevel",
            params: [
                "level": .string(level.rawValue)
            ]
        )

        let response = try await send(request)
        switch response {
        case .response:
            return
        case .errorResponse(let error):
            throw ValidationError("Failed to configure MCP log level to '\(level.rawValue)': \(error.error.message)")
        default:
            throw ValidationError("Unexpected response while configuring MCP log level to '\(level.rawValue)'.")
        }
    }
}
