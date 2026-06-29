import Foundation
import Testing
import Umami
@testable import VVTerm

// Test Context:
// Protects anonymous analytics as a non-critical telemetry owner. Event sends
// may stay off the MainActor, but the owner must still publish pending work so
// app-level tests and teardown diagnostics can wait for in-flight telemetry.
// Update these tests only if analytics becomes intentionally best-effort with
// no owner-visible flush contract.

@MainActor
struct AnalyticsTrackerTests {
    @Test
    func waitForPendingEventsWaitsForInFlightTelemetrySend() async {
        let client = BlockingAnalyticsClient()
        let defaults = UserDefaults(suiteName: "AnalyticsTrackerTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: AnalyticsTracker.enabledKey)
        let tracker = AnalyticsTracker(client: client, defaults: defaults)

        // Given an analytics event whose transport send has started but not finished.
        tracker.trackConnectionSucceeded(transport: "ssh")
        await client.waitForTrackCallCount(1)

        // When the owner is asked to flush pending telemetry work.
        let completion = AnalyticsFlushCompletionProbe()
        let waitTask = Task {
            await tracker.waitForPendingEvents()
            await completion.markFinished()
        }
        await Task.yield()

        // Then the flush remains pending until the transport send actually exits.
        #expect(
            await !completion.isFinished,
            "Analytics flush must not finish while the tracked transport send is still running."
        )

        await client.release()
        await waitTask.value
        #expect(await completion.isFinished)
        #expect(
            await client.eventNames == ["connection_succeeded"],
            "Analytics should send exactly the requested event through the injected transport."
        )
    }
}

private actor BlockingAnalyticsClient: AnalyticsTrackingClient {
    private var trackCallCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var eventNames: [String] = []

    func track(_ event: TrackEventRequest) async throws {
        eventNames.append(event.name ?? "")
        trackCallCount += 1
        waiters.forEach { $0.resume() }
        waiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForTrackCallCount(_ expectedCount: Int) async {
        guard trackCallCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AnalyticsFlushCompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
