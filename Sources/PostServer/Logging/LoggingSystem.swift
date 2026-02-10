import Foundation
import Logging

#if canImport(OSLog)
import OSLog

public extension LoggingSystem {
    static func bootstrapWithOSLog(
        subsystem: String = "com.cocoanetics.Post",
        logLevel: Logging.Logger.Level = ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" ? .trace : .info
    ) {
        bootstrap { label in
            let category = label.split(separator: ".").last?.description ?? "default"
            let osLogger = OSLog(subsystem: subsystem, category: category)

            var handler = OSLogHandler(label: label, log: osLogger)
            handler.logLevel = logLevel
            return handler
        }
    }
}
#endif
