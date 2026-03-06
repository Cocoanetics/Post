import Foundation
import Logging

#if canImport(OSLog)

@preconcurrency import OSLog

/// A swift-log backend that routes all log messages to Apple's unified logging system (Console.app).
/// Uses a fixed subsystem and derives the OSLog category from the swift-log label.
struct OSLogHandler: Logging.LogHandler {
    static let subsystem = "com.cocoanetics.Post"

    let label: String
    private let osLog: OSLog

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    init(label: String) {
        self.label = label

        // Derive category: strip common prefix, keep the rest as category.
        // e.g. "com.cocoanetics.Post.IDLE.Diagnostics" → "IDLE.Diagnostics"
        //      "com.cocoanetics.SwiftMail.IMAP_IN.xyz" → "SwiftMail.IMAP_IN.xyz"
        //      "com.cocoanetics.SwiftMCP.TCPBonjourTransport" → "SwiftMCP.TCPBonjourTransport"
        let category: String
        let prefix = Self.subsystem + "."
        if label.hasPrefix(prefix) {
            category = String(label.dropFirst(prefix.count))
        } else if label.hasPrefix("com.cocoanetics.") {
            category = String(label.dropFirst("com.cocoanetics.".count))
        } else {
            category = label
        }

        self.osLog = OSLog(subsystem: Self.subsystem, category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let osLogType: OSLogType = switch level {
        case .trace, .debug: .debug
        case .info, .notice: .info
        case .warning: .default
        case .error: .error
        case .critical: .fault
        }

        os_log("%{public}@", log: osLog, type: osLogType, message.description)
    }
}

#endif
