import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect RemoteFiles browser state rules: entry filtering,
// per-tab persistence, initial path selection, directory/viewer request
// ordering, user mutation task ownership, and transfer task ownership. Fakes
// use in-memory UserDefaults suites, injected providers, and small ordering
// probes, so failures usually indicate a browser-state or lifecycle ownership
// regression unless the persisted snapshot model, path-precedence product rule,
// or application-layer request owner intentionally changes.
@MainActor
struct RemoteFileBrowserStoreTests {
    @Test
    func displayedEntriesHideDotFilesAndKeepDirectoryOrdering() {
        let defaults = makeDefaults()
        let store = RemoteFileBrowserStore(defaults: defaults)
        let tab = makeTab()

        store.updateState(for: tab) { state in
            state.entries = [
                makeEntry(name: ".secret", path: "/tmp/.secret", type: .file),
                makeEntry(name: "docs", path: "/tmp/docs", type: .directory),
                makeEntry(name: "readme.md", path: "/tmp/readme.md", type: .file)
            ]
            state.showHiddenFiles = false
            state.sort = .name
            state.sortDirection = .ascending
        }

        #expect(store.displayedEntries(for: tab).map(\.name) == ["docs", "readme.md"])
    }

    @Test
    func persistedStateLoadsIntoFreshStoreInstance() {
        let defaults = makeDefaults()
        let tab = makeTab()

        let store = RemoteFileBrowserStore(defaults: defaults)
        store.updateState(for: tab) { state in
            state.currentPath = "/srv/releases"
            state.sort = .size
            state.sortDirection = .ascending
            state.showHiddenFiles = true
            state.hasCustomizedHiddenFiles = true
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(defaults: defaults)
        let persisted = reloadedStore.persistedState(for: tab.id)

        #expect(persisted.lastVisitedPath == "/srv/releases")
        #expect(persisted.sort == .size)
        #expect(persisted.sortDirection == .ascending)
        #expect(persisted.showHiddenFiles)
        #expect(persisted.hasCustomizedHiddenFiles)
    }

    @Test
    func legacyServerScopedSnapshotIsDiscardedOnLoad() throws {
        let defaults = makeDefaults()
        let legacyKey = "remoteFileBrowserState.v1"
        let legacyPayload = try JSONEncoder().encode([
            UUID().uuidString: RemoteFileBrowserPersistedState(lastVisitedPath: "/legacy")
        ])
        defaults.set(legacyPayload, forKey: legacyKey)

        let store = RemoteFileBrowserStore(defaults: defaults)

        #expect(defaults.object(forKey: legacyKey) == nil)
        #expect(store.persistedStates.isEmpty)
    }

    @Test
    func initialDirectoryCandidatesPreferPersistedPathOverSeedPath() {
        let defaults = makeDefaults()
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/etc")

        let store = RemoteFileBrowserStore(
            defaults: defaults,
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        store.updateState(for: tab) { state in
            state.currentPath = "/etc/nginx"
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(
            defaults: defaults,
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        let candidates = reloadedStore.initialDirectoryCandidates(
            for: server,
            tab: tab,
            initialPath: tab.seedPath
        )

        #expect(candidates == ["/etc/nginx", "/etc", "/srv/app"])
    }

    @Test
    func sameServerOperationWaitsForDroppedDisconnectTask() async throws {
        let defaults = makeDefaults()
        let server = makeServer()
        let disconnectingClient = BlockingDisconnectRemoteFileClient()
        let nextClient = BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [disconnectingClient, nextClient]
        let operationProbe = RemoteFileOperationProbe()
        let store = RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            )
        )

        // Given RemoteFiles has an established service registration for a
        // server, and iOS sends disconnect intent without awaiting the returned
        // task.
        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        _ = store.disconnect(serverId: server.id)
        await disconnectingClient.waitUntilDisconnectStarted()

        // When a later same-server operation starts while the disconnect is
        // still closing the previous lease.
        let operationTask = Task {
            try await store.withRemoteFileService(for: server) { _ in
                await operationProbe.markStarted()
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then the store must wait for the pending disconnect instead of
        // racing a new SFTP registration over teardown.
        #expect(
            await !operationProbe.started,
            "Same-server RemoteFiles operations must wait for a pending disconnect even if the caller dropped the disconnect task."
        )

        await disconnectingClient.releaseDisconnect()
        try await operationTask.value
        #expect(await operationProbe.started)
    }

    @Test
    func sameServerOperationWaitsForDisconnectRegisteredAfterFirstWait() async throws {
        let defaults = makeDefaults()
        let server = makeServer()
        let firstClient = BlockingDisconnectRemoteFileClient()
        let secondClient = BlockingDisconnectRemoteFileClient()
        let thirdClient = BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [firstClient, secondClient, thirdClient]
        let operationProbe = RemoteFileOperationProbe()
        let store = RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            )
        )
        var insertedSecondDisconnect = false
        store.setPendingDisconnectWaitDidFinishForTesting { serverId in
            guard serverId == server.id, !insertedSecondDisconnect else { return }
            insertedSecondDisconnect = true
            store.setPendingDisconnectWaitDidFinishForTesting(nil)
            _ = try? await store.withRemoteFileService(for: server) { service in
                try await service.resolveHomeDirectory()
            }
            _ = store.disconnect(serverId: server.id)
            await secondClient.waitUntilDisconnectStarted()
        }

        // Given an operation is waiting for a dropped disconnect task.
        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        _ = store.disconnect(serverId: server.id)
        await firstClient.waitUntilDisconnectStarted()
        let operationTask = Task {
            try await store.withRemoteFileService(for: server) { _ in
                await operationProbe.markStarted()
            }
        }

        // When the first disconnect finishes, another same-server disconnect
        // is registered before the waiting operation resumes service work.
        await firstClient.releaseDisconnect()
        try await Task.sleep(for: .milliseconds(20))

        // Then the waiting operation must re-check and wait for the second
        // pending disconnect too.
        #expect(
            await !operationProbe.started,
            "RemoteFiles should re-check pending disconnects after each awaited disconnect task."
        )

        await secondClient.releaseDisconnect()
        try await operationTask.value
        #expect(await operationProbe.started)
    }

    @Test
    func mutationRequestTracksTaskAndRunsSuccessAfterOperation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let gate = RemoteFileMutationGate()
        var events: [String] = []

        // Given a RemoteFiles mutation launched from synchronous UI intent.
        let requestID = store.requestMutation(
            operation: {
                events.append("operation-started")
                await gate.wait()
                events.append("operation-finished")
                return "created"
            },
            onSuccess: { result in
                events.append("success-\(result)")
            },
            onFailure: { _ in
                events.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        // Then the application store owns and exposes the pending mutation task
        // until the async operation finishes.
        #expect(store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started"])

        await gate.release()
        await store.waitForMutationRequest(requestID)

        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "operation-finished", "success-created"])
    }

    @Test
    func mutationRequestTracksFailureAndSkipsSuccessContinuation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        var events: [String] = []

        // Given a RemoteFiles mutation whose async operation fails before it
        // can safely update UI state.
        let requestID = store.requestMutation(
            operation: {
                events.append("operation-started")
                throw RemoteFileMutationIntentFailure()
            },
            onSuccess: {
                events.append("success")
            },
            onFailure: { error in
                events.append("failure-\(type(of: error))")
            }
        )
        await store.waitForMutationRequest(requestID)

        // Then the application store keeps the failure path ordered and removes
        // the tracked request only after the failure handler runs.
        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "failure-RemoteFileMutationIntentFailure"])
    }

    @Test
    func transferRequestTracksTaskProgressAndSuccessAfterOperation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let gate = RemoteFileMutationGate()
        var events: [String] = []

        // Given a RemoteFiles transfer launched from synchronous UI intent.
        let requestID = store.requestTransfer(
            operation: { onProgress in
                events.append("operation-started")
                onProgress(RemoteFileBrowserStore.TransferProgress(
                    completedUnitCount: 1,
                    totalUnitCount: 2,
                    currentItemName: "logs.txt"
                ))
                await gate.wait()
                events.append("operation-finished")
                return "exported"
            },
            onProgress: { progress in
                events.append("progress-\(progress.completedUnitCount)-\(progress.totalUnitCount)-\(progress.currentItemName)")
            },
            onSuccess: { result in
                events.append("success-\(result)")
            },
            onFailure: { _ in
                events.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        // Then the application store owns the transfer task until the async
        // operation and success continuation finish.
        #expect(store.pendingTransferRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "progress-1-2-logs.txt"])

        await gate.release()
        await store.waitForTransferRequest(requestID)

        #expect(!store.pendingTransferRequestIDs.contains(requestID))
        #expect(events == [
            "operation-started",
            "progress-1-2-logs.txt",
            "operation-finished",
            "success-exported"
        ])
    }

    @Test
    func moveDestinationLoadRequestTracksDirectoryListingUntilCompletion() async throws {
        let server = makeServer()
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeEntry(name: "zeta.log", path: "/srv/zeta.log", type: .file),
                    makeEntry(name: "beta", path: "/srv/beta", type: .directory),
                    makeEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeStore(server: server, client: client)
        var results: [Result<[RemoteFileEntry], Error>] = []

        // Given a move destination sheet sends folder-list intent while remote
        // directory listing is still blocked.
        let requestID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            results.append(result)
        }
        await client.waitUntilListStarted(path: "/srv")

        // Then RemoteFileBrowserStore exposes the request until the listing
        // finishes, rather than letting the sheet own remote SFTP work.
        #expect(store.pendingMoveDestinationLoadRequestIDs.contains(requestID))
        #expect(results.isEmpty)

        await client.releaseList(path: "/srv")
        await store.waitForMoveDestinationLoadRequest(requestID)

        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(requestID))
        #expect(try results.singleSuccess().map(\.path) == ["/srv/alpha", "/srv/beta"])
    }

    @Test
    func duplicateMoveDestinationLoadRequestsCoalesceUntilCompletion() async throws {
        let server = makeServer()
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeStore(server: server, client: client)
        var callbacks: [String] = []

        // Given the same move destination folder is requested twice while the
        // first remote listing is still in flight.
        let firstID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            if case .success = result {
                callbacks.append("first")
            }
        }
        await client.waitUntilListStarted(path: "/srv")
        let secondID = store.requestMoveDestinationLoad(path: "/srv/", server: server) { result in
            if case .success = result {
                callbacks.append("second")
            }
        }

        // Then duplicate same-server/same-path intent joins one store-owned
        // request and does not start duplicate SFTP list work.
        #expect(firstID == secondID)
        #expect(store.pendingMoveDestinationLoadRequestIDs == [firstID])
        #expect(await client.listCount(path: "/srv") == 1)

        await client.releaseList(path: "/srv")
        await store.waitForMoveDestinationLoadRequest(firstID)

        #expect(callbacks == ["first", "second"])
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(firstID))
    }

    @Test
    func moveDestinationLoadCancellationRemainsAwaitableUntilListingExits() async throws {
        let server = makeServer()
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeStore(server: server, client: client)
        let waitProbe = RemoteFileWaitProbe()
        var results: [Result<[RemoteFileEntry], Error>] = []

        // Given lifecycle cleanup cancels a pending move destination list
        // request while the remote service operation is blocked.
        let requestID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            results.append(result)
        }
        await client.waitUntilListStarted(path: "/srv")
        store.cancelMoveDestinationLoadRequestForTesting(requestID)

        let waitTask = Task {
            await store.waitForMoveDestinationLoadRequest(requestID)
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then visible pending state clears immediately, but the wait hook
        // remains tracked until the blocked list operation exits.
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(requestID))
        #expect(
            await !waitProbe.didReturn,
            "Move destination load wait hook must not return before the blocked remote listing exits."
        )

        await client.releaseList(path: "/srv")
        await waitTask.value

        #expect(await waitProbe.didReturn)
        #expect(results.isEmpty)
    }

    @Test
    func replacementMoveDestinationLoadAfterCancellationRemainsCurrent() async throws {
        let server = makeServer()
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeStore(server: server, client: client)
        var canceledResults: [Result<[RemoteFileEntry], Error>] = []
        var replacementResults: [Result<[RemoteFileEntry], Error>] = []

        // Given a move destination load is canceled while its remote list is
        // still blocked.
        let canceledID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            canceledResults.append(result)
        }
        await client.waitUntilListCount(path: "/srv", count: 1)
        store.cancelMoveDestinationLoadRequestForTesting(canceledID)

        // When the user immediately requests the same destination path again.
        let replacementID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            replacementResults.append(result)
        }

        // Then the replacement is visible as current, and the older canceled
        // request cannot remove its key or deliver a stale callback.
        #expect(replacementID != canceledID)
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(canceledID))
        #expect(store.pendingMoveDestinationLoadRequestIDs.contains(replacementID))

        await client.releaseList(path: "/srv")
        await store.waitForMoveDestinationLoadRequest(canceledID)
        await store.waitForMoveDestinationLoadRequest(replacementID)

        #expect(canceledResults.isEmpty)
        #expect(try replacementResults.singleSuccess().map(\.path) == ["/srv/alpha"])
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(replacementID))
    }

    @Test
    func disconnectCancelsVisibleMoveDestinationLoadRequestsForServer() async throws {
        let server = makeServer()
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeStore(server: server, client: client)
        var results: [Result<[RemoteFileEntry], Error>] = []

        // Given a move destination folder load is waiting inside remote
        // directory IO for a server that is about to disconnect.
        let requestID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            results.append(result)
        }
        await client.waitUntilListStarted(path: "/srv")

        // When the same server disconnects.
        _ = store.disconnect(serverId: server.id)

        // Then visible move destination pending state clears immediately, and
        // the canceled callback cannot update sheet presentation after teardown.
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(requestID))

        await client.releaseList(path: "/srv")
        await store.waitForMoveDestinationLoadRequest(requestID)

        #expect(results.isEmpty)
    }

    @Test
    func navigationRequestTracksInitialDirectoryLoadUntilSnapshotCompletes() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/srv")
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [makeEntry(name: "app", path: "/srv/app", type: .directory)]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeStore(server: server, client: client)

        // Given SwiftUI sends initial browser load intent through the
        // application store while the remote directory list is still blocked.
        let requestID = store.requestNavigation(
            .loadInitialPath(initialPath: "/srv"),
            in: tab,
            server: server
        )
        await client.waitUntilListStarted(path: "/srv")

        // Then the store exposes the pending navigation request until the
        // remote snapshot finishes.
        #expect(store.pendingNavigationRequestIDs.contains(requestID))
        #expect(
            store.isLoading(for: tab),
            "Initial directory load intent should leave loading state owned by RemoteFileBrowserStore."
        )

        await client.releaseList(path: "/srv")
        await store.waitForNavigationRequest(requestID)

        #expect(!store.pendingNavigationRequestIDs.contains(requestID))
        #expect(store.currentPathValue(for: tab) == "/srv")
        #expect(store.entries(for: tab).map(\.path) == ["/srv/app"])
    }

    @Test
    func newerNavigationRequestCancelsVisiblePendingRequestAndSkipsStaleResult() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id)
        let slowEntry = makeEntry(name: "slow", path: "/slow", type: .directory)
        let fileEntry = makeEntry(name: "current.txt", path: "/current.txt", type: .file)
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/slow": [makeEntry(name: "stale.txt", path: "/slow/stale.txt", type: .file)]
            ],
            blockedListPaths: ["/slow"]
        )
        let store = makeStore(server: server, client: client)

        // Given one directory navigation is blocked by a slow remote response.
        let slowRequestID = store.requestNavigation(.openDirectory(slowEntry), in: tab, server: server)
        await client.waitUntilListStarted(path: "/slow")

        // When the user immediately sends a newer same-tab activation intent
        // that does not need to queue behind the same remote directory list.
        let activationRequestID = store.requestNavigation(.activate(fileEntry), in: tab, server: server)
        await store.waitForNavigationRequest(activationRequestID)

        // Then the older request is no longer visible as pending, but remains
        // awaitable until its blocked fake exits.
        #expect(!store.pendingNavigationRequestIDs.contains(slowRequestID))
        #expect(!store.pendingNavigationRequestIDs.contains(activationRequestID))
        #expect(store.selectedEntryPath(for: tab) == "/current.txt")

        await client.releaseList(path: "/slow")
        await store.waitForNavigationRequest(slowRequestID)

        // Then the stale slow result cannot overwrite the newer selection.
        #expect(store.currentPathValue(for: tab) == nil)
        #expect(store.selectedEntryPath(for: tab) == "/current.txt")
    }

    @Test
    func removeRuntimeStateCancelsVisibleNavigationRequestButKeepsWaitHookAwaitable() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id)
        let entry = makeEntry(name: "logs", path: "/logs", type: .directory)
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/logs": [makeEntry(name: "app.log", path: "/logs/app.log", type: .file)]
            ],
            blockedListPaths: ["/logs"]
        )
        let store = makeStore(server: server, client: client)

        // Given a navigation request is waiting inside remote directory IO.
        let requestID = store.requestNavigation(.openDirectory(entry), in: tab, server: server)
        await client.waitUntilListStarted(path: "/logs")

        // When runtime state is removed for the tab.
        store.removeRuntimeState(for: tab.id)

        // Then visible pending state clears immediately, while the wait hook
        // still waits for the blocked request task to exit.
        #expect(!store.pendingNavigationRequestIDs.contains(requestID))
        await client.releaseList(path: "/logs")
        await store.waitForNavigationRequest(requestID)

        #expect(store.currentPathValue(for: tab) == nil)
        #expect(!store.state(for: tab).hasLoadedDirectory)
    }

    @Test
    func disconnectCancelsVisibleNavigationRequestsBeforeRemoteDisconnect() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id)
        let entry = makeEntry(name: "tmp", path: "/tmp", type: .directory)
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/tmp": [makeEntry(name: "file.txt", path: "/tmp/file.txt", type: .file)]
            ],
            blockedListPaths: ["/tmp"]
        )
        let store = makeStore(server: server, client: client)

        // Given RemoteFiles has visible runtime state plus a pending navigation
        // request for a server that is about to disconnect.
        let requestID = store.requestNavigation(.openDirectory(entry), in: tab, server: server)
        await client.waitUntilListStarted(path: "/tmp")

        // When the server disconnects.
        _ = store.disconnect(serverId: server.id)

        // Then the store clears visible navigation pending state before remote
        // service teardown proceeds.
        #expect(!store.pendingNavigationRequestIDs.contains(requestID))
        await client.releaseList(path: "/tmp")
        await store.waitForNavigationRequest(requestID)

        #expect(store.currentPathValue(for: tab) == nil)
    }

    @Test
    func disconnectCancelsQueuedNavigationBeforeRuntimeStateExists() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/srv")
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [makeEntry(name: "app", path: "/srv/app", type: .directory)]
            ]
        )
        let store = makeStore(server: server, client: client)

        // Given SwiftUI has queued an initial-load navigation request, but the
        // task has not yet created BrowserState for the tab.
        let requestID = store.requestNavigation(
            .loadInitialPath(initialPath: "/srv"),
            in: tab,
            server: server
        )
        #expect(store.pendingNavigationRequestIDs.contains(requestID))
        #expect(
            store.currentPathValue(for: tab) == nil,
            "This regression covers disconnect before initial navigation creates runtime state."
        )

        // When the same server disconnects immediately.
        _ = store.disconnect(serverId: server.id)
        await store.waitForNavigationRequest(requestID)

        // Then the queued request must be canceled by server identity and must
        // not recreate runtime state or start remote listing after disconnect.
        #expect(!store.pendingNavigationRequestIDs.contains(requestID))
        #expect(store.currentPathValue(for: tab) == nil)
        #expect(
            await !client.hasListed(path: "/srv"),
            "Server disconnect must cancel queued navigation even when no BrowserState exists yet."
        )
    }

    @Test
    func wrongServerNavigationIntentDoesNotCancelCurrentTabRequest() async throws {
        let server = makeServer()
        let wrongServer = Server(
            id: UUID(),
            workspaceId: server.workspaceId,
            name: "Stale",
            host: "stale.example.com",
            username: "root"
        )
        let tab = RemoteFileTab(serverId: server.id)
        let entry = makeEntry(name: "logs", path: "/logs", type: .directory)
        let client = BlockingNavigationRemoteFileClient(
            listResponses: [
                "/logs": [makeEntry(name: "app.log", path: "/logs/app.log", type: .file)]
            ],
            blockedListPaths: ["/logs"]
        )
        let store = makeStore(server: server, client: client)

        // Given a valid same-tab navigation request is blocked in remote IO.
        let validRequestID = store.requestNavigation(.openDirectory(entry), in: tab, server: server)
        await client.waitUntilListStarted(path: "/logs")

        // When stale UI sends an intent for a different server using the same tab.
        let staleRequestID = store.requestNavigation(
            .loadInitialPath(initialPath: "/stale"),
            in: tab,
            server: wrongServer
        )
        await store.waitForNavigationRequest(staleRequestID)

        // Then the invalid intent is skipped without canceling the current
        // valid request for the tab.
        #expect(
            store.pendingNavigationRequestIDs.contains(validRequestID),
            "Wrong-server navigation intent must validate before canceling the active tab request."
        )

        await client.releaseList(path: "/logs")
        await store.waitForNavigationRequest(validRequestID)

        #expect(store.currentPathValue(for: tab) == "/logs")
        #expect(store.entries(for: tab).map(\.path) == ["/logs/app.log"])
    }

    @Test
    func activationRequestReportsSelectedFileWithoutUIOwnedAsyncTask() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id)
        let symlink = makeEntry(name: "latest.log", path: "/latest.log", type: .symlink)
        let resolved = makeEntry(name: "latest.log", path: "/latest.log", type: .file)
        let client = BlockingNavigationRemoteFileClient(stats: ["/latest.log": resolved])
        let store = makeStore(server: server, client: client)
        var results: [RemoteFileNavigationResult] = []

        // Given entry activation intent resolves a symlink to a file.
        let requestID = store.requestNavigation(.activate(symlink), in: tab, server: server) { result in
            results.append(result)
        }
        await store.waitForNavigationRequest(requestID)

        // Then the store owns the async stat/select ordering and reports only
        // a presentation result to UI callbacks.
        #expect(results == [.selectedFile(symlink)])
        #expect(store.selectedEntryPath(for: tab) == "/latest.log")
    }

    @Test
    func newerActivationRequestPreventsBlockedSymlinkStatFromSelectingStaleFile() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id)
        let symlink = makeEntry(name: "latest.log", path: "/latest.log", type: .symlink)
        let staleResolvedFile = makeEntry(name: "latest.log", path: "/latest.log", type: .file)
        let currentFile = makeEntry(name: "current.log", path: "/current.log", type: .file)
        let client = BlockingNavigationRemoteFileClient(
            stats: ["/latest.log": staleResolvedFile],
            blockedStatPaths: ["/latest.log"]
        )
        let store = makeStore(server: server, client: client)

        // Given a symlink activation request is blocked while resolving the
        // remote target type.
        let staleRequestID = store.requestNavigation(.activate(symlink), in: tab, server: server)
        await client.waitUntilStatStarted(path: "/latest.log")

        // When a newer same-tab activation selects another file.
        let currentRequestID = store.requestNavigation(.activate(currentFile), in: tab, server: server)
        await store.waitForNavigationRequest(currentRequestID)
        #expect(store.selectedEntryPath(for: tab) == "/current.log")

        // Then the older stat result remains awaitable but cannot write stale
        // selection state after it resumes.
        await client.releaseStat(path: "/latest.log")
        await store.waitForNavigationRequest(staleRequestID)

        #expect(store.selectedEntryPath(for: tab) == "/current.log")
    }

    private func makeEntry(name: String, path: String, type: RemoteFileType) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private func makeTab() -> RemoteFileTab {
        RemoteFileTab(serverId: UUID(), seedPath: "/tmp")
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Production",
            host: "example.com",
            username: "root"
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileBrowserStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(
        server: Server,
        client: BlockingNavigationRemoteFileClient
    ) -> RemoteFileBrowserStore {
        RemoteFileBrowserStore(
            defaults: makeDefaults(),
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: {
                    client
                }
            )
        )
    }
}

private actor RemoteFileOperationProbe {
    private(set) var started = false

    func markStarted() {
        started = true
    }
}

private struct RemoteFileMutationIntentFailure: Error {}

private struct RemoteFileMoveDestinationLoadFailure: Error {}

private extension Array where Element == Result<[RemoteFileEntry], Error> {
    func singleSuccess() throws -> [RemoteFileEntry] {
        guard count == 1, case .success(let entries) = self[0] else {
            throw RemoteFileMoveDestinationLoadFailure()
        }
        return entries
    }
}

private actor RemoteFileMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RemoteFileWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}

private actor BlockingDisconnectRemoteFileClient: SFTPRemoteFileClient {
    private var disconnectStarted = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    func waitUntilDisconnectStarted() async {
        if disconnectStarted { return }
        await withCheckedContinuation { continuation in
            disconnectWaiters.append(continuation)
        }
    }

    func releaseDisconnect() {
        if let releaseContinuation {
            releaseContinuation.resume()
            self.releaseContinuation = nil
        } else {
            releaseRequested = true
        }
    }

    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws {}

    func disconnect() async {
        disconnectStarted = true
        for waiter in disconnectWaiters {
            waiter.resume()
        }
        disconnectWaiters.removeAll()
        guard !releaseRequested else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String { "" }

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment { .fallbackPOSIX }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType { .xterm256Color }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] { [] }

    func stat(at path: String) async throws -> RemoteFileEntry {
        makeEntry(path: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        makeEntry(path: path)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data { Data() }

    func downloadFile(at path: String, to localURL: URL) async throws {}

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {}

    func deleteDirectory(at path: String) async throws {}

    func setPermissions(at path: String, permissions: UInt32) async throws {}

    func resolveHomeDirectory() async throws -> String { "/home/test" }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        RemoteFileFilesystemStatus(
            blockSize: 1,
            totalBlocks: 0,
            freeBlocks: 0,
            availableBlocks: 0
        )
    }

    private func makeEntry(path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}

private actor BlockingNavigationRemoteFileClient: SFTPRemoteFileClient {
    private var listResponses: [String: [RemoteFileEntry]]
    private var stats: [String: RemoteFileEntry]
    private var blockedListPaths: Set<String>
    private var blockedStatPaths: Set<String>
    private var releasedListPaths: Set<String> = []
    private var listStartedPaths: Set<String> = []
    private var listCounts: [String: Int] = [:]
    private var listStartedWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var listCountWaiters: [String: [(count: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]
    private var listReleaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedStatPaths: Set<String> = []
    private var statStartedPaths: Set<String> = []
    private var statStartedWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var statReleaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        listResponses: [String: [RemoteFileEntry]] = [:],
        stats: [String: RemoteFileEntry] = [:],
        blockedListPaths: Set<String> = [],
        blockedStatPaths: Set<String> = []
    ) {
        self.listResponses = listResponses
        self.stats = stats
        self.blockedListPaths = blockedListPaths
        self.blockedStatPaths = blockedStatPaths
    }

    func waitUntilListStarted(path: String) async {
        let normalizedPath = Self.normalizePath(path)
        if listStartedPaths.contains(normalizedPath) { return }
        await withCheckedContinuation { continuation in
            listStartedWaiters[normalizedPath, default: []].append(continuation)
        }
    }

    func waitUntilListCount(path: String, count: Int) async {
        let normalizedPath = Self.normalizePath(path)
        if listCounts[normalizedPath, default: 0] >= count { return }
        await withCheckedContinuation { continuation in
            listCountWaiters[normalizedPath, default: []].append((count, continuation))
        }
    }

    func releaseList(path: String) {
        let normalizedPath = Self.normalizePath(path)
        releasedListPaths.insert(normalizedPath)
        for waiter in listReleaseWaiters.removeValue(forKey: normalizedPath) ?? [] {
            waiter.resume()
        }
    }

    func hasListed(path: String) -> Bool {
        listStartedPaths.contains(Self.normalizePath(path))
    }

    func listCount(path: String) -> Int {
        listCounts[Self.normalizePath(path)] ?? 0
    }

    func waitUntilStatStarted(path: String) async {
        let normalizedPath = Self.normalizePath(path)
        if statStartedPaths.contains(normalizedPath) { return }
        await withCheckedContinuation { continuation in
            statStartedWaiters[normalizedPath, default: []].append(continuation)
        }
    }

    func releaseStat(path: String) {
        let normalizedPath = Self.normalizePath(path)
        releasedStatPaths.insert(normalizedPath)
        statReleaseWaiters.removeValue(forKey: normalizedPath)?.resume()
    }

    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws {}

    func disconnect() async {}

    func execute(_ command: String, timeout: Duration?) async throws -> String { "" }

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment { .fallbackPOSIX }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType { .xterm256Color }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] {
        let normalizedPath = Self.normalizePath(path)
        listStartedPaths.insert(normalizedPath)
        listCounts[normalizedPath, default: 0] += 1
        for waiter in listStartedWaiters.removeValue(forKey: normalizedPath) ?? [] {
            waiter.resume()
        }
        let startedCount = listCounts[normalizedPath, default: 0]
        let waiters = listCountWaiters.removeValue(forKey: normalizedPath) ?? []
        var remainingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if startedCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        if !remainingWaiters.isEmpty {
            listCountWaiters[normalizedPath] = remainingWaiters
        }

        if blockedListPaths.contains(normalizedPath), !releasedListPaths.contains(normalizedPath) {
            await withCheckedContinuation { continuation in
                listReleaseWaiters[normalizedPath, default: []].append(continuation)
            }
        }

        return listResponses[normalizedPath] ?? []
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        let normalizedPath = Self.normalizePath(path)
        statStartedPaths.insert(normalizedPath)
        for waiter in statStartedWaiters.removeValue(forKey: normalizedPath) ?? [] {
            waiter.resume()
        }

        if blockedStatPaths.contains(normalizedPath), !releasedStatPaths.contains(normalizedPath) {
            await withCheckedContinuation { continuation in
                statReleaseWaiters[normalizedPath] = continuation
            }
        }

        return stats[normalizedPath] ?? makeEntry(path: path, type: .file)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        makeEntry(path: path, type: .file)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data { Data() }

    func downloadFile(at path: String, to localURL: URL) async throws {}

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {}

    func deleteDirectory(at path: String) async throws {}

    func setPermissions(at path: String, permissions: UInt32) async throws {}

    func resolveHomeDirectory() async throws -> String { "/home/test" }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        RemoteFileFilesystemStatus(
            blockSize: 1,
            totalBlocks: 0,
            freeBlocks: 0,
            availableBlocks: 0
        )
    }

    private func makeEntry(path: String, type: RemoteFileType) -> RemoteFileEntry {
        RemoteFileEntry(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private nonisolated static func normalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        let basePath = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let components = basePath.split(separator: "/", omittingEmptySubsequences: false)
        var normalized: [Substring] = []

        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            default:
                normalized.append(component)
            }
        }

        return "/" + normalized.joined(separator: "/")
    }
}
