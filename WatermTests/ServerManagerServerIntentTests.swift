import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect ServerManager's server save and move intent ownership.
// Synchronous UI actions must send intent to ServerManager while the manager
// tracks async credential, Pro-limit, metadata, and move-selection work. Fakes
// use in-memory ServerManager instances and injected credential stores; update
// only when server save or move intent semantics intentionally change.
@Suite(.serialized)
@MainActor
struct ServerManagerServerIntentTests {
    @Test
    func serverSaveIntentTracksCreateAndReturnsPersistedServer() async throws {
        // Given a new server save launched from synchronous UI intent.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let submittedServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "new.example.com",
            username: "root",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let credentials = ServerCredentials(serverId: submittedServer.id, password: "secret")
        let manager = ServerManager.makeForTesting(workspaces: [workspace])
        var savedServer: Server?

        // When UI sends create intent without owning the async credential and
        // metadata save task.
        let requestID = manager.requestServerSave(
            submittedServer,
            credentials: credentials,
            mode: .create
        ) { server in
            savedServer = server
        }

        // Then the application layer tracks the request and the callback sees
        // the persisted server value after addServer applies timestamps and
        // local persistence behavior.
        #expect(manager.pendingServerSaveRequestIDs.contains(requestID))
        await manager.waitForServerSaveRequest(requestID)
        #expect(!manager.pendingServerSaveRequestIDs.contains(requestID))
        #expect(manager.servers.map(\.id) == [submittedServer.id])
        #expect(savedServer?.id == submittedServer.id)
        #expect(savedServer?.createdAt == manager.servers.first?.createdAt)
        #expect(savedServer?.createdAt != submittedServer.createdAt)
        #expect(manager.serverSaveFailure == nil)
    }

    @Test
    func serverSaveIntentTracksUpdateAndRunsSuccessAfterCredentialStore() async throws {
        // Given an existing server edit launched from synchronous UI intent.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "old.example.com",
            username: "root"
        )
        var storedCredentialServerID: UUID?
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            storeCredentials: { storedServer, credentials in
                storedCredentialServerID = storedServer.id
                #expect(credentials.serverId == storedServer.id)
            }
        )
        let editedServer = Server(
            id: server.id,
            workspaceId: workspace.id,
            name: "Tencent Updated",
            host: "new.example.com",
            username: "root",
            createdAt: server.createdAt
        )
        let credentials = ServerCredentials(serverId: server.id, password: "updated-password")
        var savedServer: Server?

        // When UI sends update intent.
        let requestID = manager.requestServerSave(
            editedServer,
            credentials: credentials,
            mode: .update
        ) { server in
            savedServer = server
        }

        // Then success runs only after the application-layer credential and
        // metadata save operation completes.
        #expect(manager.pendingServerSaveRequestIDs.contains(requestID))
        await manager.waitForServerSaveRequest(requestID)
        #expect(!manager.pendingServerSaveRequestIDs.contains(requestID))
        #expect(storedCredentialServerID == server.id)
        #expect(savedServer?.host == "new.example.com")
        #expect(manager.servers.first?.host == "new.example.com")
        #expect(manager.serverSaveFailure == nil)
    }

    @Test
    func serverSaveIntentTracksCredentialFailureWithoutMutatingMetadata() async throws {
        // Given a server edit whose credential store fails inside the
        // application-layer save boundary.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "old.example.com",
            username: "root"
        )
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            storeCredentials: { _, _ in
                throw ServerSaveCredentialStoreFailure()
            }
        )
        let editedServer = Server(
            id: server.id,
            workspaceId: workspace.id,
            name: "Tencent Updated",
            host: "new.example.com",
            username: "root",
            createdAt: server.createdAt
        )
        let credentials = ServerCredentials(serverId: server.id, password: "updated-password")
        var didSave = false
        var failureMessage: String?

        // When UI sends update intent.
        let requestID = manager.requestServerSave(
            editedServer,
            credentials: credentials,
            mode: .update,
            onSaved: { _ in didSave = true },
            onFailed: { message in failureMessage = message }
        )

        // Then the request captures failure, skips success, and preserves the
        // original metadata because credential storage failed first.
        #expect(manager.pendingServerSaveRequestIDs.contains(requestID))
        await manager.waitForServerSaveRequest(requestID)
        #expect(!manager.pendingServerSaveRequestIDs.contains(requestID))
        #expect(!didSave)
        #expect(failureMessage != nil)
        #expect(manager.serverSaveFailure?.operation == .updateServer(server.id))
        #expect(manager.servers.first?.host == "old.example.com")
    }

    @Test
    func serverSaveIntentTracksProFailureWithoutCallingSaveContinuations() async throws {
        // Given a free-tier server create request when the server limit is
        // already reached.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let existingServers = (0..<FreeTierLimits.maxServers).map { index in
            Server(
                id: UUID(),
                workspaceId: workspace.id,
                name: "Existing \(index)",
                host: "existing-\(index).example.com",
                username: "root"
            )
        }
        let submittedServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Overflow",
            host: "overflow.example.com",
            username: "root"
        )
        let manager = ServerManager.makeForTesting(
            servers: existingServers,
            workspaces: [workspace],
            isProProvider: { false }
        )
        let credentials = ServerCredentials(serverId: submittedServer.id, password: "secret")
        var didSave = false
        var didShowProRequired = false
        var failureMessage: String?

        // When UI sends create intent through the application-layer request
        // API.
        let requestID = manager.requestServerSave(
            submittedServer,
            credentials: credentials,
            mode: .create,
            onSaved: { _ in didSave = true },
            onProRequired: { didShowProRequired = true },
            onFailed: { message in failureMessage = message }
        )

        // Then Pro-limit failure stays distinguishable from ordinary save
        // failure, no success continuation runs, and no server metadata is
        // appended.
        #expect(manager.pendingServerSaveRequestIDs.contains(requestID))
        await manager.waitForServerSaveRequest(requestID)
        #expect(!manager.pendingServerSaveRequestIDs.contains(requestID))
        #expect(!didSave)
        #expect(didShowProRequired)
        #expect(failureMessage == nil)
        #expect(manager.serverSaveFailure?.operation == .createServer(submittedServer.id))
        #expect(manager.servers.map(\.id) == existingServers.map(\.id))
    }

    @Test
    func serverMoveIntentTracksSuccessAfterMetadataAndSelectionUpdates() async throws {
        // Given a user-initiated server move where the source workspace
        // currently selects the server and the destination has not selected it.
        let sourceWorkspace = Workspace(
            id: UUID(),
            name: "Source",
            order: 0,
            lastSelectedServerId: nil
        )
        let destinationWorkspace = Workspace(
            id: UUID(),
            name: "Destination",
            order: 1,
            lastSelectedServerId: nil
        )
        let server = Server(
            id: UUID(),
            workspaceId: sourceWorkspace.id,
            environment: .staging,
            name: "Tencent",
            host: "move-success.example.com",
            username: "root"
        )
        var selectedSource = sourceWorkspace
        selectedSource.lastSelectedServerId = server.id
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [selectedSource, destinationWorkspace],
            isProProvider: { true }
        )
        var movedServer: Server?

        // When UI sends move intent without owning the async move task.
        let requestID = manager.requestServerMove(
            server,
            to: destinationWorkspace,
            preferredEnvironment: .production
        ) { server in
            movedServer = server
        }

        // Then the manager tracks the request and calls success only after the
        // server metadata and workspace selection metadata are updated.
        #expect(manager.pendingServerMoveRequestIDs.contains(requestID))
        await manager.waitForServerMoveRequest(requestID)
        #expect(!manager.pendingServerMoveRequestIDs.contains(requestID))
        #expect(movedServer?.workspaceId == destinationWorkspace.id)
        #expect(movedServer?.environment == .production)
        #expect(manager.servers.first?.workspaceId == destinationWorkspace.id)
        #expect(manager.workspace(withId: sourceWorkspace.id)?.lastSelectedServerId == nil)
        #expect(manager.workspace(withId: destinationWorkspace.id)?.lastSelectedServerId == server.id)
        #expect(manager.serverMoveFailure == nil)
    }

    @Test
    func serverMoveIntentTracksProFailureWithoutCallingMoveContinuations() async throws {
        // Given a free-tier move request into a locked destination workspace.
        let sourceWorkspace = Workspace(id: UUID(), name: "Unlocked", order: 0)
        let lockedDestination = Workspace(id: UUID(), name: "Locked", order: 1)
        let server = Server(
            id: UUID(),
            workspaceId: sourceWorkspace.id,
            name: "Tencent",
            host: "move-pro.example.com",
            username: "root"
        )
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [sourceWorkspace, lockedDestination],
            isProProvider: { false }
        )
        var didMove = false
        var didShowProRequired = false
        var failureMessage: String?

        // When UI sends move intent through the application-layer request API.
        let requestID = manager.requestServerMove(
            server,
            to: lockedDestination,
            onMoved: { _ in didMove = true },
            onProRequired: { didShowProRequired = true },
            onFailed: { message in failureMessage = message }
        )

        // Then Pro-limit failure stays distinguishable from ordinary move
        // failure, no success continuation runs, and server metadata is not
        // moved as if the request had succeeded.
        #expect(manager.pendingServerMoveRequestIDs.contains(requestID))
        await manager.waitForServerMoveRequest(requestID)
        #expect(!manager.pendingServerMoveRequestIDs.contains(requestID))
        #expect(!didMove)
        #expect(didShowProRequired)
        #expect(failureMessage == nil)
        #expect(manager.serverMoveFailure?.operation == .moveServer(server.id, lockedDestination.id))
        #expect(manager.servers.first?.workspaceId == sourceWorkspace.id)
    }

    @Test
    func serverMoveIntentRoutesOrdinaryFailureToFailureContinuation() async throws {
        // Given a move request whose destination workspace has disappeared
        // before the application-layer move starts.
        let sourceWorkspace = Workspace(id: UUID(), name: "Source", order: 0)
        let missingDestination = Workspace(id: UUID(), name: "Missing", order: 1)
        let server = Server(
            id: UUID(),
            workspaceId: sourceWorkspace.id,
            name: "Tencent",
            host: "move-failure.example.com",
            username: "root"
        )
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [sourceWorkspace],
            isProProvider: { true }
        )
        var didMove = false
        var didShowProRequired = false
        var failureMessage: String?

        // When UI sends move intent for a destination that is no longer
        // available.
        let requestID = manager.requestServerMove(
            server,
            to: missingDestination,
            onMoved: { _ in didMove = true },
            onProRequired: { didShowProRequired = true },
            onFailed: { message in failureMessage = message }
        )

        // Then the ordinary failure routes to onFailed, does not show the Pro
        // upgrade path, skips success, and preserves server metadata.
        #expect(manager.pendingServerMoveRequestIDs.contains(requestID))
        await manager.waitForServerMoveRequest(requestID)
        #expect(!manager.pendingServerMoveRequestIDs.contains(requestID))
        #expect(!didMove)
        #expect(!didShowProRequired)
        #expect(failureMessage != nil)
        #expect(failureMessage?.isEmpty == false)
        #expect(manager.serverMoveFailure?.operation == .moveServer(server.id, missingDestination.id))
        #expect(manager.servers.first?.workspaceId == sourceWorkspace.id)
    }
}

private struct ServerSaveCredentialStoreFailure: Error {}
