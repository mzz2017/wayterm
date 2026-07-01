import Foundation

extension TerminalTabManager {
    func shouldScheduleConnectWatchdog(
        forPaneId paneId: UUID,
        isReady: Bool,
        terminalExists: Bool
    ) -> Bool {
        guard let state = paneStates[paneId]?.connectionState else { return false }
        return state.isConnecting || (state.isConnected && !isReady && !terminalExists)
    }

    func scheduleConnectWatchdog(
        forPaneId paneId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeout: Duration = .seconds(20),
        timeoutMessage: String,
        onRetry: @escaping @MainActor () async -> Void
    ) {
        connectWatchdogStore.removeTask(for: paneId)?.cancel()

        guard shouldScheduleConnectWatchdog(
            forPaneId: paneId,
            isReady: isReady,
            terminalExists: terminalExists
        ) else {
            connectWatchdogStore.clear(for: paneId)?.cancel()
            return
        }

        let generation = connectWatchdogStore.beginGeneration(for: paneId)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.connectWatchdogStore.isCurrent(generation, for: paneId) else { return }

            let action = self.handleConnectWatchdogTimeout(
                forPaneId: paneId,
                isReady: isReady,
                terminalExists: terminalExists,
                timeoutMessage: timeoutMessage
            )

            switch action {
            case .retry:
                self.connectWatchdogStore.clear(for: paneId)
                await onRetry()
            case .continueWatching:
                self.scheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: isReady,
                    terminalExists: terminalExists,
                    timeout: timeout,
                    timeoutMessage: timeoutMessage,
                    onRetry: onRetry
                )
            case .none:
                self.connectWatchdogStore.clear(for: paneId)
            }
        }
        connectWatchdogStore.setTask(task, for: paneId)
    }

    func handleConnectWatchdogTimeout(
        forPaneId paneId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeoutMessage: String
    ) -> TerminalConnectWatchdogAction {
        guard let state = paneStates[paneId]?.connectionState else { return .none }
        let connectedWithoutTerminal = state.isConnected && !isReady && !terminalExists
        guard state.isConnecting || connectedWithoutTerminal else { return .none }

        if connectedWithoutTerminal {
            updatePaneState(paneId, connectionState: .disconnected)
            return .retry
        }

        if shellId(for: paneId) != nil {
            updatePaneState(paneId, connectionState: .connected)
            return .none
        }

        if isShellStartInFlight(for: paneId) {
            return .continueWatching
        }

        updatePaneState(paneId, connectionState: .failed(timeoutMessage))
        return .none
    }
}
