import Foundation
import Logging

#if canImport(OSLog)

@preconcurrency import OSLog

/// A swift-log backend that routes all log messages to Apple's unified logging system (Console.app).
///
/// Derives subsystem and category from the swift-log label:
/// - Subsystem = first 3 dot-segments (e.g. `com.cocoanetics.Post`)
/// - Category = 4th segment only (e.g. `IDLE`, `IMAP_IN`, `postd`)
/// - Instance-specific suffixes (connection IDs, server names) stay in the message.
struct OSLogHandler: Logging.LogHandler {
    let label: String
    private let osLog: OSLog

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    init(label: String) {
        self.label = label

        let parts = label.split(separator: ".", maxSplits: 4)

        // Subsystem: first 3 segments (e.g. "com.cocoanetics.Post")
        let subsystem: String
        if parts.count >= 3 {
            subsystem = parts[0...2].joined(separator: ".")
        } else {
            subsystem = label
        }

        // Category: 4th segment only (e.g. "IDLE", "IMAP_IN", "postd", "TCPBonjourTransport")
        let category: String
        if parts.count >= 4 {
            category = String(parts[3])
        } else {
            category = "general"
        }

        self.osLog = OSLog(subsystem: subsystem, category: category)
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
