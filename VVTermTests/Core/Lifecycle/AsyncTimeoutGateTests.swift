import XCTest
@testable import VVTerm

// Test Context:
// These tests protect AsyncTimeoutGate as the shared lifecycle timeout primitive
// for teardown paths whose underlying task may not cooperate with cancellation.
// Fakes use local continuations only; update these tests if lifecycle owners no
// longer need bounded waits around non-structured external cleanup.

final class AsyncTimeoutGateTests: XCTestCase {
    func testWaitForTaskReturnsOnTimeoutWhenTaskDoesNotResume() async throws {
        // Given a task representing external cleanup that never resumes.
        let neverFinishingTask = Task<Void, Error> {
            try await withCheckedThrowingContinuation { (_: CheckedContinuation<Void, Error>) in
                // Intentionally never resumed.
            }
        }
        defer { neverFinishingTask.cancel() }

        let startedAt = ContinuousClock.now

        // When a lifecycle owner waits through the timeout gate.
        do {
            try await AsyncTimeoutGate.waitForTask(
                neverFinishingTask,
                timeout: .milliseconds(60),
                timeoutError: { SSHError.timeout }
            )
            XCTFail("Expected AsyncTimeoutGate to throw the provided timeout error")
        } catch SSHError.timeout {
            // Then the caller resumes from the timeout rather than being held
            // by the non-cooperative cleanup task.
        } catch {
            XCTFail("Expected SSHError.timeout, got \(error)")
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "AsyncTimeoutGate should not structurally wait for the never-finishing task after timing out."
        )
    }
}
