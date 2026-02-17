import Foundation
import Logging
import SwiftMail

struct IdleWatchConfiguration: Sendable {
    let serverId: String
    let mailbox: String
    let command: String?
}

struct RawIdleEvent: Sendable {
    let serverId: String
    let mailbox: String
    let event: IMAPServerEvent
}

extension IMAPConnectionManager {
    nonisolated func idleEventStream(
        serverId: String,
        mailbox: String,
        reconnectDelayNanoseconds: UInt64 = 3_000_000_000
    ) -> AsyncStream<RawIdleEvent> {
        AsyncStream { continuation in
            let logger = Logger(label: "com.cocoanetics.Post.IDLE.Stream.\(serverId)")

            let producerTask = Task {
                while !Task.isCancelled {
                    do {
                        let server = try await connection(for: serverId)
                        let idleSession = try await server.idle(on: mailbox)
                        let rawEvents = idleSession.events.map { event in
                            RawIdleEvent(serverId: serverId, mailbox: mailbox, event: event)
                        }

                        for await rawEvent in rawEvents {
                            if Task.isCancelled { break }
                            continuation.yield(rawEvent)

                            if case .bye = rawEvent.event {
                                logger.warning("Session IDLE stream received BYE for \(serverId)/\(mailbox); reconnecting")
                                break
                            }
                        }

                        try? await idleSession.done()

                        if Task.isCancelled { break }
                        logger.warning("Session IDLE stream ended for \(serverId)/\(mailbox); reconnecting")
                    } catch {
                        if Task.isCancelled { break }
                        logger.warning("Session IDLE watch failed for \(serverId)/\(mailbox): \(String(describing: error))")
                    }

                    try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                producerTask.cancel()
            }
        }
    }

    nonisolated func idleEventStreams(for watchConfigurations: [IdleWatchConfiguration]) -> [AsyncStream<RawIdleEvent>] {
        watchConfigurations.map { watchConfiguration in
            idleEventStream(serverId: watchConfiguration.serverId, mailbox: watchConfiguration.mailbox)
        }
    }
}

extension Array where Element == IdleWatchConfiguration {
    func idleEventStreams(using connectionManager: IMAPConnectionManager) -> [AsyncStream<RawIdleEvent>] {
        connectionManager.idleEventStreams(for: self)
    }

    func mergedIdleEventStream(using connectionManager: IMAPConnectionManager) -> AsyncStream<RawIdleEvent> {
        idleEventStreams(using: connectionManager).mergedIdleEventStream()
    }
}

extension Array where Element == AsyncStream<RawIdleEvent> {
    func mergedIdleEventStream() -> AsyncStream<RawIdleEvent> {
        let streams = self

        return AsyncStream { continuation in
            let mergeTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    for stream in streams {
                        group.addTask {
                            for await event in stream {
                                continuation.yield(event)
                            }
                        }
                    }

                    await group.waitForAll()
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                mergeTask.cancel()
            }
        }
    }
}
