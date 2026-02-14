import Darwin
import Dispatch
import Foundation
import PostServer
import SwiftMCP

public final class SignalHandler {
    private actor State {
        private var sources: [DispatchSourceSignal] = []
        private var isShuttingDown = false
        private var transports: [any Transport]
        private var server: PostServer?

        init(transports: [any Transport], server: PostServer?) {
            self.transports = transports
            self.server = server
        }

        func setup(on queue: DispatchQueue) {
            install(signal: SIGINT, on: queue)
            install(signal: SIGTERM, on: queue)
            install(signal: SIGHUP, on: queue)
        }

        private func install(signal signalValue: Int32, on queue: DispatchQueue) {
            Darwin.signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: queue)

            source.setEventHandler { [weak self] in
                guard let self else { return }
                let captured = self
                Task {
                    await captured.handle(signal: signalValue)
                }
            }

            source.resume()
            sources.append(source)
        }

        private func handle(signal signalValue: Int32) async {
            if signalValue == SIGHUP {
                logToStderr("Received SIGHUP, reloading configuration...")
                await server?.reloadConfiguration()
                return
            }

            guard !isShuttingDown else {
                return
            }
            isShuttingDown = true

            let signalName = signalValue == SIGTERM ? "SIGTERM" : "SIGINT"
            logToStderr("Received \(signalName), shutting down transports...")

            for transport in transports {
                do {
                    try await transport.stop()
                } catch {
                    logToStderr("Transport shutdown error: \(error)")
                }
            }
        }
    }

    private let state: State

    public init(transports: [any Transport], server: PostServer? = nil) {
        self.state = State(transports: transports, server: server)
    }

    public func setup() async {
        let queue = DispatchQueue(label: "com.cocoanetics.Post.signal")
        await state.setup(on: queue)
    }
}
