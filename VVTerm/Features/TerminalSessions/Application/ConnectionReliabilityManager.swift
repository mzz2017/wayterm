//
//  ConnectionReliabilityManager.swift
//  VVTerm
//
//  Reconnect reliability policy for terminal sessions.
//

import Foundation

actor ConnectionReliabilityManager {
    typealias ReconnectOperation = @MainActor @Sendable (ConnectionSession) async throws -> Void
    typealias DelayOperation = @Sendable (TimeInterval) async throws -> Void

    private var reconnectAttempts = 0
    private let maxAttempts: Int
    private let baseDelay: TimeInterval
    private let reconnect: ReconnectOperation
    private let delay: DelayOperation

    init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        reconnect: @escaping ReconnectOperation = ConnectionReliabilityManager.liveReconnect,
        delay: @escaping DelayOperation = ConnectionReliabilityManager.liveDelay
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.reconnect = reconnect
        self.delay = delay
    }

    func handleDisconnect(session: ConnectionSession) async {
        guard session.autoReconnect else { return }

        while reconnectAttempts < maxAttempts {
            reconnectAttempts += 1
            let delay = baseDelay * pow(2, Double(reconnectAttempts - 1))

            do {
                try await self.delay(delay)
                try await reconnect(session)
                reconnectAttempts = 0
                return
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    func resetAttempts() {
        reconnectAttempts = 0
    }

    private static func liveDelay(_ interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}
