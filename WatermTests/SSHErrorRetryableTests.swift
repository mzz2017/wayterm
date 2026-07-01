import Testing
@testable import Waterm

// Test Context:
// These tests protect SSH retry classification. Authentication, host-key, and
// explicit user-auth rejection errors are deterministic and should not be
// retried, while transport and raw libssh2 failures remain retryable unless a
// narrower non-retryable contract is introduced. Update these tests only when
// the connection retry policy intentionally changes.

struct SSHErrorRetryableTests {
    @Test func authenticationFailedIsNotRetryable() {
        #expect(SSHError.authenticationFailed.isRetryable == false)
    }

    @Test func hostKeyVerificationFailedIsNotRetryable() {
        #expect(SSHError.hostKeyVerificationFailed.isRetryable == false)
    }

    @Test func tailscaleAuthNotAcceptedIsNotRetryable() {
        #expect(SSHError.tailscaleAuthenticationNotAccepted.isRetryable == false)
    }

    @Test func timeoutIsRetryable() {
        #expect(SSHError.timeout.isRetryable == true)
    }

    @Test func socketErrorIsRetryable() {
        #expect(SSHError.socketError("boom").isRetryable == true)
    }

    @Test func rawLibSSH2ErrorIsRetryable() {
        let rawError = LibSSH2RawError(
            operation: .handshake,
            code: -13,
            message: "socket recv failed"
        )

        #expect(SSHError.libssh2(rawError).isRetryable == true)
    }
}
