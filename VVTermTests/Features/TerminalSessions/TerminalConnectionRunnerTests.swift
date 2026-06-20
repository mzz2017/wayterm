import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal SSH runner retry policy without opening a real
// network connection or terminal. The runner owns attempt ordering for UI-created
// terminal connections; deterministic SSH failures such as authentication errors
// must not be retried because repeated auth attempts can trigger server-side
// penalties and surface misleading SSH errors.
//
// Fakes and assumptions: TerminalConnectionRunnerProbe is a test-only fake that
// returns configured errors from each attempt and records the final user-facing
// state. Update these tests only if VVTerm intentionally changes its retry
// policy for non-retryable SSHError cases.
final class TerminalConnectionRunnerTests: XCTestCase {
    func testNonRetryableAuthenticationFailureDoesNotRetry() async {
        let probe = TerminalConnectionRunnerProbe(errors: [SSHError.authenticationFailed])

        await TerminalConnectionRunner.runForTesting(
            onAttempt: { _ in },
            performAttempt: { attempt in
                try await probe.performAttempt(attempt)
            },
            onFailure: { error in
                await probe.recordFailure(error)
            }
        )

        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)

        let finalState = await probe.finalState
        XCTAssertEqual(finalState, ConnectionState.failed("Authentication failed"))
    }
}

private actor TerminalConnectionRunnerProbe {
    private let errors: [Error]
    private(set) var attempts = 0
    private(set) var finalState: ConnectionState?

    init(errors: [Error]) {
        self.errors = errors
    }

    func performAttempt(_ attempt: Int) async throws {
        attempts += 1
        guard attempt <= errors.count else { return }
        throw errors[attempt - 1]
    }

    func recordFailure(_ error: Error) {
        finalState = .failed(error.localizedDescription)
    }
}
