import Foundation

extension ConnectionSessionManager {
    func shouldScheduleConnectWatchdog(
        forSessionId sessionId: UUID,
        isReady: Bool,
        terminalExists: Bool
    ) -> Bool {
        guard let state = sessionState(for: sessionId) else { return false }
        return state.isConnecting || (state.isConnected && !isReady && !terminalExists)
    }

    func scheduleConnectWatchdog(
        forSessionId sessionId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeout: Duration = .seconds(20),
        timeoutMessage: String,
        onRetry: @escaping @MainActor () async -> Void
    ) {
        connectWatchdogStore.removeTask(for: sessionId)?.cancel()

        guard shouldScheduleConnectWatchdog(
            forSessionId: sessionId,
            isReady: isReady,
            terminalExists: terminalExists
        ) else {
            connectWatchdogStore.clear(for: sessionId)?.cancel()
            return
        }

        let generation = connectWatchdogStore.beginGeneration(for: sessionId)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.connectWatchdogStore.isCurrent(generation, for: sessionId) else { return }

            let action = self.handleConnectWatchdogTimeout(
                forSessionId: sessionId,
                isReady: isReady,
                terminalExists: terminalExists,
                timeoutMessage: timeoutMessage
            )

            switch action {
            case .retry:
                self.connectWatchdogStore.clear(for: sessionId)
                await onRetry()
            case .continueWatching:
                self.scheduleConnectWatchdog(
                    forSessionId: sessionId,
                    isReady: isReady,
                    terminalExists: terminalExists,
                    timeout: timeout,
                    timeoutMessage: timeoutMessage,
                    onRetry: onRetry
                )
            case .none:
                self.connectWatchdogStore.clear(for: sessionId)
            }
        }
        connectWatchdogStore.setTask(task, for: sessionId)
    }

    func handleConnectWatchdogTimeout(
        forSessionId sessionId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeoutMessage: String
    ) -> TerminalConnectWatchdogAction {
        guard let state = sessionState(for: sessionId) else { return .none }
        let connectedWithoutTerminal = state.isConnected && !isReady && !terminalExists
        guard state.isConnecting || connectedWithoutTerminal else { return .none }

        if connectedWithoutTerminal {
            updateSessionState(sessionId, to: .disconnected)
            return .retry
        }

        if shellId(for: sessionId) != nil {
            updateSessionState(sessionId, to: .connected)
            return .none
        }

        if isShellStartInFlight(for: sessionId) {
            return .continueWatching
        }

        updateSessionState(sessionId, to: .failed(timeoutMessage))
        return .none
    }
}
