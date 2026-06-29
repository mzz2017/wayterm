import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Security.framework FFI boundary used by RSA SSH key
// generation. Security APIs return retained CFError values through Unmanaged
// output parameters; production code must consume those values exactly once and
// preserve raw diagnostic detail internally without changing user-facing copy.
// Fakes create local CFError values only; update these tests only if the RSA key
// generation backend moves away from Security.framework.

struct SSHKeyGeneratorErrorDetailTests {
    @Test
    func retainedCFErrorDetailConsumesErrorAndPreservesRawDescription() {
        // Given a retained CFError returned through a Security.framework-style
        // Unmanaged output parameter.
        let userInfo = [
            kCFErrorDescriptionKey: "Security denied test key generation" as CFString
        ] as CFDictionary
        let cfError = CFErrorCreate(
            kCFAllocatorDefault,
            "VVTerm.SecurityTest" as CFString,
            -42,
            userInfo
        )!
        var retainedError: Unmanaged<CFError>? = Unmanaged.passRetained(cfError)

        // When the SSH key generator consumes the retained error detail.
        let detail = SecurityFrameworkErrorDetail.takeRetainedDescription(&retainedError)

        // Then ownership is consumed and raw diagnostics remain available for
        // internal logging/debugging.
        #expect(retainedError == nil)
        #expect(detail?.contains("VVTerm.SecurityTest") == true)
        #expect(detail?.contains("-42") == true)
        #expect(detail?.contains("Security denied test key generation") == true)
    }

    @Test
    func generatorErrorKeepsUserFacingCopyGenericWhilePreservingRawDetail() {
        // Given an RSA key-generation failure backed by a raw Security detail.
        let error = SSHKeyGeneratorError.keyGenerationFailed(
            underlyingDescription: "VVTerm.SecurityTest -42 Security denied test key generation"
        )

        // Then UI-facing copy remains stable, while internal diagnostics keep
        // the low-level Security.framework detail.
        #expect(error.errorDescription == "Failed to generate SSH key")
        #expect(error.underlyingSecurityErrorDescription?.contains("VVTerm.SecurityTest") == true)
        #expect(error.underlyingSecurityErrorDescription?.contains("-42") == true)
    }
}
