import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect terminal connection lifecycle ordering across
// app-level managers. They intentionally use real manager singletons but avoid
// real network I/O; registered SSHClient instances are never connected. A
// failure usually means a lifecycle invariant changed, such as stale shell
// registration rejection, close/open ordering, or teardown completion semantics.
// Update these tests only when the intended lifecycle contract changes.

@Suite(.serialized)
@MainActor
struct ConnectionLifecycleIntegrationTests {
    private func makeServer(
        id: UUID = UUID(),
        workspaceId: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .cloudflare
    ) -> Server {
        Server(
            id: id,
            workspaceId: workspaceId,
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode
        )
    }

    private func makeCredentials(serverId: UUID) -> ServerCredentials {
        ServerCredentials(
            serverId: serverId,
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )
    }

    private func withCleanConnectionManager(
        _ body: @MainActor (ConnectionSessionManager) async throws -> Void
    ) async rethrows {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    private func withServerList<T>(
        _ servers: [Server],
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        let serverManager = ServerManager.shared
        let originalServers = serverManager.servers
        serverManager.servers = servers
        defer { serverManager.servers = originalServers }
        return try await body()
    }

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    @Test
    func connectionManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Session A",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: session.id, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: staleClient)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: session.id))
        }
    }

    @Test
    func connectionManagerRestoredSessionsAreOpenButNotActiveUntilRuntimeStreams() async throws {
        try await withCleanConnectionManager { manager in
            let server = makeServer()
            let sessionId = UUID()
            let snapshot = TestConnectionSessionsSnapshot(
                sessions: [
                    .init(
                        id: sessionId,
                        serverId: server.id,
                        title: server.name,
                        createdAt: Date(),
                        lastActivity: Date(),
                        autoReconnect: true,
                        parentSessionId: nil,
                        workingDirectory: nil,
                        presentationOverrides: nil
                    )
                ],
                selectedSessionId: sessionId,
                serverSelections: [
                    .init(serverId: server.id, selectedSessionId: sessionId, selectedView: "terminal")
                ]
            )
            UserDefaults.standard.set(
                try JSONEncoder().encode(snapshot),
                forKey: "connectionSessionsSnapshot.v1"
            )

            manager.restorePersistedSnapshotForTesting()

            #expect(manager.openServerIds == [server.id], "Restored sessions should keep server navigation open.")
            #expect(manager.activeServerIds.isEmpty, "Restored disconnected sessions must not appear as live transports.")
            #expect(manager.connectedServerIds.isEmpty, "Legacy connected ids should mirror active live transports only.")

            let client = RecordingPaneRuntimeClient()
            manager.setTerminalConnectionClientFactoryForTesting { _, _ in client }
            await manager.startRuntimeForTesting(sessionId: sessionId)

            #expect(manager.activeServerIds == [server.id], "A server becomes active only after its runtime reaches streaming.")
            #expect(manager.connectedServerIds == [server.id], "Legacy connected ids should update when the runtime is streaming.")
        }
    }

    @Test
    func tabManagerRestoredTabsAreOpenButNotActiveUntilRuntimeStreams() async throws {
        try await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            let snapshot = TestTerminalTabsSnapshot(
                servers: [
                    .init(
                        serverId: server.id,
                        tabs: [
                            .init(
                                id: tabId,
                                serverId: server.id,
                                title: server.name,
                                createdAt: Date(),
                                layout: nil,
                                focusedPaneId: paneId,
                                rootPaneId: paneId,
                                panePresentationOverrides: nil
                            )
                        ],
                        selectedTabId: tabId,
                        selectedView: "terminal"
                    )
                ]
            )
            UserDefaults.standard.set(
                try JSONEncoder().encode(snapshot),
                forKey: "terminalTabsSnapshot.v1"
            )

            manager.restorePersistedSnapshotForTesting()

            #expect(manager.openServerIds == [server.id], "Restored tabs should keep server navigation open.")
            #expect(manager.activeServerIds.isEmpty, "Restored panes must not appear as live transports before streaming.")
            #expect(manager.connectedServerIds.isEmpty, "Legacy connected ids should mirror active live transports only.")

            let client = RecordingPaneRuntimeClient()
            manager.setTerminalConnectionClientFactoryForTesting { _, _ in client }
            await manager.startRuntimeForTesting(paneId: paneId)

            #expect(manager.activeServerIds == [server.id], "A server becomes active only after a pane runtime reaches streaming.")
            #expect(manager.connectedServerIds == [server.id], "Legacy connected ids should update when the pane runtime is streaming.")
        }
    }

    @Test
    func connectionManagerActiveServersComeFromRegistryNotDomainSessionState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected
            )

            manager.sessions = [session]

            #expect(
                manager.activeServerIds.isEmpty,
                "A stale domain session state must not make a server active without a streaming runtime in the registry."
            )
        }
    }

    @Test
    func connectionManagerActiveSessionsComeFromRegistryNotDomainSessionState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleDomainSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Connected",
                connectionState: .connected
            )
            let registryLiveSession = ConnectionSession(
                serverId: server.id,
                title: "Registry Live",
                connectionState: .disconnected
            )

            manager.sessions = [staleDomainSession, registryLiveSession]
            manager.updateSessionState(registryLiveSession.id, to: .connected)
            manager.sessions[1].connectionState = .disconnected

            #expect(
                manager.activeSessions.map(\.id) == [registryLiveSession.id],
                "Active sessions should come from registry runtime state, not stale domain snapshots."
            )
        }
    }

    @Test
    func connectionManagerAutoReconnectIntentUsesManagerRuntimeState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]

            // Given SwiftUI sends scene/setting intent only and the application
            // layer owns the session snapshot plus runtime liveness lookup.
            #expect(
                manager.shouldAutoReconnectSession(
                    session.id,
                    isSceneActive: true,
                    autoReconnectEnabled: true,
                    reconnectInFlight: false
                ),
                "Disconnected sessions without live runtime should be eligible for app-layer auto reconnect."
            )

            // When the runtime registry says the session is already opening,
            // even if the UI display snapshot later appears disconnected.
            manager.updateSessionState(session.id, to: .connecting)
            manager.sessions[0].connectionState = .disconnected

            // Then the application-layer intent must suppress a duplicate
            // reconnect without asking SwiftUI to combine registry state.
            #expect(
                !manager.shouldAutoReconnectSession(
                    session.id,
                    isSceneActive: true,
                    autoReconnectEnabled: true,
                    reconnectInFlight: false
                ),
                "Auto reconnect intent should use manager-owned runtime liveness, not stale SwiftUI session snapshots."
            )
        }
    }

    @Test
    func connectionManagerForegroundReconnectActionUsesSelectedRuntimeState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            // Given the iOS shell sends foreground/selection intent to the
            // application layer instead of deriving runtime liveness in SwiftUI.
            let reconnectAction = manager.foregroundReconnectActionForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true
            )

            // Then the manager returns the UI side effects while owning the
            // reconnect decision and selected-session lookup.
            #expect(reconnectAction?.sessionId == session.id)
            #expect(reconnectAction?.shouldRefreshTerminal == true)
            #expect(reconnectAction?.shouldReconnect == true)
            #expect(reconnectAction?.shouldForceTerminalVisible == true)

            // When a live runtime exists but the UI display snapshot is stale.
            manager.updateSessionState(session.id, to: .connected)
            manager.sessions[0].connectionState = .disconnected

            // Then foreground intent must not create a duplicate reconnect.
            let liveAction = manager.foregroundReconnectActionForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true
            )
            #expect(liveAction?.shouldReconnect == false)
            #expect(liveAction?.shouldForceTerminalVisible == false)
        }
    }

    @Test
    func connectionManagerWatchdogSchedulingIntentUsesManagerState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connecting
            )
            manager.sessions = [session]

            // Given the terminal view reports only UI readiness and surface
            // presence, while the application layer owns connection state.
            #expect(
                manager.shouldScheduleConnectWatchdog(
                    forSessionId: session.id,
                    isReady: false,
                    terminalExists: false
                ),
                "Connecting sessions should schedule their connect watchdog from the application layer."
            )

            // When the session is connected but no terminal surface became
            // ready, the same manager-owned rule should continue watching.
            manager.updateSessionState(session.id, to: .connected)
            #expect(
                manager.shouldScheduleConnectWatchdog(
                    forSessionId: session.id,
                    isReady: false,
                    terminalExists: false
                ),
                "Connected sessions without a ready terminal surface should still schedule the watchdog."
            )

            // Then a ready connected terminal should stop scheduling.
            #expect(
                !manager.shouldScheduleConnectWatchdog(
                    forSessionId: session.id,
                    isReady: true,
                    terminalExists: true
                ),
                "Ready connected sessions should not schedule another connect watchdog."
            )
        }
    }

    @Test
    func connectionManagerOwnsConnectWatchdogRetryTask() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.updateSessionState(session.id, to: .connected)
            var retryCount = 0

            // Given a connected session whose terminal surface never became
            // ready, and SwiftUI sends only the current surface state.
            manager.scheduleConnectWatchdog(
                forSessionId: session.id,
                isReady: false,
                terminalExists: false,
                timeout: .milliseconds(10),
                timeoutMessage: "timeout"
            ) {
                retryCount += 1
            }

            // When the manager-owned watchdog timeout expires.
            try? await Task.sleep(for: .milliseconds(150))

            // Then retry is triggered by the application layer task, not by a
            // SwiftUI-owned sleep/retry orchestration.
            #expect(retryCount == 1)
            #expect(manager.sessionState(for: session.id) == .disconnected)
        }
    }

    @Test
    func connectionManagerCancelsConnectWatchdogWhenSurfaceBecomesReady() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.updateSessionState(session.id, to: .connected)
            var retryCount = 0

            // Given an initial watchdog for a connected session without a
            // ready terminal surface.
            manager.scheduleConnectWatchdog(
                forSessionId: session.id,
                isReady: false,
                terminalExists: false,
                timeout: .milliseconds(30),
                timeoutMessage: "timeout"
            ) {
                retryCount += 1
            }

            // When SwiftUI reports that the terminal surface is now ready.
            manager.scheduleConnectWatchdog(
                forSessionId: session.id,
                isReady: true,
                terminalExists: true,
                timeout: .milliseconds(10),
                timeoutMessage: "timeout"
            ) {
                retryCount += 1
            }
            try? await Task.sleep(for: .milliseconds(150))

            // Then the previous manager-owned watchdog is cancelled.
            #expect(retryCount == 0)
            #expect(manager.sessionState(for: session.id) == .connected)
        }
    }

    @Test
    func connectionManagerRetryLoadsCredentialsAndGatesDuplicateRequests() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            let credentialGate = CredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.sessions = [session]
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }

            await withServerList([server]) {
                // Given SwiftUI sends retry intent while credential loading is
                // still in progress inside the application layer.
                let firstRetry = Task {
                    await manager.retrySessionConnection(session: session, server: server)
                }
                try? await Task.sleep(for: .milliseconds(20))

                // When another retry intent arrives before credential loading
                // completes.
                let duplicateResult = await manager.retrySessionConnection(
                    session: session,
                    server: server
                )

                // Then the manager-owned retry gate rejects the duplicate
                // without asking SwiftUI to track reconnectInFlight.
                #expect(duplicateResult.isSkipped)

                await credentialGate.release()
                let result = await firstRetry.value
                #expect(
                    result.credentials?.serverId == server.id,
                    "A successful retry should return loaded credentials for the UI wrapper to render."
                )
                #expect(
                    await credentialGate.loadCount == 1,
                    "Duplicate retry intent must not load credentials a second time."
                )
                #expect(manager.sessionState(for: session.id) == .reconnecting(attempt: 1))
            }
        }
    }

    @Test
    func connectionManagerRetrySkipsIfRuntimeBecomesLiveWhileLoadingCredentials() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            let credentialGate = CredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.sessions = [session]
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }

            await withServerList([server]) {
                // Given retry intent has started credential loading.
                let retryTask = Task {
                    await manager.retrySessionConnection(session: session, server: server)
                }
                try? await Task.sleep(for: .milliseconds(20))

                // When the runtime becomes live before credential loading
                // returns to the manager.
                manager.updateSessionState(session.id, to: .connected)
                manager.sessions[0].connectionState = .disconnected
                await credentialGate.release()
                let result = await retryTask.value

                // Then the retry intent is skipped and the UI should not
                // rebuild a wrapper for a stale reconnect.
                #expect(
                    result.isSkipped,
                    "Retry must revalidate runtime liveness after awaited credential loading."
                )
            }
        }
    }

    @Test
    func connectionManagerForegroundReconnectIntentExecutesReconnectInApplicationLayer() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            await withServerList([server]) {
                // Given iOS sends foreground intent to the application layer.
                let action = await manager.handleForegroundReconnectForSelectedSession(
                    selectedViewId: "terminal",
                    terminalViewId: "terminal",
                    refreshTerminal: true,
                    autoReconnectEnabled: true
                )

                // Then the manager returns UI render instructions and performs
                // reconnect execution itself.
                #expect(action?.sessionId == session.id)
                #expect(action?.shouldReconnect == true)
                #expect(manager.sessionState(for: session.id) == .reconnecting(attempt: 1))
            }
        }
    }

    @Test
    func connectionManagerLoadsCredentialsThroughApplicationBoundary() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            manager.setCredentialsProviderForTesting { server in
                makeCredentials(serverId: server.id)
            }

            // Given SwiftUI needs credentials for rendering the terminal
            // wrapper but must not read Keychain directly.
            let result = await manager.loadCredentials(for: server)

            // Then the application layer performs credential loading and
            // returns only the renderable value or user-facing error.
            #expect(
                result.credentials?.serverId == server.id,
                "TerminalContainerView should obtain wrapper credentials through ConnectionSessionManager."
            )
        }
    }

    @Test
    func connectionManagerRefreshesLiveActivityWithRegistryActiveSessionsOnly() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleDomainSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Connected",
                connectionState: .connected
            )
            var refreshedSessionIds: [[UUID]] = []
            manager.liveActivityRefresh = { snapshots in
                refreshedSessionIds.append(snapshots.map(\.sessionId))
            }

            manager.sessions = [staleDomainSession]

            #expect(
                refreshedSessionIds.last == [],
                "Live Activity refreshes must ignore stale domain connected snapshots without registry runtime."
            )

            manager.updateSessionState(staleDomainSession.id, to: .connected)

            #expect(
                refreshedSessionIds.last == [staleDomainSession.id],
                "Live Activity refreshes should include the session after the registry records streaming runtime."
            )
        }
    }

    @Test
    func connectionManagerRefreshesLiveActivityWithRegistryRuntimeStates() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleDomainSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Connecting",
                connectionState: .connecting
            )
            var refreshedStates: [[TerminalEntityConnectionState]] = []
            manager.liveActivityRefresh = { snapshots in
                refreshedStates.append(snapshots.map(\.state))
            }

            // Given a restored session whose domain snapshot still says
            // connecting, while the registry has no live runtime yet.
            manager.sessions = [staleDomainSession]

            #expect(
                refreshedStates.last == [],
                "Live Activity refreshes must ignore opening states that exist only in the domain snapshot."
            )

            // When the application-layer registry records the terminal runtime
            // as streaming and the domain snapshot later remains stale.
            manager.updateSessionState(staleDomainSession.id, to: .connected)
            manager.sessions[0].connectionState = .connecting

            // Then the Live Activity refresh uses the registry runtime state,
            // not the stale ConnectionSession.connectionState snapshot.
            #expect(
                refreshedStates.last == [.streaming],
                "Live Activity status should be derived from TerminalConnectionRegistry runtime state."
            )
        }
    }

    @Test
    func tabManagerActiveServersComeFromRegistryNotDomainPaneState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .connected

            manager.paneStates[paneId] = paneState

            #expect(
                manager.activeServerIds.isEmpty,
                "A stale domain pane state must not make a server active without a streaming runtime in the registry."
            )
        }
    }

    @Test
    func tabManagerReportsLiveRuntimeFromRegistryNotPaneStateSnapshot() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var stalePane = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            stalePane.connectionState = .disconnected
            manager.paneStates[paneId] = stalePane

            // Given a pane whose domain snapshot still says disconnected.
            #expect(
                !manager.hasLiveRuntime(forPaneId: paneId),
                "A pane without registry opening/streaming state should not be considered live."
            )

            // When the application-layer registry records the runtime as opening.
            manager.updatePaneState(paneId, connectionState: .connecting)

            // Then liveness comes from the registry, not the stale pane snapshot
            // value used for display.
            #expect(
                manager.hasLiveRuntime(forPaneId: paneId),
                "Pane runtime liveness should be true when the registry is opening or streaming."
            )
        }
    }

    @Test
    func tabManagerManualReconnectIntentUsesManagerRuntimeState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .disconnected
            manager.paneStates[paneId] = paneState

            // Given split SwiftUI sends only retry intent and the application
            // layer owns the runtime liveness decision.
            #expect(
                manager.shouldManuallyReconnectPane(paneId, reconnectInFlight: false),
                "Disconnected panes without live runtime should accept manual reconnect intent."
            )

            // When the registry records an opening runtime while the display
            // snapshot later appears disconnected.
            manager.updatePaneState(paneId, connectionState: .connecting)
            manager.paneStates[paneId]?.connectionState = .disconnected

            // Then the manager suppresses the duplicate retry without SwiftUI
            // reading registry state directly.
            #expect(
                !manager.shouldManuallyReconnectPane(paneId, reconnectInFlight: false),
                "Manual pane reconnect intent should use manager-owned runtime liveness."
            )
        }
    }

    @Test
    func tabManagerWatchdogSchedulingIntentUsesManagerState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .connecting
            manager.paneStates[paneId] = paneState

            // Given split-pane SwiftUI sends only UI readiness and terminal
            // surface presence to the application layer.
            #expect(
                manager.shouldScheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: false,
                    terminalExists: false
                ),
                "Connecting panes should schedule watchdogs through TerminalTabManager."
            )

            // When the pane is connected but the terminal surface is not ready,
            // the manager still owns the connected-without-terminal rule.
            manager.updatePaneState(paneId, connectionState: .connected)
            #expect(
                manager.shouldScheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: false,
                    terminalExists: false
                ),
                "Connected panes without a ready terminal should continue watchdog scheduling."
            )

            // Then ready connected panes stop scheduling.
            #expect(
                !manager.shouldScheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: true,
                    terminalExists: true
                ),
                "Ready connected panes should not schedule another watchdog."
            )
        }
    }

    @Test
    func tabManagerOwnsConnectWatchdogRetryTask() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .connected
            manager.paneStates[paneId] = paneState
            manager.updatePaneState(paneId, connectionState: .connected)
            var retryCount = 0

            // Given a connected split pane whose terminal surface never became
            // ready, and SwiftUI sends only surface state.
            manager.scheduleConnectWatchdog(
                forPaneId: paneId,
                isReady: false,
                terminalExists: false,
                timeout: .milliseconds(10),
                timeoutMessage: "timeout"
            ) {
                retryCount += 1
            }

            // When the manager-owned watchdog timeout expires.
            try? await Task.sleep(for: .milliseconds(150))

            // Then retry is triggered by TerminalTabManager's task.
            #expect(retryCount == 1)
            #expect(manager.paneStates[paneId]?.connectionState == .disconnected)
        }
    }

    @Test
    func tabManagerRetryLoadsCredentialsAndGatesDuplicateRequests() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .disconnected
            let credentialGate = CredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.paneStates[paneId] = paneState
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }

            // Given split-pane SwiftUI sends retry intent while credential
            // loading is still in progress inside TerminalTabManager.
            let firstRetry = Task {
                await manager.retryPaneConnection(paneId: paneId, server: server)
            }
            try? await Task.sleep(for: .milliseconds(20))

            // When another retry intent arrives before credential loading
            // completes.
            let duplicateResult = await manager.retryPaneConnection(
                paneId: paneId,
                server: server
            )

            // Then the manager-owned retry gate rejects the duplicate without
            // SwiftUI tracking reconnectInFlight.
            #expect(duplicateResult.isSkipped)

            await credentialGate.release()
            let result = await firstRetry.value
            #expect(
                result.credentials?.serverId == server.id,
                "A successful pane retry should return loaded credentials for the UI wrapper to render."
            )
            #expect(
                await credentialGate.loadCount == 1,
                "Duplicate pane retry intent must not load credentials a second time."
            )
            #expect(manager.paneStates[paneId]?.connectionState == .reconnecting(attempt: 1))
        }
    }

    @Test
    func tabManagerRetrySkipsIfRuntimeBecomesLiveWhileLoadingCredentials() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .disconnected
            let credentialGate = CredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.paneStates[paneId] = paneState
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }

            // Given pane retry intent has started credential loading.
            let retryTask = Task {
                await manager.retryPaneConnection(paneId: paneId, server: server)
            }
            try? await Task.sleep(for: .milliseconds(20))

            // When the pane runtime becomes live before credential loading
            // returns to the manager.
            manager.updatePaneState(paneId, connectionState: .connected)
            manager.paneStates[paneId]?.connectionState = .disconnected
            await credentialGate.release()
            let result = await retryTask.value

            // Then the retry is skipped instead of forcing a stale wrapper
            // rebuild from SwiftUI.
            #expect(
                result.isSkipped,
                "Pane retry must revalidate runtime liveness after awaited credential loading."
            )
        }
    }

    @Test
    func tabManagerLoadsCredentialsThroughApplicationBoundary() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            manager.setCredentialsProviderForTesting { server in
                makeCredentials(serverId: server.id)
            }

            // Given split-pane SwiftUI needs credentials for rendering the pane
            // wrapper but must not read Keychain directly.
            let result = await manager.loadCredentials(for: server)

            // Then TerminalTabManager performs credential loading.
            #expect(
                result.credentials?.serverId == server.id,
                "TerminalPaneView should obtain wrapper credentials through TerminalTabManager."
            )
        }
    }

    @Test
    func connectionManagerOtherActiveSessionsComeFromRegistryNotDomainState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleSession = ConnectionSession(
                serverId: server.id,
                title: "Stale",
                connectionState: .connected
            )
            let closingSession = ConnectionSession(
                serverId: server.id,
                title: "Closing",
                connectionState: .disconnected
            )

            manager.sessions = [staleSession, closingSession]

            #expect(
                !manager.hasOtherActiveSessions(for: server.id, excluding: closingSession.id),
                "A stale domain session state must not count as another active session without registry state."
            )

            manager.updateSessionState(staleSession.id, to: .connected)

            #expect(
                manager.hasOtherActiveSessions(for: server.id, excluding: closingSession.id),
                "A registry streaming state should count as another active session."
            )
        }
    }

    @Test
    func tabManagerOtherActivePanesComeFromRegistryNotDomainState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let stalePaneId = UUID()
            let closingPaneId = UUID()
            var stalePane = TerminalPaneState(paneId: stalePaneId, tabId: tabId, serverId: server.id)
            stalePane.connectionState = .connected
            let closingPane = TerminalPaneState(paneId: closingPaneId, tabId: tabId, serverId: server.id)

            manager.paneStates = [
                stalePaneId: stalePane,
                closingPaneId: closingPane
            ]

            #expect(
                !manager.hasOtherActivePanes(for: server.id, excluding: closingPaneId),
                "A stale domain pane state must not count as another active pane without registry state."
            )

            manager.updatePaneState(stalePaneId, connectionState: .connected)

            #expect(
                manager.hasOtherActivePanes(for: server.id, excluding: closingPaneId),
                "A registry streaming state should count as another active pane."
            )
        }
    }

    @Test
    func connectionManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Session B",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: firstClient))

            await manager.unregisterSSHClient(for: session.id)
            #expect(!manager.isShellStartInFlight(for: session.id))
            #expect(manager.shellId(for: session.id) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: nextClient))
            manager.finishShellStart(for: session.id, client: nextClient)
        }
    }

    @Test
    func connectionManagerCloseSessionAndWaitWaitsForShellTeardownAndUnregister() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Awaited Close",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.updateSessionState(session.id, to: .connected)

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            var teardownFinished = false
            manager.registerShellCancelHandler({ _ in
                try? await Task.sleep(for: .milliseconds(50))
                teardownFinished = true
            }, for: session.id)

            await manager.closeSessionAndWait(session, notingSessionEnd: false)

            #expect(teardownFinished)
            #expect(manager.shellId(for: session.id) == nil)
            #expect(!manager.sessions.contains { $0.id == session.id })
        }
    }

    @Test
    func connectionManagerDisconnectAllAndWaitWaitsForEverySessionTeardown() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let first = ConnectionSession(
                serverId: serverId,
                title: "Termination A",
                connectionState: .connected
            )
            let second = ConnectionSession(
                serverId: serverId,
                title: "Termination B",
                connectionState: .connected
            )
            manager.sessions = [first, second]
            manager.selectedSessionId = first.id

            for session in [first, second] {
                manager.registerSSHClient(
                    SSHClient(),
                    shellId: UUID(),
                    for: session.id,
                    serverId: serverId,
                    skipTmuxLifecycle: true
                )
            }

            var finishedTeardowns: Set<UUID> = []
            for session in [first, second] {
                manager.registerShellCancelHandler({ _ in
                    try? await Task.sleep(for: .milliseconds(50))
                    finishedTeardowns.insert(session.id)
                }, for: session.id)
            }

            await manager.disconnectAllAndWait()

            #expect(
                finishedTeardowns == [first.id, second.id],
                "App termination cleanup must wait for every session shell teardown before reporting completion."
            )
            #expect(manager.sessions.isEmpty)
            #expect(manager.shellId(for: first.id) == nil)
            #expect(manager.shellId(for: second.id) == nil)
        }
    }

    @Test
    func connectionManagerLruEvictionTracksShellCleanupBeforeSameServerReopen() async throws {
        try await withCleanConnectionManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let server = makeServer(name: "Tencent", connectionMode: .standard)
            let evictedSession = ConnectionSession(
                serverId: server.id,
                title: "Evicted",
                connectionState: .connected
            )
            manager.sessions = [evictedSession]
            manager.selectedSessionId = nil

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: evictedSession.id,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            var evictionTeardownFinished = false
            manager.registerShellCancelHandler({ _ in
                try? await Task.sleep(for: .milliseconds(100))
                evictionTeardownFinished = true
            }, for: evictedSession.id)

            manager.registerTerminalForTesting(sessionId: evictedSession.id)
            for index in 0..<20 {
                let cachedSession = ConnectionSession(
                    serverId: UUID(),
                    title: "Cached \(index)",
                    connectionState: .connected
                )
                manager.sessions.append(cachedSession)
                manager.registerTerminalForTesting(sessionId: cachedSession.id)
            }

            _ = try await manager.openConnection(to: server, forceNew: true)

            #expect(
                evictionTeardownFinished,
                "Opening the same server after LRU eviction must wait for the evicted session cleanup task."
            )
        }
    }

    @Test
    func tabManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let tabId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: tabId,
                serverId: serverId
            )

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: paneId, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: paneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: paneId) == nil)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: staleClient)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: paneId))
        }
    }

    @Test
    func tabManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: firstClient))

            await manager.unregisterSSHClient(for: paneId)
            #expect(!manager.isShellStartInFlight(for: paneId))
            #expect(manager.shellId(for: paneId) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: nextClient))
            manager.finishShellStart(for: paneId, client: nextClient)
        }
    }

    @Test
    func tabManagerReconnectPaneSkipsWhenRegistryRuntimeIsLive() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            // Given a pane with a live manager-owned opening runtime and a stale
            // disconnected display snapshot.
            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: client))
            manager.updatePaneState(paneId, connectionState: .connecting)
            manager.paneStates[paneId]?.connectionState = .disconnected

            // When split-pane reconnect is requested.
            await manager.reconnectPane(paneId)

            // Then the application layer must not unregister or cancel the live
            // opening runtime just because the UI snapshot is stale.
            #expect(manager.isShellStartInFlight(for: paneId))
        }
    }

    @Test
    func tabManagerReconnectPaneStartsWhenSnapshotIsConnectingButRegistryRuntimeIsInactive() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            var stalePane = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )
            stalePane.connectionState = .connecting
            manager.paneStates[paneId] = stalePane

            // When a user retry reaches the application layer after the display
            // snapshot says connecting but the runtime registry is inactive.
            await manager.reconnectPane(paneId)

            // Then reconnect is driven by registry liveness, not blocked by the
            // stale connecting snapshot.
            #expect(manager.hasLiveRuntime(forPaneId: paneId))
            if case .reconnecting(let attempt) = manager.paneStates[paneId]?.connectionState {
                #expect(attempt == 1)
            } else {
                Issue.record("Expected pane to enter reconnecting state.")
            }
        }
    }

    @Test
    func tabManagerHandlePaneExitMarksDisconnectedAndWaitsForUnregister() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: client))

            await manager.handlePaneExit(for: paneId)

            #expect(manager.paneStates[paneId]?.connectionState == .disconnected)
            #expect(!manager.isShellStartInFlight(for: paneId))
            #expect(!manager.hasLiveRuntime(forPaneId: paneId))
        }
    }

    @Test
    func tabManagerCloseTabAndWaitWaitsForPaneUnregister() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Awaited Tab")
            manager.tabsByServer[serverId] = [tab]
            manager.selectedTabByServer[serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: serverId
            )

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            await manager.closeTabAndWait(tab)

            #expect(manager.remoteConnectionLease(for: tab.rootPaneId) == nil)
            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(manager.tabs(for: serverId).isEmpty)
            #expect(manager.paneStates[tab.rootPaneId] == nil)
        }
    }

    @Test
    func tabManagerDisconnectAllAndWaitWaitsForEveryPaneUnregister() async {
        await withCleanTabManager { manager in
            let firstServerId = UUID()
            let secondServerId = UUID()
            let firstTab = TerminalTab(serverId: firstServerId, title: "Termination Pane A")
            let secondTab = TerminalTab(serverId: secondServerId, title: "Termination Pane B")

            manager.tabsByServer[firstServerId] = [firstTab]
            manager.tabsByServer[secondServerId] = [secondTab]
            manager.selectedTabByServer[firstServerId] = firstTab.id
            manager.selectedTabByServer[secondServerId] = secondTab.id
            manager.paneStates[firstTab.rootPaneId] = TerminalPaneState(
                paneId: firstTab.rootPaneId,
                tabId: firstTab.id,
                serverId: firstServerId
            )
            manager.paneStates[secondTab.rootPaneId] = TerminalPaneState(
                paneId: secondTab.rootPaneId,
                tabId: secondTab.id,
                serverId: secondServerId
            )

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: firstTab.rootPaneId,
                serverId: firstServerId,
                skipTmuxLifecycle: true
            )
            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: secondTab.rootPaneId,
                serverId: secondServerId,
                skipTmuxLifecycle: true
            )

            await manager.disconnectAllAndWait()

            #expect(manager.tabs(for: firstServerId).isEmpty)
            #expect(manager.tabs(for: secondServerId).isEmpty)
            #expect(manager.shellId(for: firstTab.rootPaneId) == nil)
            #expect(manager.shellId(for: secondTab.rootPaneId) == nil)
            #expect(manager.paneStates[firstTab.rootPaneId] == nil)
            #expect(manager.paneStates[secondTab.rootPaneId] == nil)
        }
    }

    @Test
    func tabManagerOpenTabWaitsForRejectedLateShellCleanupBeforeCreatingTab() async throws {
        try await withCleanTabManager { manager in
            let server = makeServer(name: "Tencent", connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: "Closing Pane")
            let staleClient = SSHClient()
            let staleShellId = UUID()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )

            let staleGeneration = manager.beginShellStartForTesting(
                paneId: tab.rootPaneId,
                serverId: server.id,
                client: staleClient
            )
            manager.closeShellRegistrationForTesting(paneId: tab.rootPaneId)

            var cleanupFinished = false
            manager.setRejectedShellCleanupOperationForTesting {
                try? await Task.sleep(for: .milliseconds(100))
                cleanupFinished = true
            }

            manager.registerSSHClient(
                staleClient,
                shellId: staleShellId,
                for: tab.rootPaneId,
                serverId: server.id,
                generation: staleGeneration,
                skipTmuxLifecycle: true
            )

            _ = try await manager.openTab(for: server)

            #expect(
                cleanupFinished,
                "Opening another tab must wait for cleanup of a rejected late pane shell."
            )
        }
    }

    @Test
    func tabManagerOpenTabWaitsForManagedTmuxKillBeforeCreatingTab() async throws {
        try await withCleanTabManager { manager in
            let server = makeServer(name: "Tencent", connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: "Managed Tmux")
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            var killFinished = false
            manager.setTmuxKillOperationForTesting {
                try? await Task.sleep(for: .milliseconds(100))
                killFinished = true
            }

            manager.killTmuxIfNeeded(for: tab.rootPaneId)
            _ = try await manager.openTab(for: server)

            #expect(
                killFinished,
                "Opening another tab must wait for a managed tmux kill task on the same server."
            )
        }
    }

    @Test
    func tabManagerPaneInputResizeAndCloseUseManagerOwnedRuntime() async {
        await withCleanTabManager { manager in
            // Given a split-pane tab and a fake runtime client owned by the
            // application manager, not by the SwiftUI pane coordinator.
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Runtime Pane")
            let fake = RecordingPaneRuntimeClient()
            manager.tabsByServer[serverId] = [tab]
            manager.selectedTabByServer[serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: serverId
            )
            manager.setTerminalConnectionClientFactoryForTesting { _, _ in fake }

            // When the manager starts the pane runtime, forwards terminal I/O,
            // and closes the pane.
            await manager.startRuntimeForTesting(paneId: tab.rootPaneId)
            await manager.sendInput(Data("ls\n".utf8), toPane: tab.rootPaneId)
            await manager.resizePane(tab.rootPaneId, cols: 100, rows: 32)
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)

            // Then all SSH-facing work is serialized through manager-owned
            // runtime state, including close teardown before the close returns.
            let events = await fake.events
            #expect(events == ["connect", "startShell", "write", "resize", "closeShell", "disconnect"])
            #expect(manager.remoteConnectionLease(for: tab.rootPaneId) == nil)
            #expect(manager.paneStates[tab.rootPaneId] == nil)
        }
    }

    @Test
    func connectionManagerConfiguredRuntimeUsesInjectedFactory() async {
        await withCleanConnectionManager { manager in
            // Given a session whose runtime is configured through the
            // application manager and a fake client factory.
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connecting
            )
            let fake = RecordingPaneRuntimeClient()
            manager.sessions = [session]
            manager.setTerminalConnectionClientFactoryForTesting { entityId, factoryServer in
                #expect(entityId == .session(session.id))
                #expect(factoryServer?.id == server.id)
                return fake
            }

            // When the production configure path prepares and starts a runtime.
            manager.configureRuntime(
                for: session.id,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )

            // Then the manager exposes a centralized runtime for that session
            // and the runtime uses the injected factory rather than constructing
            // a manager-local SSHClient.
            #expect(
                manager.hasTerminalConnectionRuntimeForTesting(.session(session.id)),
                "Configured sessions should be represented by TerminalConnectionRuntime."
            )
            await manager.startRuntimeForTesting(sessionId: session.id)

            let events = await fake.events
            #expect(events == ["connect", "startShell"])
            #expect(manager.sessionState(for: session.id) == .connected)
        }
    }

    @Test
    func connectionManagerCloseSessionAndWaitAwaitsStoredRunnerTask() async {
        await withCleanConnectionManager { manager in
            // Given a session with a configured production-style runtime and a
            // stored runner task whose finish path is deliberately delayed.
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected
            )
            let runnerGate = RunnerTaskGate()
            manager.sessions = [session]
            manager.configureRuntime(
                for: session.id,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )
            await manager.setRuntimeShellTaskForTesting(
                sessionId: session.id,
                Task {
                    await runnerGate.waitForRelease()
                    await runnerGate.markRunnerFinished()
                }
            )

            // When the application close-and-wait API runs before the runner
            // task has released its cleanup path.
            let closeTask = Task {
                await manager.closeSessionAndWait(session)
                await runnerGate.markCloseReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then close-and-wait must still be waiting on the runner task.
            #expect(
                await !runnerGate.closeReturned,
                "closeSessionAndWait must not return while the stored runner task is still finishing."
            )

            await runnerGate.release()
            await closeTask.value
            #expect(
                await runnerGate.runnerFinished,
                "The delayed runner task should finish before closeSessionAndWait returns."
            )
        }
    }

    @Test
    func connectionManagerLateRuntimeShellCallbackCannotUpdateClosedGeneration() async {
        await withCleanConnectionManager { manager in
            // Given a shell start that belongs to an older session generation.
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connecting
            )
            let staleClient = SSHClient()
            let staleShellId = UUID()
            manager.sessions = [session]
            let staleGeneration = manager.beginShellStartForTesting(
                sessionId: session.id,
                serverId: server.id,
                client: staleClient
            )
            manager.closeShellRegistrationForTesting(sessionId: session.id)

            // When the old runner reports a late shell callback.
            let accepted = manager.completeRuntimeShellStartForTesting(
                sessionId: session.id,
                client: staleClient,
                shellId: staleShellId,
                serverId: server.id,
                generation: staleGeneration
            )

            // Then the stale callback cannot register a shell or move UI state
            // back to connected for the closed generation.
            #expect(!accepted)
            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.sessionState(for: session.id) == .connecting)
        }
    }

    @Test
    func tabManagerConfiguredRuntimeUsesInjectedFactory() async {
        await withCleanTabManager { manager in
            // Given a pane whose runtime is configured through the application
            // manager and a fake client factory.
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let fake = RecordingPaneRuntimeClient()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.setTerminalConnectionClientFactoryForTesting { entityId, factoryServer in
                #expect(entityId == .pane(tab.rootPaneId))
                #expect(factoryServer?.id == server.id)
                return fake
            }

            // When the production configure path prepares and starts a runtime.
            manager.configureRuntime(
                forPane: tab.rootPaneId,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )

            // Then the manager exposes a centralized runtime for that pane and
            // the runtime uses the injected factory.
            #expect(
                manager.hasTerminalConnectionRuntimeForTesting(.pane(tab.rootPaneId)),
                "Configured panes should be represented by TerminalConnectionRuntime."
            )
            await manager.startRuntimeForTesting(paneId: tab.rootPaneId)

            let events = await fake.events
            #expect(events == ["connect", "startShell"])
            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .connected)
        }
    }

    @Test
    func tabManagerClosePaneAndWaitAwaitsStoredRunnerTask() async {
        await withCleanTabManager { manager in
            // Given a pane with a configured production-style runtime and a
            // stored runner task whose finish path is deliberately delayed.
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let runnerGate = RunnerTaskGate()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            var paneState = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            paneState.connectionState = .connected
            manager.paneStates[tab.rootPaneId] = paneState
            manager.configureRuntime(
                forPane: tab.rootPaneId,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )
            await manager.setRuntimeShellTaskForTesting(
                paneId: tab.rootPaneId,
                Task {
                    await runnerGate.waitForRelease()
                    await runnerGate.markRunnerFinished()
                }
            )

            // When the application close-and-wait API runs before the runner
            // task has released its cleanup path.
            let closeTask = Task {
                await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)
                await runnerGate.markCloseReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then close-and-wait must still be waiting on the runner task.
            #expect(
                await !runnerGate.closeReturned,
                "closePaneAndWait must not return while the stored runner task is still finishing."
            )

            await runnerGate.release()
            await closeTask.value
            #expect(
                await runnerGate.runnerFinished,
                "The delayed runner task should finish before closePaneAndWait returns."
            )
        }
    }

    @Test
    func tabManagerLateRuntimeShellCallbackCannotUpdateClosedGeneration() async {
        await withCleanTabManager { manager in
            // Given a shell start that belongs to an older pane generation.
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let staleClient = SSHClient()
            let staleShellId = UUID()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            let staleGeneration = manager.beginShellStartForTesting(
                paneId: tab.rootPaneId,
                serverId: server.id,
                client: staleClient
            )
            manager.closeShellRegistrationForTesting(paneId: tab.rootPaneId)

            // When the old runner reports a late shell callback.
            let accepted = manager.completeRuntimeShellStartForTesting(
                paneId: tab.rootPaneId,
                client: staleClient,
                shellId: staleShellId,
                serverId: server.id,
                generation: staleGeneration
            )

            // Then the stale callback cannot register a shell or move UI state
            // back to connected for the closed generation.
            #expect(!accepted)
            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(
                manager.paneStates[tab.rootPaneId]?.connectionState != .connected,
                "A stale pane runner callback must not move the pane back to connected."
            )
        }
    }

    @Test
    func connectionManagerTryBeginShellStartFailsWhenSessionIsMissing() async {
        await withCleanConnectionManager { manager in
            let missingSessionId = UUID()
            #expect(!manager.tryBeginShellStart(for: missingSessionId, client: SSHClient()))
            #expect(!manager.isShellStartInFlight(for: missingSessionId))
        }
    }

    @Test
    func connectionManagerRejectsShellRegistrationWhenSessionIsMissing() async {
        await withCleanConnectionManager { manager in
            // Given a late shell callback for a session that no longer exists.
            let missingSessionId = UUID()

            // When the callback attempts to register without a valid entity.
            let accepted = manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: missingSessionId,
                serverId: UUID(),
                skipTmuxLifecycle: true
            )

            // Then no orphan shell registration is retained.
            #expect(!accepted)
            #expect(manager.shellId(for: missingSessionId) == nil)
        }
    }

    @Test
    func connectionManagerTracksSelectedSessionPerServer() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let first = ConnectionSession(
                serverId: serverId,
                title: "First",
                connectionState: .disconnected
            )
            let second = ConnectionSession(
                serverId: serverId,
                title: "Second",
                connectionState: .disconnected
            )

            manager.sessions = [first, second]
            manager.selectSession(second)

            #expect(manager.selectedSessionId == second.id)
            #expect(manager.selectedSessionByServer[serverId] == second.id)
        }
    }

    @Test
    func openConnectionDoesNotSeedWorkingDirectoryFromSelectedDifferentServer() async throws {
        try await withCleanConnectionManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            try await withServerList([firstServer, secondServer]) {
                let firstSession = ConnectionSession(
                    serverId: firstServer.id,
                    title: "First",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/first"
                )
                manager.sessions = [firstSession]
                manager.selectedSessionId = firstSession.id
                manager.selectedSessionByServer[firstServer.id] = firstSession.id

                let newSession = try await manager.openConnection(to: secondServer, forceNew: true)

                #expect(newSession.serverId == secondServer.id)
                #expect(newSession.workingDirectory == nil)
            }
        }
    }

    @Test
    func openConnectionSeedsWorkingDirectoryFromSameServerSession() async throws {
        try await withCleanConnectionManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            try await withServerList([firstServer, secondServer]) {
                let wasPro = StoreManager.shared.isPro
                StoreManager.shared.isPro = true
                defer { StoreManager.shared.isPro = wasPro }

                let firstSession = ConnectionSession(
                    serverId: firstServer.id,
                    title: "First",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/first"
                )
                let secondSession = ConnectionSession(
                    serverId: secondServer.id,
                    title: "Second",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/second"
                )
                manager.sessions = [firstSession, secondSession]
                manager.selectedSessionId = firstSession.id
                manager.selectedSessionByServer[firstServer.id] = firstSession.id
                manager.selectedSessionByServer[secondServer.id] = secondSession.id

                let newSession = try await manager.openConnection(to: secondServer, forceNew: true)

                #expect(newSession.serverId == secondServer.id)
                #expect(newSession.workingDirectory == "/srv/second")
            }
        }
    }

    @Test
    func connectionManagerDisconnectServerLeavesOtherServersConnected() async {
        await withCleanConnectionManager { manager in
            let firstServerId = UUID()
            let secondServerId = UUID()
            let first = ConnectionSession(
                serverId: firstServerId,
                title: "First Server",
                connectionState: .connected
            )
            let second = ConnectionSession(
                serverId: secondServerId,
                title: "Second Server",
                connectionState: .connected
            )

            manager.sessions = [first, second]
            manager.selectedSessionId = first.id
            manager.updateSessionState(first.id, to: .connected)
            manager.updateSessionState(second.id, to: .connected)

            manager.disconnectServer(firstServerId)

            #expect(manager.sessions.count == 1)
            #expect(manager.sessions.first?.id == second.id)
            #expect(manager.selectedSessionId == second.id)
            #expect(manager.connectedServerIds == [secondServerId])
        }
    }

    @Test
    func connectionManagerSuspendAllForBackgroundPreservesTabsAndClearsShells() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Background Session",
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.updateSessionState(session.id, to: .connected)

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            var suspendCalls = 0
            manager.registerShellSuspendHandler({
                suspendCalls += 1
            }, for: session.id)

            await manager.suspendAllForBackground()

            #expect(manager.sessions.count == 1)
            #expect(manager.sessions.first?.id == session.id)
            #expect(manager.sessions.first?.connectionState == .disconnected)
            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.consumeTerminalReconnectReset(for: session.id))
            #expect(manager.connectedServerIds.isEmpty)
            #expect(suspendCalls == 1)
            #expect(!manager.isSuspendingForBackground)
        }
    }

    @Test
    func connectionManagerBackgroundSuspendUsesRegistryActiveStateForReconnectReset() async {
        await withCleanConnectionManager { manager in
            // Given an open tab whose registry runtime state is newer than the
            // domain snapshot retained for UI projection.
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Registry Active",
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            manager.updateSessionState(session.id, to: .connected)
            manager.sessions[0].connectionState = .disconnected

            // When background suspend runs before foreground reconnect.
            await manager.suspendAllForBackground()

            // Then registry state drives reconnect cleanup even if the
            // persisted tab snapshot already reads disconnected.
            #expect(
                manager.sessions.first?.connectionState == .disconnected,
                "Background suspend should leave the open tab disconnected for foreground reconnect."
            )
            #expect(
                manager.consumeTerminalReconnectReset(for: session.id),
                "A registry-active session must reset its preserved terminal even if the domain state is stale."
            )
            #expect(
                manager.connectedServerIds.isEmpty,
                "Background suspend must clear live server state through the registry."
            )
        }
    }

    @Test
    func connectionManagerHandleShellExitMarksTerminalForReconnectReset() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Reconnect Reset",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.updateSessionState(session.id, to: .connected)

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            manager.handleShellExit(for: session.id)

            #expect(manager.sessions.first?.connectionState == .disconnected)
            #expect(manager.consumeTerminalReconnectReset(for: session.id))
            #expect(!manager.consumeTerminalReconnectReset(for: session.id))
        }
    }

    @Test
    func connectionManagerReconnectDoesNothingWhileBackgroundSuspendIsActive() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Reconnect Guard",
                connectionState: .disconnected
            )

            await withServerList([server]) {
                manager.sessions = [session]
                manager.setBackgroundSuspendInProgressForTesting(true)
                defer { manager.setBackgroundSuspendInProgressForTesting(false) }

                try? await manager.reconnect(session: session)

                #expect(manager.sessions.first?.connectionState == .disconnected)
                #expect(manager.shellId(for: session.id) == nil)
            }
        }
    }

    @Test
    func connectionManagerWatchdogRequestsRetryForConnectedSnapshotWithoutTerminal() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Watchdog",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.updateSessionState(session.id, to: .connected)

            let action = manager.handleConnectWatchdogTimeout(
                forSessionId: session.id,
                isReady: false,
                terminalExists: false,
                timeoutMessage: "Timed out"
            )

            #expect(action == .retry)
            #expect(manager.sessions.first?.connectionState == .disconnected)
        }
    }

    @Test
    func tabManagerTryBeginShellStartFailsWhenPaneIsMissing() async {
        await withCleanTabManager { manager in
            let missingPaneId = UUID()
            #expect(!manager.tryBeginShellStart(for: missingPaneId, client: SSHClient()))
            #expect(!manager.isShellStartInFlight(for: missingPaneId))
        }
    }

    @Test
    func tabManagerRejectsShellRegistrationWhenPaneIsMissing() async {
        await withCleanTabManager { manager in
            // Given a late shell callback for a pane that no longer exists.
            let missingPaneId = UUID()

            // When the callback attempts to register without a valid entity.
            let accepted = manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: missingPaneId,
                serverId: UUID(),
                skipTmuxLifecycle: true
            )

            // Then no orphan shell registration is retained.
            #expect(!accepted)
            #expect(manager.shellId(for: missingPaneId) == nil)
        }
    }

    @Test
    func tabManagerWatchdogRequestsRetryForConnectedSnapshotWithoutTerminal() async {
        await withCleanTabManager { manager in
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: UUID()
            )
            manager.updatePaneState(paneId, connectionState: .connected)

            let action = manager.handleConnectWatchdogTimeout(
                forPaneId: paneId,
                isReady: false,
                terminalExists: false,
                timeoutMessage: "Timed out"
            )

            #expect(action == .retry)
            #expect(manager.paneStates[paneId]?.connectionState == .disconnected)
        }
    }

    @Test
    func connectionManagerSharedStatsLeaseSkipsMoshTransport() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Mosh Session",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.selectedSessionByServer[server.id] = session.id

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            #expect(manager.remoteConnectionLease(forSessionId: session.id) != nil)
            #expect(manager.sharedStatsLease(for: server.id) == nil)
        }
    }

    @Test
    func connectionManagerSharedStatsLeaseUsesRegistryActiveSSHWhenSelectionIsStaleMosh() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let staleSelected = ConnectionSession(
                serverId: server.id,
                title: "Stale Mosh",
                connectionState: .disconnected,
                activeTransport: .mosh
            )
            let activeSession = ConnectionSession(
                serverId: server.id,
                title: "Active SSH",
                connectionState: .disconnected,
                activeTransport: .ssh
            )
            manager.sessions = [staleSelected, activeSession]
            manager.selectedSessionId = staleSelected.id
            manager.selectedSessionByServer[server.id] = staleSelected.id

            let staleClient = SSHClient()
            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: staleSelected.id,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            let activeClient = SSHClient()
            manager.registerSSHClient(
                activeClient,
                shellId: UUID(),
                for: activeSession.id,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )
            manager.updateSessionState(activeSession.id, to: .connected)

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(activeClient),
                "Stats should use the registry-active SSH session lease instead of a stale selected Mosh session."
            )
        }
    }

    @Test
    func connectionManagerSharedStatsLeaseUsesPendingSSHWhenDomainMoshSnapshotIsStale() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let staleMoshSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Mosh",
                connectionState: .connected,
                activeTransport: .mosh
            )
            let pendingSSHSession = ConnectionSession(
                serverId: server.id,
                title: "Pending SSH",
                connectionState: .disconnected,
                activeTransport: .ssh
            )
            manager.sessions = [staleMoshSession, pendingSSHSession]

            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingSSHSession.id, client: pendingClient))

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(pendingClient),
                "A stale domain Mosh snapshot must not block a pending SSH stats lease."
            )
        }
    }

    @Test
    func connectionManagerRecordsSuccessfulConnectionTransportFromShellRegistry() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Stale Transport",
                connectionState: .disconnected,
                activeTransport: .mosh
            )
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.sessions = [session]

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: session.id,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )

            // When the runtime reaches connected while the domain transport
            // snapshot is stale.
            manager.updateSessionState(session.id, to: .connected)

            // Then successful-connection recording uses the registered shell
            // transport rather than ConnectionSession.activeTransport.
            #expect(
                recorded.map(\.id) == [session.id],
                "The session should be recorded exactly once when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Successful connection transport should come from the live shell registry."
            )
        }
    }

    @Test
    func connectionManagerDefaultsSuccessfulConnectionTransportWhenRuntimeIsUnregistered() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Unregistered Runtime",
                connectionState: .disconnected,
                activeTransport: .mosh
            )
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.sessions = [session]

            // When a restored or partially torn-down session reaches connected
            // without a live shell registry entry.
            manager.updateSessionState(session.id, to: .connected)

            // Then the recorder uses the explicit default transport rather than
            // trusting stale ConnectionSession.activeTransport.
            #expect(
                recorded.map(\.id) == [session.id],
                "The session should still be recorded when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Unregistered runtime should record the safe default SSH transport."
            )
        }
    }

    @Test
    func tabManagerSharedStatsLeaseSkipsMoshTransport() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            #expect(manager.remoteConnectionLease(for: tab.rootPaneId) != nil)
            #expect(manager.sharedStatsLease(for: server.id) == nil)
        }
    }

    @Test
    func tabManagerSharedStatsLeaseUsesRegistryActiveSSHWhenSelectionIsStaleMosh() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let stalePaneId = UUID()
            let activePaneId = UUID()
            let tab = TerminalTab(
                serverId: server.id,
                title: server.name,
                rootPaneId: stalePaneId,
                focusedPaneId: stalePaneId
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            var stalePane = TerminalPaneState(paneId: stalePaneId, tabId: tab.id, serverId: server.id)
            stalePane.connectionState = .disconnected
            stalePane.activeTransport = .mosh
            manager.paneStates[stalePaneId] = stalePane

            var activePane = TerminalPaneState(paneId: activePaneId, tabId: tab.id, serverId: server.id)
            activePane.connectionState = .disconnected
            activePane.activeTransport = .ssh
            manager.paneStates[activePaneId] = activePane

            let staleClient = SSHClient()
            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: stalePaneId,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            let activeClient = SSHClient()
            manager.registerSSHClient(
                activeClient,
                shellId: UUID(),
                for: activePaneId,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )
            manager.updatePaneState(activePaneId, connectionState: .connected)

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(activeClient),
                "Stats should use the registry-active SSH pane lease instead of a stale selected Mosh pane."
            )
        }
    }

    @Test
    func tabManagerSharedStatsLeaseUsesPendingSSHWhenDomainMoshSnapshotIsStale() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let stalePaneId = UUID()
            let pendingPaneId = UUID()
            let tab = TerminalTab(
                serverId: server.id,
                title: server.name,
                rootPaneId: stalePaneId,
                focusedPaneId: stalePaneId
            )
            manager.tabsByServer[server.id] = [tab]

            var stalePane = TerminalPaneState(paneId: stalePaneId, tabId: tab.id, serverId: server.id)
            stalePane.connectionState = .connected
            stalePane.activeTransport = .mosh
            manager.paneStates[stalePaneId] = stalePane

            var pendingPane = TerminalPaneState(paneId: pendingPaneId, tabId: tab.id, serverId: server.id)
            pendingPane.connectionState = .disconnected
            pendingPane.activeTransport = .ssh
            manager.paneStates[pendingPaneId] = pendingPane

            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingPaneId, client: pendingClient))

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(pendingClient),
                "A stale domain Mosh pane snapshot must not block a pending SSH stats lease."
            )
        }
    }

    @Test
    func tabManagerRecordsSuccessfulConnectionTransportFromShellRegistry() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            var stalePane = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            stalePane.connectionState = .disconnected
            stalePane.activeTransport = .mosh
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = stalePane

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )

            // When the pane runtime reaches connected while the pane transport
            // snapshot is stale.
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            // Then successful-connection recording uses the registered shell
            // transport rather than TerminalPaneState.activeTransport.
            #expect(
                recorded.map(\.id) == [tab.rootPaneId],
                "The pane should be recorded exactly once when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Successful pane transport should come from the live shell registry."
            )
        }
    }

    @Test
    func tabManagerDefaultsSuccessfulConnectionTransportWhenRuntimeIsUnregistered() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            var stalePane = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            stalePane.connectionState = .disconnected
            stalePane.activeTransport = .mosh
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = stalePane

            // When a pane reaches connected without a live shell registry entry.
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            // Then successful-connection recording does not reuse the stale
            // TerminalPaneState.activeTransport snapshot.
            #expect(
                recorded.map(\.id) == [tab.rootPaneId],
                "The pane should still be recorded when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Unregistered pane runtime should record the safe default SSH transport."
            )
        }
    }

    @Test
    func tabManagerLivePaneIndicatorComesFromRegistryNotPaneStateSnapshots() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            var stalePaneState = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            stalePaneState.connectionState = .connected
            manager.paneStates[tab.rootPaneId] = stalePaneState

            #expect(
                !manager.hasLivePanes,
                "A stale pane snapshot must not make the tab manager report live pane runtime."
            )

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            #expect(
                manager.hasLivePanes,
                "Live pane state should turn true only after the registry records streaming runtime."
            )
        }
    }

    @Test
    func splitPaneUsesLatestTabStateWhenViewTabIsStale() async {
        await withCleanTabManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)

            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            guard let firstSplitPane = manager.splitHorizontal(tab: tab, paneId: tab.rootPaneId) else {
                Issue.record("First split failed unexpectedly")
                return
            }

            // Intentionally pass a stale snapshot (the original `tab` value) to simulate
            // view-state lag while still targeting a pane created by the first split.
            guard let secondSplitPane = manager.splitVertical(tab: tab, paneId: firstSplitPane) else {
                Issue.record("Second split failed unexpectedly")
                return
            }

            guard let latestTab = manager.tabs(for: server.id).first else {
                Issue.record("Expected tab to exist after split")
                return
            }

            let paneIds = Set(latestTab.allPaneIds)
            #expect(paneIds.contains(tab.rootPaneId))
            #expect(paneIds.contains(firstSplitPane))
            #expect(paneIds.contains(secondSplitPane))
            #expect(paneIds.count == 3)
        }
    }
}

private struct TestConnectionSessionsSnapshot: Codable {
    struct SessionSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let lastActivity: Date
        let autoReconnect: Bool
        let parentSessionId: UUID?
        let workingDirectory: String?
        let presentationOverrides: TerminalPresentationOverrides?
    }

    struct ServerSnapshot: Codable {
        let serverId: UUID
        let selectedSessionId: UUID?
        let selectedView: String?
    }

    let sessions: [SessionSnapshot]
    let selectedSessionId: UUID?
    let serverSelections: [ServerSnapshot]
}

private struct TestTerminalTabsSnapshot: Codable {
    struct ServerSnapshot: Codable {
        let serverId: UUID
        let tabs: [TabSnapshot]
        let selectedTabId: UUID?
        let selectedView: String?
    }

    struct TabSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let layout: TerminalSplitNode?
        let focusedPaneId: UUID
        let rootPaneId: UUID
        let panePresentationOverrides: [UUID: TerminalPresentationOverrides]?
    }

    let servers: [ServerSnapshot]
}

private actor RunnerTaskGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var runnerFinished = false
    private(set) var closeReturned = false

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func markRunnerFinished() {
        runnerFinished = true
    }

    func markCloseReturned() {
        closeReturned = true
    }
}

private actor CredentialProviderGate {
    private let credentials: ServerCredentials
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var loadCount = 0

    init(credentials: ServerCredentials) {
        self.credentials = credentials
    }

    func load() async -> ServerCredentials {
        loadCount += 1
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return credentials
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RecordingPaneRuntimeClient: TerminalConnectionClient {
    private(set) var events: [String] = []
    private let shellId = UUID()

    func connect() async throws {
        events.append("connect")
    }

    func startShell() async throws -> UUID {
        events.append("startShell")
        return shellId
    }

    func closeShell(_ shellId: UUID) async {
        events.append("closeShell")
    }

    func disconnect() async {
        events.append("disconnect")
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        events.append("write")
    }

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {
        events.append("resize")
    }
}
