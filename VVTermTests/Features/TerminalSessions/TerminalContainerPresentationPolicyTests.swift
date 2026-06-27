import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect TerminalContainerView's presentation policy for terminal
// lifecycle states. The UI should render status and prompts from these pure
// decisions while application managers own reconnect, credential, install, and
// teardown work. Update these expectations only when terminal connection
// presentation semantics intentionally change.
struct TerminalContainerPresentationPolicyTests {
    @Test
    func fallbackBannerShowsMoshServerMissingReasonUntilDismissed() {
        // Given a Mosh session running through the SSH fallback transport.
        let message = TerminalContainerPresentationPolicy.fallbackBannerMessage(
            activeTransport: .sshFallback,
            fallbackReason: .serverMissing,
            isDismissed: false
        )

        // Then the banner preserves the specific fallback reason for triage.
        #expect(message?.contains("mosh-server is missing") == true)

        // And a user-dismissed fallback banner stays hidden.
        let dismissed = TerminalContainerPresentationPolicy.fallbackBannerMessage(
            activeTransport: .sshFallback,
            fallbackReason: .serverMissing,
            isDismissed: true
        )
        #expect(dismissed == nil)
    }

    @Test
    func moshInstallPromptRequiresMoshServerMissingFallback() {
        // Given a server configured for Mosh but no server-side mosh-server.
        let shouldPrompt = TerminalContainerPresentationPolicy.shouldPromptMoshInstall(
            serverConnectionMode: .mosh,
            activeTransport: .sshFallback,
            fallbackReason: .serverMissing
        )

        // Then the terminal may ask to install mosh-server.
        #expect(shouldPrompt)

        // But generic SSH fallback failures do not imply an install flow.
        let bootstrapFailure = TerminalContainerPresentationPolicy.shouldPromptMoshInstall(
            serverConnectionMode: .mosh,
            activeTransport: .sshFallback,
            fallbackReason: .bootstrapFailed
        )
        #expect(!bootstrapFailure)
    }

    @Test
    func hostKeyVerificationFailuresStayRecognizable() {
        // Given both typed and raw host-key failure strings seen by the UI.
        let typed = TerminalContainerPresentationPolicy.isHostKeyVerificationFailure(
            connectionState: .failed(SSHError.hostKeyVerificationFailed.localizedDescription)
        )
        let raw = TerminalContainerPresentationPolicy.isHostKeyVerificationFailure(
            connectionState: .failed("Host key verification failed for example.com")
        )

        // Then both forms keep the retrust affordance available.
        #expect(typed)
        #expect(raw)

        // And unrelated failures do not expose the destructive retrust action.
        let unrelated = TerminalContainerPresentationPolicy.isHostKeyVerificationFailure(
            connectionState: .failed("Authentication failed")
        )
        #expect(!unrelated)
    }

    @Test
    func initializingOverlayRequiresPendingTerminalStartupWithCredentials() {
        // Given a new terminal whose Ghostty app is ready but terminal surface is not.
        let shouldInitialize = TerminalContainerPresentationPolicy.shouldShowInitializing(
            credentialLoadErrorMessage: nil,
            terminalAlreadyExists: false,
            connectionState: .connecting,
            isGhosttyReady: true,
            isTerminalReady: false
        )

        // Then the initializing state is visible only once server and credentials exist.
        #expect(shouldInitialize)
        #expect(TerminalContainerPresentationPolicy.shouldShowInitializingOverlay(
            shouldShowInitializing: shouldInitialize,
            hasServer: true,
            hasCredentials: true
        ))
        #expect(!TerminalContainerPresentationPolicy.shouldShowInitializingOverlay(
            shouldShowInitializing: shouldInitialize,
            hasServer: true,
            hasCredentials: false
        ))
    }

    @Test
    func inlineReconnectRequiresExistingRuntimeAfterAConnectionWasEstablished() {
        // Given a previously connected session whose terminal surface still exists.
        let shouldInline = TerminalContainerPresentationPolicy.shouldUseInlineReconnectPresentation(
            hasEstablishedConnection: true,
            terminalAlreadyExists: true,
            connectionState: .reconnecting(attempt: 2)
        )

        // Then reconnecting is shown inline instead of as initial connection setup.
        #expect(shouldInline)

        // But first-time connection attempts should not use reconnect presentation.
        let firstConnect = TerminalContainerPresentationPolicy.shouldUseInlineReconnectPresentation(
            hasEstablishedConnection: false,
            terminalAlreadyExists: false,
            connectionState: .connecting
        )
        #expect(!firstConnect)
    }
}
