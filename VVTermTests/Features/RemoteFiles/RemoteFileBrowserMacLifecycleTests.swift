import Foundation
import Testing
@testable import VVTerm

#if os(macOS)
// Test Context:
// These tests protect macOS RemoteFiles UI intent as a thin adapter over the
// application-owned transfer lifecycle. Fakes block source-server SFTP work
// deterministically; failures usually mean the AppKit table path can bypass
// source-server cancellation, awaitable teardown, or cross-server ownership
// binding. Update these tests only if macOS native table drops move to another
// owner with equivalent source and destination transfer scoping.
@MainActor
struct RemoteFileBrowserMacLifecycleTests {
    @Test
    func macOSNativeRemoteDropBindsSourceServerScopeForDisconnectCancellation() async throws {
        let sourceServer = makeRemoteFileBrowserServer()
        let destinationServer = makeRemoteFileBrowserServer()
        let sourceEntry = makeRemoteFileBrowserEntry(
            name: "linked-config",
            path: "/source/linked-config",
            type: .symlink
        )
        let payload = RemoteFileDragPayload(serverId: sourceServer.id, entry: sourceEntry)
        let sourceClient = await BlockingNavigationRemoteFileClient(
            blockedStatPaths: [sourceEntry.path]
        )
        let destinationClient = await BlockingNavigationRemoteFileClient()
        var clients = [sourceClient, destinationClient]
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(),
            remoteFileServiceAccess: SSHSFTPAdapter(
                credentialsProvider: { server in makeRemoteFileBrowserCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            ),
            serverProvider: { serverId in
                [sourceServer.id: sourceServer, destinationServer.id: destinationServer][serverId]
            }
        )
        let screen = RemoteFileBrowserScreen(
            browser: store,
            server: destinationServer,
            fileTab: RemoteFileTab(serverId: destinationServer.id, seedPath: "/destination")
        )

        // Given the macOS native table handler starts a cross-server remote
        // copy and source-server SFTP work is still in flight.
        screen.handleMacOSDroppedRemotePayload(payload, to: "/destination")
        await sourceClient.waitUntilStatStarted(path: sourceEntry.path)
        let requestID = try #require(
            store.pendingTransferRequestIDs.first,
            "macOS remote table drop should register an application-owned transfer request."
        )

        // When the source server disconnects while the copy still owns remote
        // work through the destination UI path.
        _ = store.disconnect(serverId: sourceServer.id)
        let waitProbe = RemoteFileWaitProbe()
        let waitTask = Task {
            await store.waitForTransferRequest(requestID)
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then source disconnect cancels visible transfer state immediately,
        // but teardown remains awaitable until the blocked source operation
        // exits.
        #expect(
            !store.pendingTransferRequestIDs.contains(requestID),
            "macOS native remote drops must bind the source server so disconnect cancels the transfer."
        )
        #expect(
            await !waitProbe.didReturn,
            "Transfer teardown should remain awaitable while source SFTP work is still exiting."
        )

        await sourceClient.releaseStat(path: sourceEntry.path)
        await waitTask.value

        #expect(await waitProbe.didReturn)
    }
}
#endif
