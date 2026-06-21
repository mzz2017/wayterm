import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect ServerManager's local bootstrap, backfill, orphan repair,
// credential-save consistency, and deletion-side cleanup rules without CloudKit
// or Keychain I/O. They use value-only Server/Workspace fixtures and injected
// lifecycle closures so failures identify changes to local state invariants
// rather than sync transport behavior. Update this context only when
// bootstrap/backfill policy, known-host cleanup ownership, credential-save
// ordering, server deletion teardown ownership, or user-initiated deletion
// intent tracking changes intentionally.
@Suite(.serialized)
@MainActor
struct ServerManagerBootstrapTests {
    @Test
    func bootstrapCreationRunsOnlyBeforeAnyFirstRunMarkerExists() {
        #expect(
            ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: false,
                hasLocalWorkspaces: false
            )
        )
    }

    @Test
    func bootstrapCreationIsBlockedByEitherBootstrapFlagOrWelcomeFlag() {
        #expect(
            !ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: true,
                hasSeenWelcome: false,
                hasLocalWorkspaces: false
            )
        )
        #expect(
            !ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: true,
                hasLocalWorkspaces: false
            )
        )
        #expect(
            !ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: false,
                hasLocalWorkspaces: true
            )
        )
    }

    @Test
    func backfillCandidatesIgnoreTransientBootstrapWorkspace() {
        let bootstrapWorkspace = Workspace(
            id: UUID(),
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.en.rawValue),
            order: 0
        )
        let remoteWorkspace = Workspace(id: UUID(), name: "Remote", order: 1)

        let bootstrapServer = Server(
            id: UUID(),
            workspaceId: bootstrapWorkspace.id,
            name: "Placeholder",
            host: "bootstrap.example.com",
            username: "root"
        )
        let remoteServer = Server(
            id: UUID(),
            workspaceId: remoteWorkspace.id,
            name: "Needs Upload",
            host: "remote.example.com",
            username: "root"
        )

        let candidates = ServerManager.backfillCandidates(
            localWorkspaces: [bootstrapWorkspace, remoteWorkspace],
            localServers: [bootstrapServer, remoteServer],
            cloudWorkspaceIDs: [remoteWorkspace.id],
            cloudServerIDs: [],
            transientBootstrapWorkspaceID: bootstrapWorkspace.id
        )

        #expect(candidates.workspaces.isEmpty)
        #expect(candidates.servers.map(\.id) == [remoteServer.id])
    }

    @Test
    func canonicalDefaultWorkspaceDetectionAcceptsLocalizedNames() {
        let localizedWorkspace = Workspace(
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.zhHans.rawValue),
            order: 0
        )

        #expect(ServerManager.isCanonicalDefaultWorkspaceCandidate(localizedWorkspace))
    }

    @Test
    func backfillCandidatesIncludeBootstrapWorkspaceAfterPromotion() {
        let bootstrapWorkspace = Workspace(
            id: UUID(),
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.en.rawValue),
            order: 0
        )

        let candidates = ServerManager.backfillCandidates(
            localWorkspaces: [bootstrapWorkspace],
            localServers: [],
            cloudWorkspaceIDs: [],
            cloudServerIDs: [],
            transientBootstrapWorkspaceID: nil
        )

        #expect(candidates.workspaces.map(\.id) == [bootstrapWorkspace.id])
        #expect(candidates.servers.isEmpty)
    }

    @Test
    func orphanRepairCreatesFallbackWorkspaceWhenServersExistWithoutAnyWorkspace() {
        let orphanedServer = Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "Lost Server",
            host: "lost.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "My Servers", order: 0)

        let repairWorkspace = ServerManager.workspaceForOrphanRepair(
            existingWorkspaces: [],
            servers: [orphanedServer],
            fallbackWorkspace: fallbackWorkspace
        )

        #expect(repairWorkspace?.id == fallbackWorkspace.id)
    }

    @Test
    func orphanRepairDoesNothingWhenAllServersAlreadyHaveValidWorkspaces() {
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let validServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Healthy",
            host: "healthy.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "Fallback", order: 1)

        let repairWorkspace = ServerManager.workspaceForOrphanRepair(
            existingWorkspaces: [workspace],
            servers: [validServer],
            fallbackWorkspace: fallbackWorkspace
        )

        #expect(repairWorkspace == nil)
    }

    @Test
    func knownHostRemovalCandidatesUsePostDeleteServerState() {
        // Given two deleted servers where only one host is still used by a
        // remaining server after deletion.
        let workspaceID = UUID()
        let deletedSharedHost = Server(
            id: UUID(),
            workspaceId: workspaceID,
            name: "Deleted Shared",
            host: "shared.example.com",
            username: "root"
        )
        let remainingSharedHost = Server(
            id: UUID(),
            workspaceId: workspaceID,
            name: "Remaining Shared",
            host: "shared.example.com",
            username: "root"
        )
        let deletedUniqueHost = Server(
            id: UUID(),
            workspaceId: workspaceID,
            name: "Deleted Unique",
            host: "unique.example.com",
            username: "root"
        )

        // When ServerManager computes known-host cleanup candidates using the
        // post-delete server collection.
        let candidates = ServerManager.knownHostRemovalCandidates(
            removedServers: [deletedSharedHost, deletedUniqueHost],
            remainingServers: [remainingSharedHost]
        )

        // Then only the unique deleted host is removed; the shared host must
        // stay trusted for the remaining server.
        #expect(
            candidates == [
                ServerManager.KnownHostRemovalCandidate(host: "unique.example.com", port: 22)
            ],
            "Known-host cleanup must preserve hosts still referenced by post-delete server state."
        )
    }

    @Test
    func deleteServerAwaitsTeardownBeforeCredentialAndMetadataRemoval() async throws {
        // Given a server manager with injected deletion dependencies that record
        // the order of lifecycle teardown and credential cleanup.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "delete-order.example.com",
            username: "root"
        )
        let probe = ServerDeletionOrderProbe()
        var manager: ServerManager!
        manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            deletionTeardown: { server in
                #expect(
                    manager.servers.contains { $0.id == server.id },
                    "Server metadata must still exist while deletion teardown runs."
                )
                await probe.record("teardown:\(server.id.uuidString)")
            },
            deleteCredentials: { serverId in
                await probe.record("credentials:\(serverId.uuidString)")
            }
        )

        // When the server is deleted.
        try await manager.deleteServer(server)

        // Then teardown completes before credentials are deleted, and metadata
        // is removed only after the teardown boundary has run.
        let events = await probe.events()
        #expect(
            events == [
                "teardown:\(server.id.uuidString)",
                "credentials:\(server.id.uuidString)"
            ],
            "Server deletion must await runtime teardown before credential deletion."
        )
        #expect(
            !manager.servers.contains { $0.id == server.id },
            "Server metadata should be removed after deletion completes."
        )
    }

    @Test
    func updateServerWithCredentialsDoesNotMutateMetadataWhenCredentialStoreFails() async throws {
        // Given an existing server and an application-layer credential store
        // that fails before metadata should be changed.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "old.example.com",
            username: "root"
        )
        var storeAttempted = false
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            storeCredentials: { storedServer, credentials in
                storeAttempted = true
                #expect(storedServer.id == server.id)
                #expect(credentials.serverId == server.id)
                throw ServerCredentialStoreFailure()
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

        // When editing attempts to save credentials and metadata as one
        // application-layer operation.
        do {
            try await manager.updateServer(editedServer, credentials: credentials)
            Issue.record("Expected credential store failure")
        } catch {
            #expect(error is ServerCredentialStoreFailure)
        }

        // Then credential failure prevents metadata mutation, so UI cannot
        // leave an edited server pointing at stale or missing credentials.
        #expect(storeAttempted)
        #expect(manager.servers.map(\.id) == [server.id])
        #expect(manager.servers.first?.name == "Tencent")
        #expect(manager.servers.first?.host == "old.example.com")
    }

    @Test
    func deleteWorkspaceAwaitsEachServerTeardownBeforeWorkspaceRemoval() async throws {
        // Given a workspace with two servers and injected deletion dependencies.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let firstServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent 1",
            host: "workspace-delete-1.example.com",
            username: "root"
        )
        let secondServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent 2",
            host: "workspace-delete-2.example.com",
            username: "root"
        )
        let probe = ServerDeletionOrderProbe()
        var manager: ServerManager!
        manager = ServerManager.makeForTesting(
            servers: [firstServer, secondServer],
            workspaces: [workspace],
            deletionTeardown: { server in
                #expect(
                    manager.workspaces.contains { $0.id == workspace.id },
                    "Workspace metadata must remain until all server teardown has completed."
                )
                await probe.record("teardown:\(server.id.uuidString)")
            },
            deleteCredentials: { serverId in
                await probe.record("credentials:\(serverId.uuidString)")
            }
        )

        // When the workspace is deleted.
        try await manager.deleteWorkspace(workspace)

        // Then every contained server is torn down before its credentials are
        // deleted, and the workspace is removed only after server deletion ends.
        let events = await probe.events()
        #expect(
            events == [
                "teardown:\(firstServer.id.uuidString)",
                "credentials:\(firstServer.id.uuidString)",
                "teardown:\(secondServer.id.uuidString)",
                "credentials:\(secondServer.id.uuidString)"
            ],
            "Workspace deletion must reuse the awaitable server deletion path for each server."
        )
        #expect(
            !manager.workspaces.contains { $0.id == workspace.id },
            "Workspace metadata should be removed after contained server teardown completes."
        )
    }

    @Test
    func workspaceDeletionIntentTracksFailureInsteadOfDroppingResult() async throws {
        // Given a workspace deletion launched from a synchronous UI intent where
        // credential cleanup fails during the awaitable application delete path.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "workspace-intent-failure.example.com",
            username: "root"
        )
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            deleteCredentials: { _ in
                throw ServerDeletionIntentFailure()
            }
        )
        var successCalled = false

        // When the UI sends deletion intent without being able to await from
        // the button action itself.
        let requestID = manager.requestWorkspaceDeletion(workspace) {
            successCalled = true
        }

        // Then the application layer tracks the task, captures the failure, and
        // does not run the success continuation or remove metadata as if the
        // destructive action succeeded.
        #expect(manager.pendingDeletionRequestIDs.contains(requestID))
        await manager.waitForDeletionRequest(requestID)
        #expect(!manager.pendingDeletionRequestIDs.contains(requestID))
        #expect(!successCalled)
        #expect(manager.deletionFailure?.operation == .deleteWorkspace(workspace.id))
        #expect(
            manager.deletionFailure?.message.contains("ServerDeletionIntentFailure") == true,
            "Deletion intent failure should preserve the underlying error identity for diagnostics."
        )
        #expect(
            manager.workspaces.contains { $0.id == workspace.id },
            "Failed workspace deletion intent must not silently remove workspace metadata."
        )
    }
}

private struct ServerCredentialStoreFailure: Error {}
private struct ServerDeletionIntentFailure: Error {}

private actor ServerDeletionOrderProbe {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}
