import Foundation

enum TerminalContainerPresentationPolicy {
    static func fallbackBannerMessage(
        activeTransport: ShellTransport,
        fallbackReason: MoshFallbackReason?,
        isDismissed: Bool
    ) -> String? {
        guard activeTransport == .sshFallback else { return nil }
        guard !isDismissed else { return nil }
        return fallbackReason?.bannerMessage ?? String(localized: "Using SSH fallback for this session.")
    }

    static func shouldPromptMoshInstall(
        serverConnectionMode: SSHConnectionMode?,
        activeTransport: ShellTransport,
        fallbackReason: MoshFallbackReason?
    ) -> Bool {
        guard serverConnectionMode == .mosh else { return false }
        guard activeTransport == .sshFallback else { return false }
        return fallbackReason == .serverMissing
    }

    static func shouldShowMoshDurabilityHint(
        serverConnectionMode: SSHConnectionMode?,
        tmuxStatus: TmuxStatus
    ) -> Bool {
        guard serverConnectionMode == .mosh else { return false }
        return tmuxStatus == .off
    }

    static func shouldAllowTerminalInteraction(connectionState: ConnectionState) -> Bool {
        connectionState.isConnected
    }

    static func shouldUseInlineReconnectPresentation(
        hasEstablishedConnection: Bool,
        terminalAlreadyExists: Bool,
        connectionState: ConnectionState
    ) -> Bool {
        hasEstablishedConnection && terminalAlreadyExists && connectionState.isConnecting
    }

    static func isHostKeyVerificationFailure(connectionState: ConnectionState) -> Bool {
        guard case .failed(let error) = connectionState else { return false }
        return error == SSHError.hostKeyVerificationFailed.localizedDescription
            || error.contains("Host key verification failed")
    }

    static func shouldAttemptConnection(
        terminalAlreadyExists: Bool,
        connectionState: ConnectionState
    ) -> Bool {
        terminalAlreadyExists || connectionState.isConnected || connectionState.isConnecting
    }

    static func isFailedState(
        credentialLoadErrorMessage: String?,
        connectionState: ConnectionState
    ) -> Bool {
        if credentialLoadErrorMessage != nil { return true }
        if case .failed = connectionState { return true }
        return false
    }

    static func shouldShowInitializing(
        credentialLoadErrorMessage: String?,
        terminalAlreadyExists: Bool,
        connectionState: ConnectionState,
        isGhosttyReady: Bool,
        isTerminalReady: Bool
    ) -> Bool {
        credentialLoadErrorMessage == nil
            && !terminalAlreadyExists
            && !isFailedState(
                credentialLoadErrorMessage: credentialLoadErrorMessage,
                connectionState: connectionState
            )
            && connectionState != .disconnected
            && (!isGhosttyReady || !isTerminalReady)
    }

    static func shouldShowInitializingOverlay(
        shouldShowInitializing: Bool,
        hasServer: Bool,
        hasCredentials: Bool
    ) -> Bool {
        shouldShowInitializing && hasServer && hasCredentials
    }
}
