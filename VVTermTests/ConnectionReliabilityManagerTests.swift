import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the TerminalSessions reconnect reliability actor. The
// actor owns retry policy and backoff ordering, while the actual reconnect
// operation is injected so lifecycle orchestration does not depend directly on
// ConnectionSessionManager.shared. Update these tests when the intended retry
// policy changes, not when the concrete manager wiring changes.
@Suite(.serialized)
struct ConnectionReliabilityManagerTests {
    @Test
    func handleDisconnectSkipsReconnectWhenAutoReconnectIsDisabled() async {
        // Given a session whose auto-reconnect preference is disabled.
        let session = makeSession(autoReconnect: false)
        let probe = ConnectionReliabilityProbe()
        let manager = ConnectionReliabilityManager(
            reconnect: { _ in
                await probe.recordReconnect()
            },
            delay: { interval in
                await probe.recordDelay(interval)
            }
        )

        // When the disconnect is handled.
        await manager.handleDisconnect(session: session)

        // Then no retry work is scheduled.
        #expect(await probe.reconnectAttempts() == 0, "Disabled auto-reconnect should not call reconnect.")
        #expect(await probe.delays() == [], "Disabled auto-reconnect should not schedule backoff delays.")
    }

    @Test
    func handleDisconnectRetriesWithExponentialBackoffUntilReconnectSucceeds() async {
        // Given reconnect fails twice before succeeding.
        let session = makeSession()
        let probe = ConnectionReliabilityProbe(failuresBeforeSuccess: 2)
        let manager = ConnectionReliabilityManager(
            maxAttempts: 3,
            baseDelay: 0.5,
            reconnect: { _ in
                try await probe.reconnect()
            },
            delay: { interval in
                await probe.recordDelay(interval)
            }
        )

        // When the disconnect is handled.
        await manager.handleDisconnect(session: session)

        // Then each attempt waits for the expected exponential delay and stops
        // after the first successful reconnect.
        #expect(await probe.reconnectAttempts() == 3, "Reconnect should stop after the first successful attempt.")
        #expect(await probe.delays() == [0.5, 1.0, 2.0], "Reconnect backoff should double for each attempt.")
    }

    @Test
    func handleDisconnectStopsWhenBackoffIsCancelled() async {
        // Given the backoff delay is cancelled before reconnect can run.
        let session = makeSession()
        let probe = ConnectionReliabilityProbe()
        let manager = ConnectionReliabilityManager(
            reconnect: { _ in
                await probe.recordReconnect()
            },
            delay: { interval in
                await probe.recordDelay(interval)
                throw CancellationError()
            }
        )

        // When the disconnect is handled.
        await manager.handleDisconnect(session: session)

        // Then cancellation ends the lifecycle without treating it as a retry
        // failure.
        #expect(await probe.reconnectAttempts() == 0, "Cancelled backoff should not reconnect afterwards.")
        #expect(await probe.delays() == [1.0], "Cancellation should stop after the in-flight delay.")
    }

    private func makeSession(autoReconnect: Bool = true) -> ConnectionSession {
        ConnectionSession(
            serverId: UUID(),
            title: "Reconnect Target",
            autoReconnect: autoReconnect
        )
    }
}

private actor ConnectionReliabilityProbe {
    private var attemptCount = 0
    private var recordedDelays: [TimeInterval] = []
    private let failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func reconnect() throws {
        attemptCount += 1
        if attemptCount <= failuresBeforeSuccess {
            throw ConnectionReliabilityProbeError.reconnectFailed
        }
    }

    func recordReconnect() {
        attemptCount += 1
    }

    func recordDelay(_ interval: TimeInterval) {
        recordedDelays.append(interval)
    }

    func reconnectAttempts() -> Int {
        attemptCount
    }

    func delays() -> [TimeInterval] {
        recordedDelays
    }
}

private enum ConnectionReliabilityProbeError: Error {
    case reconnectFailed
}
