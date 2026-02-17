import ArgumentParser
import Darwin
import Foundation
import Logging
import PostServer
import SwiftMCP

@main
struct PostDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "postd",
        abstract: "Post IMAP daemon",
        subcommands: [Start.self, Stop.self, Reload.self, Status.self],
        defaultSubcommand: Start.self
    )
}

extension PostDaemon {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the daemon")

        @Flag(name: .long, help: "Run the daemon in the foreground (useful for debugging).")
        var foreground: Bool = false

        func run() async throws {
            if foreground {
                try await runForeground()
            } else {
                try launchDetachedProcess()
            }
        }

        private func launchDetachedProcess() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["start", "--foreground"]
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

            let devNull = URL(fileURLWithPath: "/dev/null")
            process.standardInput = try? FileHandle(forReadingFrom: devNull)
            let nullOutput = try? FileHandle(forWritingTo: devNull)
            process.standardOutput = nullOutput
            process.standardError = nullOutput

            try process.run()
            logToStderr("postd started in background (PID \(process.processIdentifier)).")
        }

        private func runForeground() async throws {
            try PIDFileManager.ensureNotRunning()

            let configuration = try PostConfiguration.load()

            #if canImport(OSLog)
            LoggingSystem.bootstrapWithOSLog(subsystem: "com.cocoanetics.Post")
            #endif

            let server = PostServer(configuration: configuration)
            var transports: [any Transport] = []

            let tcpTransport = TCPBonjourTransport(server: server, serviceName: PostServer.Client.serverName)
            transports.append(tcpTransport)

            do {
                if let httpPort = configuration.httpPort {
                    let httpTransport = HTTPSSETransport(server: server, port: httpPort)
                    try await httpTransport.start()
                    transports.append(httpTransport)
                    logToStderr("MCP HTTP+SSE transport listening on http://\(String.localHostname):\(httpTransport.port)/sse")
                }

                try await tcpTransport.start()
                logToStderr("MCP Server \(server.serverName) (\(server.serverVersion)) started with TCP+Bonjour service '\(PostServer.Client.serverName)'.")

                try PIDFileManager.writeCurrentPID()
                logToStderr("PID written to \(PIDFileManager.pidURL.path)")

                // Start configured IMAP IDLE watches (dedicated connections; does not interfere with primary).
                Task {
                    await server.startIdleWatches()
                }

                let signalHandler = SignalHandler(transports: transports, server: server)
                await signalHandler.setup()

                try await tcpTransport.run()

                await server.shutdown()
                try? PIDFileManager.removePIDFile()
                logToStderr("postd stopped.")
            } catch {
                for transport in transports {
                    try? await transport.stop()
                }
                await server.shutdown()
                try? PIDFileManager.removePIDFile()
                throw error
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a running daemon")

        func run() async throws {
            guard let pid = try PIDFileManager.readPID() else {
                logToStderr("postd is not running (no PID file).")
                return
            }

            guard PIDFileManager.isProcessRunning(pid) else {
                logToStderr("Stale PID file found for PID \(pid). Removing it.")
                try PIDFileManager.removePIDFile()
                return
            }

            guard kill(pid, SIGTERM) == 0 else {
                throw ValidationError("Failed to send SIGTERM to PID \(pid): \(String(cString: strerror(errno)))")
            }

            logToStderr("Sent SIGTERM to postd (PID \(pid)).")

            for _ in 0..<50 {
                if !PIDFileManager.isProcessRunning(pid) {
                    break
                }
                usleep(100_000)
            }

            if PIDFileManager.isProcessRunning(pid) {
                logToStderr("postd is still shutting down.")
            } else {
                try PIDFileManager.removePIDFile()
                logToStderr("postd stopped.")
            }
        }
    }

    struct Reload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reload configuration (send SIGHUP)")

        func run() async throws {
            guard let pid = try PIDFileManager.readPID() else {
                logToStderr("postd is not running (no PID file).")
                throw ExitCode.failure
            }

            guard PIDFileManager.isProcessRunning(pid) else {
                logToStderr("Stale PID file found for PID \(pid).")
                try PIDFileManager.removePIDFile()
                throw ExitCode.failure
            }

            guard kill(pid, SIGHUP) == 0 else {
                throw ValidationError("Failed to send SIGHUP to PID \(pid): \(String(cString: strerror(errno)))")
            }

            logToStderr("Sent SIGHUP to postd (PID \(pid)). Configuration will be reloaded.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show daemon status")

        func run() async throws {
            guard let pid = try PIDFileManager.readPID() else {
                logToStderr("postd is not running.")
                return
            }

            if PIDFileManager.isProcessRunning(pid) {
                logToStderr("postd is running (PID \(pid)).")
            } else {
                logToStderr("postd is not running (stale PID file for PID \(pid)).")
            }
        }
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

func logToStderr(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else {
        return
    }

    try? FileHandle.standardError.write(contentsOf: data)
}
