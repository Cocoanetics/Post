import ArgumentParser
#if canImport(Darwin)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Logging
import PostServer
import SwiftMCP

@main
struct PostDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "postd",
        abstract: "Post IMAP daemon",
        version: postVersion,
        subcommands: [Start.self, Stop.self, Reload.self, Status.self],
        defaultSubcommand: Start.self
    )
}

extension PostDaemon {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the daemon")
        private static let daemonLogRelativePath = "clawd/mail-room/log/postd-idle.log"

        @Flag(name: .long, help: "Run the daemon in the foreground (useful for debugging).")
        var foreground: Bool = false

        func run() async throws {
            if foreground {
                try await runForeground()
            } else {
                bootstrapDaemonLogging(level: .info)
                try launchDetachedProcess()
            }
        }

        private func launchDetachedProcess() throws {
            let process = Process()
            process.executableURL = try ExecutablePathResolver.currentExecutableURL()
            process.arguments = ["start", "--foreground"]
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

            let devNull = URL(fileURLWithPath: "/dev/null")
            process.standardInput = try? FileHandle(forReadingFrom: devNull)

            let logURL = Self.daemonLogURL
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let logHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? logHandle?.seekToEnd()

            process.standardOutput = logHandle
            process.standardError = logHandle

            try process.run()

            // Poll until the child writes its PID file (max ~3 s) so that
            // `postd status` immediately after `postd start` sees the daemon.
            let expectedPID = process.processIdentifier
            let maxAttempts = 30  // 30 × 100 ms = 3 s
            for _ in 0..<maxAttempts {
                if let writtenPID = try? PIDFileManager.readPID(), writtenPID == expectedPID {
                    break
                }
                usleep(100_000)  // 100 ms
            }

            let logger = Logger(label: "com.cocoanetics.Post.postd")
            logger.info("postd started in background (PID \(expectedPID)).")
        }

        private func runForeground() async throws {
            // Ignore SIGPIPE to prevent crashes on broken sockets and pipes
            signal(SIGPIPE, SIG_IGN)

            try PIDFileManager.ensureNotRunning()

            let configuration = try PostConfiguration.load()

            #if canImport(OSLog)
            LoggingSystem.bootstrap { label in
                var handler = OSLogHandler(label: label)
                handler.logLevel = .trace
                return handler
            }
            #else
            // On Linux, log to stderr and let the process manager handle persistence
            // (systemd → journald, Docker → docker logs, manual → pipe to file).
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = .trace
                return handler
            }
            #endif
            let daemonLogger = Logger(label: "com.cocoanetics.Post.postd")

            let server = PostServer(configuration: configuration)
            var transports: [any Transport] = []

            do {
                let keyCount = try await server.primeAPIKeyScopes()
                daemonLogger.info("API key scopes authorized and loaded (\(keyCount) key(s)).")
            } catch {
                daemonLogger.error("Failed to authorize API key scopes at startup: \(String(describing: error))")
                throw ValidationError(
                    """
                    Unable to access API key scopes in Keychain. Authorize postd for "Post API Keys" and start again.
                    Underlying error: \(error.localizedDescription)
                    """
                )
            }

            let tcpTransport = TCPBonjourTransport(server: server, serviceName: PostServer.Client.serverName)
            transports.append(tcpTransport)

            do {
                if let httpPort = configuration.httpPort {
                    let httpTransport = HTTPSSETransport(server: server, port: httpPort)
                    try await httpTransport.start()
                    transports.append(httpTransport)
                    daemonLogger.info("MCP HTTP+SSE transport listening on http://\(String.localHostname):\(httpTransport.port)/sse")
                }

                try await tcpTransport.start()
                daemonLogger.info("MCP Server \(server.serverName) (\(server.serverVersion)) started with TCP+Bonjour service '\(PostServer.Client.serverName)'.")

                try PIDFileManager.writeCurrentPID()
                daemonLogger.info("PID written to \(PIDFileManager.pidURL.path)")

                // Start configured IMAP IDLE watches (dedicated connections; does not interfere with primary).
                Task {
                    await server.startIdleWatches()
                }

                let signalHandler = SignalHandler(transports: transports, server: server)
                await signalHandler.setup()

                try await tcpTransport.run()

                await server.shutdown()
                try? PIDFileManager.removePIDFile()
                daemonLogger.info("postd stopped.")
            } catch {
                for transport in transports {
                    try? await transport.stop()
                }
                await server.shutdown()
                try? PIDFileManager.removePIDFile()
                daemonLogger.error("postd failed: \(String(describing: error))")
                throw error
            }
        }

        private static var daemonLogURL: URL {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(daemonLogRelativePath)
        }

    
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a running daemon")

        func run() async throws {
            bootstrapDaemonLogging(level: .info)
            let logger = Logger(label: "com.cocoanetics.Post.postd")

            guard let pid = try PIDFileManager.readPID() else {
                logger.info("postd is not running (no PID file).")
                return
            }

            guard PIDFileManager.isProcessRunning(pid) else {
                logger.warning("Stale PID file found for PID \(pid). Removing it.")
                try PIDFileManager.removePIDFile()
                return
            }

            guard kill(pid, SIGTERM) == 0 else {
                throw ValidationError("Failed to send SIGTERM to PID \(pid): \(String(cString: strerror(errno)))")
            }

            logger.info("Sent SIGTERM to postd (PID \(pid)).")

            for _ in 0..<50 {
                if !PIDFileManager.isProcessRunning(pid) {
                    break
                }
                usleep(100_000)
            }

            if PIDFileManager.isProcessRunning(pid) {
                logger.warning("postd is still shutting down.")
            } else {
                try PIDFileManager.removePIDFile()
                logger.info("postd stopped.")
            }
        }
    }

    struct Reload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reload configuration (send SIGHUP)")

        func run() async throws {
            bootstrapDaemonLogging(level: .info)
            let logger = Logger(label: "com.cocoanetics.Post.postd")

            guard let pid = try PIDFileManager.readPID() else {
                logger.info("postd is not running (no PID file).")
                throw ExitCode.failure
            }

            guard PIDFileManager.isProcessRunning(pid) else {
                logger.warning("Stale PID file found for PID \(pid).")
                try PIDFileManager.removePIDFile()
                throw ExitCode.failure
            }

            guard kill(pid, SIGHUP) == 0 else {
                throw ValidationError("Failed to send SIGHUP to PID \(pid): \(String(cString: strerror(errno)))")
            }

            logger.info("Sent SIGHUP to postd (PID \(pid)). Configuration will be reloaded.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show daemon status")

        func run() async throws {
            bootstrapDaemonLogging(level: .info)
            let logger = Logger(label: "com.cocoanetics.Post.postd")

            guard let pid = try PIDFileManager.readPID() else {
                logger.info("postd is not running.")
                return
            }

            if PIDFileManager.isProcessRunning(pid) {
                logger.info("postd is running (PID \(pid)).")
            } else {
                logger.warning("postd is not running (stale PID file for PID \(pid)).")
            }
        }
    }
}

enum ExecutablePathResolver {
    static func currentExecutableURL(
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        argv0: String = CommandLine.arguments.first ?? "postd",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) throws -> URL {
        let fileManager = FileManager.default

        if let bundleExecutableURL,
           bundleExecutableURL.path.hasPrefix("/"),
           fileManager.isExecutableFile(atPath: bundleExecutableURL.path)
        {
            return bundleExecutableURL.standardizedFileURL
        }

        let executableURL = resolveExecutableURL(
            argv0: argv0,
            pathEnvironment: environment["PATH"],
            currentDirectoryPath: currentDirectoryPath,
            fileManager: fileManager
        )

        guard let executableURL else {
            throw ValidationError("Unable to locate the current postd executable for background relaunch.")
        }

        return executableURL
    }

    static func resolveExecutableURL(
        argv0: String,
        pathEnvironment: String?,
        currentDirectoryPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        if argv0.hasPrefix("/") {
            return executableURLIfPresent(at: URL(fileURLWithPath: argv0), fileManager: fileManager)
        }

        if argv0.contains("/") {
            let baseURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
            return executableURLIfPresent(at: baseURL.appendingPathComponent(argv0), fileManager: fileManager)
        }

        guard let pathEnvironment else {
            return nil
        }

        for directory in pathEnvironment.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(argv0)
            if let resolved = executableURLIfPresent(at: candidate, fileManager: fileManager) {
                return resolved
            }
        }

        return nil
    }

    private static func executableURLIfPresent(at url: URL, fileManager: FileManager) -> URL? {
        let standardizedURL = url.standardizedFileURL
        guard fileManager.isExecutableFile(atPath: standardizedURL.path) else {
            return nil
        }
        return standardizedURL
    }
}

private enum PIDFileManager {
    static var pidURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".post.pid")
    }

    static func ensureNotRunning() throws {
        guard let pid = try readPID() else {
            return
        }

        if isProcessRunning(pid) {
            throw ValidationError("postd is already running (PID \(pid)).")
        }

        try removePIDFile()
    }

    static func writeCurrentPID() throws {
        let pid = Int(getpid())
        let data = "\(pid)\n".data(using: .utf8) ?? Data()
        try data.write(to: pidURL, options: .atomic)
    }

    static func readPID() throws -> Int32? {
        guard FileManager.default.fileExists(atPath: pidURL.path) else {
            return nil
        }

        let raw = try String(contentsOf: pidURL, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed) else {
            return nil
        }

        return pid
    }

    static func removePIDFile() throws {
        if FileManager.default.fileExists(atPath: pidURL.path) {
            try FileManager.default.removeItem(at: pidURL)
        }
    }

    static func isProcessRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}

func bootstrapDaemonLogging(level: Logger.Level) {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = level
        return handler
    }
}
