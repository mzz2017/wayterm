import Foundation

extension ConnectionReliabilityManager {
    @MainActor
    static func liveReconnect(session: ConnectionSession) async throws {
        try await ConnectionSessionManager.shared.reconnect(session: session)
    }
}

extension ConnectionSessionManager.Dependencies {
    static var live: Self {
        Self(
            serverProvider: { serverId in
                ServerManager.shared.servers.first { $0.id == serverId }
            },
            serverLockPolicy: { server in
                ServerManager.shared.isServerLocked(server)
            },
            serverUnlocker: { server in
                await AppLockManager.shared.ensureServerUnlocked(server)
            },
            lastConnectedUpdater: { server in
                await ServerManager.shared.updateLastConnected(for: server)
            },
            isProProvider: {
                StoreManager.shared.isPro
            },
            credentialsProvider: { server in
                try KeychainManager.shared.getCredentials(for: server)
            },
            tmuxService: RemoteTmuxManager.shared,
            moshService: RemoteMoshManager.shared,
            knownHostRemover: { host, port in
                await KnownHostsStore.shared.remove(host: host, port: port)
            },
            workingDirectoryService: TerminalWorkingDirectoryService(),
            liveActivityRefresher: { snapshots in
                LiveActivityManager.shared.refresh(with: snapshots)
            },
            successfulConnectionRecorder: { id, transport in
                EngagementTracker.shared.recordSuccessfulConnection(id: id, transport: transport)
            },
            terminalSessionEndRecorder: { otherTerminalsActive, isPro in
                EngagementTracker.shared.noteTerminalSessionEnded(
                    otherTerminalsActive: otherTerminalsActive,
                    isPro: isPro
                )
            }
        )
    }
}

extension TerminalTabManager.Dependencies {
    static var live: Self {
        Self(
            isProProvider: {
                StoreManager.shared.isPro
            },
            defaultViewProvider: {
                ViewTabConfigurationManager.shared.effectiveDefaultTab()
            },
            serverUnlocker: { server in
                await AppLockManager.shared.ensureServerUnlocked(server)
            },
            serverProvider: { serverId in
                ServerManager.shared.servers.first { $0.id == serverId }
            },
            credentialsProvider: { server in
                try KeychainManager.shared.getCredentials(for: server)
            },
            tmuxService: RemoteTmuxManager.shared,
            moshService: RemoteMoshManager.shared,
            knownHostRemover: { host, port in
                await KnownHostsStore.shared.remove(host: host, port: port)
            },
            workingDirectoryService: TerminalWorkingDirectoryService(),
            successfulConnectionRecorder: { id, transport in
                EngagementTracker.shared.recordSuccessfulConnection(id: id, transport: transport)
            },
            splitPaneCreatedTracker: {
                AnalyticsTracker.shared.trackSplitPaneCreated()
            },
            terminalSessionEndRecorder: { otherTerminalsActive, isPro in
                EngagementTracker.shared.noteTerminalSessionEnded(
                    otherTerminalsActive: otherTerminalsActive,
                    isPro: isPro
                )
            }
        )
    }
}
