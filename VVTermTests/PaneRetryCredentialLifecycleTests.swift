import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect split-pane retry, credential-load, and
// host-retrust request lifecycle ordering. They use TerminalTabManager with
// injected blocking providers/operations, so failures usually mean pane request
// coalescing, cancellation, runtime liveness revalidation, or credential
// boundary ownership changed. Update only when that pane request contract
// intentionally changes.

@Suite(.serialized)
@MainActor
struct PaneRetryCredentialLifecycleTests {
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

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        manager.setRejectedShellCleanupOperationForTesting {}
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
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
            let credentialGate = PaneCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
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

            // When another retry intent arrives before credential loading completes.
            let duplicateResult = await manager.retryPaneConnection(
                paneId: paneId,
                server: server
            )

            // Then the manager-owned retry gate rejects the duplicate.
            #expect(duplicateResult.isSkipped)

            await credentialGate.release()
            let result = await firstRetry.value
            #expect(result.credentials?.serverId == server.id)
            #expect(
                await credentialGate.loadCount == 1,
                "Duplicate pane retry intent must not load credentials a second time."
            )
            #expect(manager.paneStates[paneId]?.connectionState == .reconnecting(attempt: 1))
        }
    }

    @Test
    func tabManagerRetryRequestCoalescesDuplicateCallersUntilOperationCompletes() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .disconnected
            let gate = PaneRetryOperationGate()
            let credentials = makeCredentials(serverId: server.id)
            manager.paneStates[paneId] = paneState
            manager.setPaneRetryOperationForTesting { requestPaneId, requestServer in
                #expect(requestPaneId == paneId)
                #expect(requestServer.id == server.id)
                await gate.run()
                return .started(credentials)
            }
            var firstResult: TerminalReconnectRequestResult?
            var secondResult: TerminalReconnectRequestResult?

            // Given split SwiftUI sends retry intent and TerminalTabManager
            // owns the blocking credential/reconnect operation.
            let firstRequestID = manager.requestPaneRetry(
                paneId: paneId,
                server: server,
                onCompleted: { firstResult = $0 }
            )

            let secondRequestID = manager.requestPaneRetry(
                paneId: paneId,
                server: server,
                onCompleted: { secondResult = $0 }
            )
            await gate.waitForCallCount(1)

            // Then duplicate callers share one request and all receive the
            // final retry result when the manager-owned task completes.
            #expect(secondRequestID == firstRequestID)
            #expect(manager.pendingPaneRetryRequestIDs == [firstRequestID])
            #expect(firstResult == nil)
            #expect(secondResult == nil)
            #expect(await gate.callCount == 1)

            await gate.release()
            await manager.waitForPaneRetryRequest(firstRequestID)

            #expect(firstResult?.credentials?.serverId == server.id)
            #expect(secondResult?.credentials?.serverId == server.id)
            #expect(manager.pendingPaneRetryRequestIDs.isEmpty)
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
            let credentialGate = PaneCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.paneStates[paneId] = paneState
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }

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

            #expect(
                result.isSkipped,
                "Pane retry must revalidate runtime liveness after awaited credential loading."
            )
        }
    }

    @Test
    func tabManagerHostRetrustRequestCoalescesDuplicateCallersUntilOperationCompletes() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            let gate = PaneRetryOperationGate()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .failed("Host key verification failed")
            manager.paneStates[paneId] = paneState
            manager.setPaneHostRetrustOperationForTesting { requestPaneId, requestServer in
                #expect(requestPaneId == paneId)
                #expect(requestServer.id == server.id)
                await gate.run()
                return true
            }
            var firstResult: Bool?
            var secondResult: Bool?

            let firstRequestID = manager.requestPaneHostRetrust(
                paneId: paneId,
                server: server,
                onCompleted: { firstResult = $0 }
            )
            let secondRequestID = manager.requestPaneHostRetrust(
                paneId: paneId,
                server: server,
                onCompleted: { secondResult = $0 }
            )
            await gate.waitForCallCount(1)

            #expect(secondRequestID == firstRequestID)
            #expect(manager.pendingPaneHostRetrustRequestIDs == [firstRequestID])
            #expect(firstResult == nil)
            #expect(secondResult == nil)
            #expect(await gate.callCount == 1)

            await gate.release()
            await manager.waitForPaneHostRetrustRequest(firstRequestID)

            #expect(firstResult == true)
            #expect(secondResult == true)
            #expect(manager.pendingPaneHostRetrustRequestIDs.isEmpty)
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

            #expect(
                result.credentials?.serverId == server.id,
                "TerminalPaneView should obtain wrapper credentials through TerminalTabManager."
            )
        }
    }

    @Test
    func tabManagerCredentialLoadRequestCoalescesDuplicateCallersUntilProviderCompletes() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let credentialGate = PaneCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }
            var firstResult: TerminalCredentialLoadResult?
            var secondResult: TerminalCredentialLoadResult?

            // Given split-pane UI sends credential-load intent while the
            // Keychain-backed provider is still blocked.
            let firstRequestID = manager.requestPaneCredentialLoad(
                paneId: tab.rootPaneId,
                server: server,
                onCompleted: { firstResult = $0 }
            )
            let secondRequestID = manager.requestPaneCredentialLoad(
                paneId: tab.rootPaneId,
                server: server,
                onCompleted: { secondResult = $0 }
            )
            await credentialGate.waitForLoadCount(1)

            // Then duplicate intent shares one manager-owned request until the
            // provider returns.
            #expect(secondRequestID == firstRequestID)
            #expect(manager.pendingPaneCredentialLoadRequestIDs == [firstRequestID])
            #expect(firstResult == nil)
            #expect(secondResult == nil)
            #expect(await credentialGate.loadCount == 1)

            await credentialGate.release()
            await manager.waitForPaneCredentialLoadRequest(firstRequestID)

            #expect(firstResult?.credentials?.serverId == server.id)
            #expect(secondResult?.credentials?.serverId == server.id)
            #expect(manager.pendingPaneCredentialLoadRequestIDs.isEmpty)
        }
    }

    @Test
    func tabManagerCredentialLoadSuppressesCompletionIfPaneChangesServerWhileLoading() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let replacementServer = makeServer()
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let credentialGate = PaneCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }
            var result: TerminalCredentialLoadResult?

            let requestID = manager.requestPaneCredentialLoad(
                paneId: tab.rootPaneId,
                server: server,
                onCompleted: { result = $0 }
            )
            await credentialGate.waitForLoadCount(1)

            // Given credential loading is in flight and the pane is rebound to another server.
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: replacementServer.id
            )
            await credentialGate.release()
            await manager.waitForPaneCredentialLoadRequest(requestID)

            // Then the application layer suppresses the stale completion before UI sees it.
            #expect(result == nil)
            #expect(manager.pendingPaneCredentialLoadRequestIDs.isEmpty)
        }
    }

    @Test
    func tabManagerClosePaneCancelsPendingCredentialLoadRequest() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let credentialGate = PaneCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }
            var results: [TerminalCredentialLoadResult] = []

            // Given a credential-load request is pending for a pane.
            let requestID = manager.requestPaneCredentialLoad(
                paneId: tab.rootPaneId,
                server: server,
                onCompleted: { results.append($0) }
            )
            await credentialGate.waitForLoadCount(1)

            // When the owning pane closes before the provider returns.
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)
            let waitProbe = PaneRetryWaitProbe()
            let waitTask = Task {
                await manager.waitForPaneCredentialLoadRequest(requestID)
                await waitProbe.markReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then lifecycle cancellation clears request state without later
            // delivering a user-facing credential result.
            #expect(manager.pendingPaneCredentialLoadRequestIDs.isEmpty)
            #expect(results.isEmpty)
            #expect(
                await !waitProbe.didReturn,
                "Pane credential-load wait hook must remain tracked until the blocked provider exits."
            )
            await credentialGate.release()
            await waitTask.value
            #expect(await waitProbe.didReturn)
            try? await Task.sleep(for: .milliseconds(20))
            #expect(
                results.isEmpty,
                "A canceled pane credential-load request must not send a later success or failure callback."
            )
        }
    }
}

private actor PaneRetryWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}

private actor PaneCredentialProviderGate {
    private let credentials: ServerCredentials
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var loadCountContinuations: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var loadCount = 0

    init(credentials: ServerCredentials) {
        self.credentials = credentials
    }

    func load() async -> ServerCredentials {
        loadCount += 1
        resumeLoadCountContinuations()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return credentials
    }

    func waitForLoadCount(_ expectedCount: Int) async {
        if loadCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            loadCountContinuations.append((expectedCount, continuation))
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func resumeLoadCountContinuations() {
        let ready = loadCountContinuations.filter { loadCount >= $0.0 }
        loadCountContinuations.removeAll { loadCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor PaneRetryOperationGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var callContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var callCount = 0

    func run() async {
        callCount += 1
        callContinuations.forEach { $0.resume() }
        callContinuations.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
