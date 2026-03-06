import Foundation
import Logging
import OSLog

/// A swift-log backend that routes all log messages to Apple's unified logging system (Console.app).
/// The swift-log `label` becomes the OSLog `subsystem`.
struct OSLogHandler: Logging.LogHandler {
    let subsystem: String
    private let osLog: OSLog

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    init(label: String) {
        self.subsystem = label
        self.osLog = OSLog(subsystem: label, category: "")
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
