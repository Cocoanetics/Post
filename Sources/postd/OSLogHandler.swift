import Foundation
import Logging
import OSLog

/// A swift-log backend that routes all log messages to Apple's unified logging system (Console.app).
/// Uses a fixed subsystem and derives the OSLog category from the swift-log label.
struct OSLogHandler: Logging.LogHandler {
    static let subsystem = "com.cocoanetics.Post"

    private let osLog: OSLog
    let category: String

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    init(label: String) {
        // Derive category by stripping the common subsystem prefix.
        // e.g. "com.cocoanetics.Post.IDLE.Diagnostics" → "IDLE.Diagnostics"
        //      "com.cocoanetics.SwiftMail.IMAP_IN.xyz" → "SwiftMail.IMAP_IN.xyz"
        let prefix = Self.subsystem + "."
        if label.hasPrefix(prefix) {
            self.category = String(label.dropFirst(prefix.count))
        } else if label.hasPrefix("com.cocoanetics.") {
            self.category = String(label.dropFirst("com.cocoanetics.".count))
        } else {
            self.category = label
        }
        self.osLog = OSLog(subsystem: Self.subsystem, category: self.category)
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
        case .trace: .debug
        case .debug: .debug
        case .info, .notice: .info
        case .warning: .default
        case .error: .error
        case .critical: .fault
        }

        os_log("%{public}@", log: osLog, type: osLogType, "\(message)")
    }
}
