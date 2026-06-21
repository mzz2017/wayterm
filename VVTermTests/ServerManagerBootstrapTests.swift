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
// ordering, server deletion teardown ownership, or user-initiated server,
// workspace, and environment save/delete intent tracking changes intentionally.
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
        let wasPro = StoreManager.shared.isPro
        StoreManager.shared.isPro = false
        defer { StoreManager.shared.isPro = wasPro }

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
            workspaces: [workspace]
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
    func workspaceSaveIntentTracksUpdateAndRunsSuccessAfterApplicationSave() async throws {
        // Given a workspace edit launched from a synchronous UI intent.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let manager = ServerManager.makeForTesting(workspaces: [workspace])
        let editedWorkspace = Workspace(
            id: workspace.id,
            name: "Main Updated",
            colorHex: "#00AAFF",
            order: workspace.order,
            environments: workspace.environments,
            lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
            lastSelectedServerId: workspace.lastSelectedServerId,
            createdAt: workspace.createdAt
        )
        var savedWorkspace: Workspace?

        // When UI sends save intent without directly owning the async update
        // task.
        let requestID = manager.requestWorkspaceSave(editedWorkspace, mode: .update) { workspace in
            savedWorkspace = workspace
        }

        // Then the application layer tracks the request and calls success only
        // after the workspace metadata has been updated.
        #expect(manager.pendingWorkspaceSaveRequestIDs.contains(requestID))
        await manager.waitForWorkspaceSaveRequest(requestID)
        #expect(!manager.pendingWorkspaceSaveRequestIDs.contains(requestID))
        #expect(savedWorkspace?.id == workspace.id)
        #expect(savedWorkspace?.name == "Main Updated")
        #expect(manager.workspaces.first?.name == "Main Updated")
        #expect(manager.workspaceSaveFailure == nil)
    }

    @Test
    func workspaceSaveIntentTracksProFailureWithoutCallingSuccess() async throws {
        // Given free-tier state already has the maximum workspace count.
        let existingWorkspace = Workspace(id: UUID(), name: "Existing", order: 0)
        let manager = ServerManager.makeForTesting(workspaces: [existingWorkspace])
        let newWorkspace = Workspace(id: UUID(), name: "New Workspace", order: 1)
        var savedWorkspace: Workspace?
        var didShowProUpgrade = false
        var failureMessage: String?

        // When UI sends create intent that hits the Pro limit.
        let requestID = manager.requestWorkspaceSave(
            newWorkspace,
            mode: .create,
            onSaved: { workspace in
                savedWorkspace = workspace
            },
            onProRequired: {
                didShowProUpgrade = true
            },
            onFailed: { message in
                failureMessage = message
            }
        )

        // Then the manager captures the failure, keeps workspace metadata
        // unchanged, and lets the UI show the existing upgrade path without
        // pretending save succeeded.
        #expect(manager.pendingWorkspaceSaveRequestIDs.contains(requestID))
        await manager.waitForWorkspaceSaveRequest(requestID)
        #expect(!manager.pendingWorkspaceSaveRequestIDs.contains(requestID))
        #expect(savedWorkspace == nil)
        #expect(didShowProUpgrade)
        #expect(failureMessage == nil)
        #expect(manager.workspaces.map(\.id) == [existingWorkspace.id])
        #expect(manager.workspaceSaveFailure?.operation == .createWorkspace(newWorkspace.id))
        #expect(
            manager.workspaceSaveFailure?.message.contains("Upgrade") == true,
            "Workspace save Pro failure should preserve the user-visible upgrade message."
        )
    }

    @Test
    func environmentSaveIntentTracksUpdateAndRunsSuccessAfterApplicationSave() async throws {
        // Given an environment edit launched from synchronous UI intent with a
        // server assigned to that environment.
        let environment = ServerEnvironment(
            id: UUID(),
            name: "QA",
            shortName: "QA",
            colorHex: "#FF00FF"
        )
        let workspace = Workspace(
            id: UUID(),
            name: "Main",
            order: 0,
            environments: ServerEnvironment.builtInEnvironments + [environment]
        )
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            environment: environment,
            name: "Tencent",
            host: "environment-save.example.com",
            username: "root"
        )
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace]
        )
        let editedEnvironment = ServerEnvironment(
            id: environment.id,
            name: "Quality",
            shortName: "Qual",
            colorHex: "#00AAFF"
        )
        var savedWorkspace: Workspace?
        var savedEnvironment: ServerEnvironment?

        // When UI sends update intent without directly owning the async
        // workspace/environment save task.
        let requestID = manager.requestEnvironmentSave(
            editedEnvironment,
            in: workspace,
            mode: .update
        ) { workspace, environment in
            savedWorkspace = workspace
            savedEnvironment = environment
        }

        // Then the application layer tracks the request and calls success only
        // after workspace metadata and assigned servers use the edited
        // environment.
        #expect(manager.pendingEnvironmentSaveRequestIDs.contains(requestID))
        await manager.waitForEnvironmentSaveRequest(requestID)
        #expect(!manager.pendingEnvironmentSaveRequestIDs.contains(requestID))
        #expect(savedWorkspace?.environment(withId: environment.id)?.name == "Quality")
        #expect(savedEnvironment?.name == "Quality")
        #expect(manager.workspaces.first?.environment(withId: environment.id)?.name == "Quality")
        #expect(
            manager.servers.first?.environment.name == "Quality",
            "Environment update intent must update servers assigned to that environment before success."
        )
        #expect(manager.environmentSaveFailure == nil)
    }

    @Test
    func environmentSaveIntentTracksCreateAndReturnsPersistedWorkspace() async throws {
        // Given an environment create launched from synchronous UI intent.
        let wasPro = StoreManager.shared.isPro
        StoreManager.shared.isPro = true
        defer { StoreManager.shared.isPro = wasPro }

        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let manager = ServerManager.makeForTesting(workspaces: [workspace])
        let newEnvironment = ServerEnvironment(
            id: UUID(),
            name: "QA",
            shortName: "QA",
            colorHex: "#FF00FF"
        )
        var savedWorkspace: Workspace?
        var savedEnvironment: ServerEnvironment?

        // When UI sends create intent.
        let requestID = manager.requestEnvironmentSave(
            newEnvironment,
            in: workspace,
            mode: .create
        ) { workspace, environment in
            savedWorkspace = workspace
            savedEnvironment = environment
        }

        // Then the callback receives the workspace state after the manager's
        // persistence boundary, not the stale pre-save workspace passed by UI.
        #expect(manager.pendingEnvironmentSaveRequestIDs.contains(requestID))
        await manager.waitForEnvironmentSaveRequest(requestID)
        #expect(!manager.pendingEnvironmentSaveRequestIDs.contains(requestID))
        #expect(savedEnvironment?.id == newEnvironment.id)
        #expect(savedWorkspace?.environment(withId: newEnvironment.id)?.name == "QA")
        #expect(manager.workspaces.first?.environment(withId: newEnvironment.id)?.name == "QA")
        #expect(manager.environmentSaveFailure == nil)
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

    @Test
    func environmentDeletionIntentTracksRequestAndRunsSuccessAfterApplicationDelete() async throws {
        // Given an environment deletion launched from a synchronous UI intent.
        let environment = ServerEnvironment(
            id: UUID(),
            name: "QA",
            shortName: "QA",
            colorHex: "#FF00FF"
        )
        let workspace = Workspace(
            id: UUID(),
            name: "Main",
            order: 0,
            environments: ServerEnvironment.builtInEnvironments + [environment],
            lastSelectedEnvironmentId: environment.id
        )
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            environment: environment,
            name: "Tencent",
            host: "environment-intent.example.com",
            username: "root"
        )
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace]
        )
        var selectedWorkspace = workspace
        var selectedEnvironment = environment

        // When the UI sends deletion intent without starting its own Task.
        let requestID = manager.requestEnvironmentDeletion(
            environment,
            in: workspace,
            fallback: .production
        ) { updatedWorkspace in
            selectedWorkspace = updatedWorkspace
            if selectedEnvironment.id == environment.id {
                selectedEnvironment = .production
            }
        }
        await manager.waitForDeletionRequest(requestID)

        // Then the tracked request completes through ServerManager, and UI
        // selection updates run only after the application delete succeeds.
        #expect(!manager.pendingDeletionRequestIDs.contains(requestID))
        #expect(selectedWorkspace.environments.allSatisfy { $0.id != environment.id })
        #expect(selectedWorkspace.lastSelectedEnvironmentId == ServerEnvironment.production.id)
        #expect(selectedEnvironment == .production)
        #expect(
            manager.servers.first?.environment == .production,
            "Servers assigned to the deleted environment should move to the fallback environment."
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
