import Foundation
import SwiftMCP

/// Prints IDLE event log notifications from the daemon to stdout.
final class IdleEventLogger: MCPServerProxyLogNotificationHandling, @unchecked Sendable {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func mcpServerProxy(_ proxy: MCPServerProxy, didReceiveLog message: LogMessage) async {
        let timestamp = dateFormatter.string(from: Date())

        if let structured = parseStructuredEvent(from: message.data.value) {
            "[\(timestamp)] \(structured.server)/\(structured.mailbox): \(structured.event)".writeToStandardOutputLine()
        } else if let text = message.data.value as? String {
            "[\(timestamp)] \(text)".writeToStandardOutputLine()
        } else {
            "[\(timestamp)] \(message.data)".writeToStandardOutputLine()
        }
    }

    private func parseStructuredEvent(from data: Any) -> (server: String, mailbox: String, event: String)? {
        if let dict = data as? [String: String],
           let server = dict["server"],
           let mailbox = dict["mailbox"],
           let event = dict["event"] {
            return (server, mailbox, event)
        }

        if let dict = data as? [String: Any],
           let server = dict["server"] as? String,
           let mailbox = dict["mailbox"] as? String,
           let event = dict["event"] as? String {
            return (server, mailbox, event)
        }

        if let dict = data as? JSONDictionary {
            return dict.structuredIdleEvent
        }

        return nil
    }
}
