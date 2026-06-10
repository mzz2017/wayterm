import Testing
@testable import VVTerm

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
}
