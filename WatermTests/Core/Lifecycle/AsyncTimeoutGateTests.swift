import XCTest
@testable import Waterm

// Test Context:
// These tests protect AsyncTimeoutGate as the shared lifecycle timeout primitive
// for teardown paths whose underlying task may not cooperate with cancellation.
// Fakes use local continuations only; update these tests if lifecycle owners no
// longer need bounded waits around non-structured external cleanup.

final class AsyncTimeoutGateTests: XCTestCase {
    func testWaitForTaskReturnsOnTimeoutWhenCleanupIgnoresCancellation() async throws {
        // Given a task representing external cleanup that ignores cancellation
        // and only resumes well after the lifecycle timeout.
        let slowCleanupTask = Task<Void, Error> {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    continuation.resume(returning: ())
                }
            }
        }
        defer { slowCleanupTask.cancel() }

        let startedAt = ContinuousClock.now

        // When a lifecycle owner waits through the timeout gate.
        do {
            try await AsyncTimeoutGate.waitForTask(
                slowCleanupTask,
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
            .milliseconds(500),
            "AsyncTimeoutGate should return on timeout instead of waiting for a cancellation-uncooperative cleanup task to resume."
        )
    }
}
