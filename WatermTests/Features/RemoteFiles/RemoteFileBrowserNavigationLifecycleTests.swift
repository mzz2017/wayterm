import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect RemoteFiles navigation, activation, and move destination
// loading as application-layer requests owned by RemoteFileBrowserStore. The
// fake client blocks list/stat calls deterministically; update these tests only
// when the store intentionally changes request coalescing, cancellation, or
// stale-result suppression rules.
@MainActor
struct RemoteFileBrowserNavigationLifecycleTests {
    @Test
    func moveDestinationLoadRequestTracksDirectoryListingUntilCompletion() async throws {
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeRemoteFileBrowserEntry(name: "zeta.log", path: "/srv/zeta.log", type: .file),
                    makeRemoteFileBrowserEntry(name: "beta", path: "/srv/beta", type: .directory),
                    makeRemoteFileBrowserEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)
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
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeRemoteFileBrowserEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)
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
    func completionTriggeredMoveDestinationLoadStartsFreshRequest() async throws {
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeRemoteFileBrowserEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)
        var callbackOrder: [String] = []
        var restartedID: UUID?

        // Given a move destination load completion synchronously starts a
        // fresh same-server/same-path load, as a sheet can do while refreshing
        // after applying a destination change.
        let firstID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            if case .success = result {
                callbackOrder.append("first")
            }
            restartedID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
                if case .success = result {
                    callbackOrder.append("restarted")
                }
            }
        }
        await client.waitUntilListCount(path: "/srv", count: 1)

        // When the first remote listing completes.
        await client.releaseList(path: "/srv")
        await store.waitForMoveDestinationLoadRequest(firstID)

        // Then the callback-triggered intent starts a fresh owner request
        // instead of being appended to the completing request and cleared.
        let freshID = try #require(restartedID)
        try #require(
            freshID != firstID,
            "Callback-triggered move destination loads must not join the completing request."
        )
        await client.waitUntilListCount(path: "/srv", count: 2)
        await store.waitForMoveDestinationLoadRequest(freshID)

        #expect(await client.listCount(path: "/srv") == 2)
        #expect(callbackOrder == ["first", "restarted"])
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(firstID))
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(freshID))
    }

    @Test
    func moveDestinationLoadCancellationRemainsAwaitableUntilListingExits() async throws {
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeRemoteFileBrowserEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)
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
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeRemoteFileBrowserEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)
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
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeRemoteFileBrowserEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)
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
    func disconnectWaitsForCanceledMoveDestinationLoadBeforeRemoteDisconnect() async throws {
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [
                    makeRemoteFileBrowserEntry(name: "alpha", path: "/srv/alpha", type: .directory)
                ]
            ],
            blockedListPaths: ["/srv"],
            blocksDisconnect: true
        )
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(),
            remoteFileServiceAccess: NonSerializingRemoteFileServiceAccess(client: client),
            serverProvider: { _ in nil }
        )
        let waitProbe = RemoteFileWaitProbe()
        var results: [Result<[RemoteFileEntry], Error>] = []

        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }

        // Given a move destination folder load is blocked inside remote
        // directory IO for a server that is about to disconnect.
        let requestID = store.requestMoveDestinationLoad(path: "/srv", server: server) { result in
            results.append(result)
        }
        await client.waitUntilListStarted(path: "/srv")

        // When the same server disconnects.
        let disconnectTask = store.disconnect(serverId: server.id)
        let disconnectWaitTask = Task {
            await disconnectTask.value
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then service disconnect waits for the canceled listing to exit so
        // SFTP cleanup cannot race request cleanup.
        #expect(!store.pendingMoveDestinationLoadRequestIDs.contains(requestID))
        #expect(
            await !client.hasStartedDisconnect(),
            "RemoteFiles disconnect should wait for canceled move destination listing to exit before disconnecting the SFTP service."
        )
        #expect(
            await !waitProbe.didReturn,
            "RemoteFiles disconnect task should not complete while canceled move destination listing is still blocked."
        )

        await client.releaseList(path: "/srv")
        await client.waitUntilDisconnectStarted()
        await client.releaseDisconnect()
        await disconnectWaitTask.value

        #expect(await waitProbe.didReturn)
        #expect(results.isEmpty)
    }

    @Test
    func navigationRequestTracksInitialDirectoryLoadUntilSnapshotCompletes() async throws {
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/srv")
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [makeRemoteFileBrowserEntry(name: "app", path: "/srv/app", type: .directory)]
            ],
            blockedListPaths: ["/srv"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)

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
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id)
        let slowEntry = makeRemoteFileBrowserEntry(name: "slow", path: "/slow", type: .directory)
        let fileEntry = makeRemoteFileBrowserEntry(name: "current.txt", path: "/current.txt", type: .file)
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/slow": [makeRemoteFileBrowserEntry(name: "stale.txt", path: "/slow/stale.txt", type: .file)]
            ],
            blockedListPaths: ["/slow"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)

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
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id)
        let entry = makeRemoteFileBrowserEntry(name: "logs", path: "/logs", type: .directory)
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/logs": [makeRemoteFileBrowserEntry(name: "app.log", path: "/logs/app.log", type: .file)]
            ],
            blockedListPaths: ["/logs"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)

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
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id)
        let entry = makeRemoteFileBrowserEntry(name: "tmp", path: "/tmp", type: .directory)
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/tmp": [makeRemoteFileBrowserEntry(name: "file.txt", path: "/tmp/file.txt", type: .file)]
            ],
            blockedListPaths: ["/tmp"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)

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
    func disconnectWaitsForCanceledNavigationBeforeRemoteDisconnect() async throws {
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id)
        let entry = makeRemoteFileBrowserEntry(name: "tmp", path: "/tmp", type: .directory)
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/tmp": [makeRemoteFileBrowserEntry(name: "file.txt", path: "/tmp/file.txt", type: .file)]
            ],
            blockedListPaths: ["/tmp"],
            blocksDisconnect: true
        )
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(),
            remoteFileServiceAccess: NonSerializingRemoteFileServiceAccess(client: client),
            serverProvider: { _ in nil }
        )
        let waitProbe = RemoteFileWaitProbe()

        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }

        // Given a navigation request is blocked inside remote directory IO.
        let requestID = store.requestNavigation(.openDirectory(entry), in: tab, server: server)
        await client.waitUntilListStarted(path: "/tmp")

        // When the same server disconnects.
        let disconnectTask = store.disconnect(serverId: server.id)
        let disconnectWaitTask = Task {
            await disconnectTask.value
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then service disconnect waits for navigation cleanup to exit.
        #expect(!store.pendingNavigationRequestIDs.contains(requestID))
        #expect(
            await !client.hasStartedDisconnect(),
            "RemoteFiles disconnect should wait for canceled navigation listing to exit before disconnecting the SFTP service."
        )
        #expect(
            await !waitProbe.didReturn,
            "RemoteFiles disconnect task should not complete while canceled navigation listing is still blocked."
        )

        await client.releaseList(path: "/tmp")
        await client.waitUntilDisconnectStarted()
        await client.releaseDisconnect()
        await disconnectWaitTask.value

        #expect(await waitProbe.didReturn)
        #expect(store.currentPathValue(for: tab) == nil)
    }

    @Test
    func disconnectCancelsQueuedNavigationBeforeRuntimeStateExists() async throws {
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/srv")
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/srv": [makeRemoteFileBrowserEntry(name: "app", path: "/srv/app", type: .directory)]
            ]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)

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
        let server = makeRemoteFileBrowserServer()
        let wrongServer = Server(
            id: UUID(),
            workspaceId: server.workspaceId,
            name: "Stale",
            host: "stale.example.com",
            username: "root"
        )
        let tab = RemoteFileTab(serverId: server.id)
        let entry = makeRemoteFileBrowserEntry(name: "logs", path: "/logs", type: .directory)
        let client = await BlockingNavigationRemoteFileClient(
            listResponses: [
                "/logs": [makeRemoteFileBrowserEntry(name: "app.log", path: "/logs/app.log", type: .file)]
            ],
            blockedListPaths: ["/logs"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)

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
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id)
        let symlink = makeRemoteFileBrowserEntry(name: "latest.log", path: "/latest.log", type: .symlink)
        let resolved = makeRemoteFileBrowserEntry(name: "latest.log", path: "/latest.log", type: .file)
        let client = await BlockingNavigationRemoteFileClient(stats: ["/latest.log": resolved])
        let store = makeRemoteFileBrowserStore(server: server, client: client)
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
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id)
        let symlink = makeRemoteFileBrowserEntry(name: "latest.log", path: "/latest.log", type: .symlink)
        let staleResolvedFile = makeRemoteFileBrowserEntry(name: "latest.log", path: "/latest.log", type: .file)
        let currentFile = makeRemoteFileBrowserEntry(name: "current.log", path: "/current.log", type: .file)
        let client = await BlockingNavigationRemoteFileClient(
            stats: ["/latest.log": staleResolvedFile],
            blockedStatPaths: ["/latest.log"]
        )
        let store = makeRemoteFileBrowserStore(server: server, client: client)

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
}
