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
// ordering, server deletion teardown ownership, or user-initiated workspace and
// environment save/delete intent tracking changes intentionally.
@Suite(.serialized)
@MainActor
struct ServerManagerBootstrapTests {
    @Test
    func startupLoadRequestTracksOperationUntilCompletion() async throws {
        let gate = ServerStartupLoadGate()
        let waitProbe = ServerStartupLoadWaitProbe()

        // Given app startup constructs ServerManager with a startup data load
        // that is blocked inside the application-layer load boundary.
        let manager = ServerManager.makeForTesting(
            startStartupLoad: true,
            startupLoadAction: { _ in
                await gate.markStarted()
                await gate.waitForRelease()
            }
        )

        await gate.waitForStart()
        let pendingIDs = manager.pendingStartupLoadRequestIDs
        #expect(
            pendingIDs.count == 1,
            "ServerManager startup load must expose one pending request while the fake load is blocked."
        )
        let requestID = try #require(pendingIDs.first)

        // When a caller waits for the startup load while it is still pending.
        let waitTask = Task {
            await manager.waitForStartupLoadRequest(requestID)
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then wait remains ordered behind the underlying load task instead of
        // returning just because init already finished.
        #expect(
            await !waitProbe.didReturn,
            "Startup load wait should not return before the fake load task exits."
        )

        await gate.release()
        await waitTask.value

        #expect(await waitProbe.didReturn)
        #expect(
            manager.pendingStartupLoadRequestIDs.isEmpty,
            "ServerManager should clear startup load request state after the tracked task exits."
        )
    }

    @Test
    func serverManagerInitDoesNotLaunchUntrackedLoadTask() throws {
        // Given the ServerManager application owner source.
        let root = try sourceRoot()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VVTerm/Features/Servers/Application/ServerManager.swift"
        ))

        // Then initialization should route startup loading through a named
        // manager-owned request path instead of an untracked loadData task.
        #expect(
            !source.contains("Task { await loadData() }"),
            "ServerManager init must not launch an untracked startup loadData task."
        )
        #expect(
            source.contains("startStartupLoad()"),
            "ServerManager init should use a named startup load owner method so request tracking stays auditable."
        )
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

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
    func canonicalDefaultWorkspaceDetectionAcceptsLocalizedNames() {
        let localizedWorkspace = Workspace(
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.zhHans.rawValue),
            order: 0
        )

        #expect(ServerManager.isCanonicalDefaultWorkspaceCandidate(localizedWorkspace))
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
        let managerHolder = ServerDeletionOrderManagerHolder()
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            deletionTeardown: { server in
                #expect(
                    managerHolder.manager?.servers.contains { $0.id == server.id } == true,
                    "Server metadata must still exist while deletion teardown runs."
                )
                await probe.record("teardown:\(server.id.uuidString)")
            },
            deleteCredentials: { serverId in
                await probe.record("credentials:\(serverId.uuidString)")
            }
        )
        managerHolder.manager = manager

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
        let managerHolder = ServerDeletionOrderManagerHolder()
        let manager = ServerManager.makeForTesting(
            servers: [firstServer, secondServer],
            workspaces: [workspace],
            deletionTeardown: { server in
                #expect(
                    managerHolder.manager?.workspaces.contains { $0.id == workspace.id } == true,
                    "Workspace metadata must remain until all server teardown has completed."
                )
                await probe.record("teardown:\(server.id.uuidString)")
            },
            deleteCredentials: { serverId in
                await probe.record("credentials:\(serverId.uuidString)")
            }
        )
        managerHolder.manager = manager

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
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let manager = ServerManager.makeForTesting(workspaces: [workspace], isProProvider: { true })
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

private enum SourceRootError: Error {
    case notFound
}

private actor ServerStartupLoadGate {
    private var didStart = false
    private var didRelease = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let continuations = startContinuations
        startContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !didRelease else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func release() {
        didRelease = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor ServerStartupLoadWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}

@MainActor
private final class ServerDeletionOrderManagerHolder: @unchecked Sendable {
    var manager: ServerManager?
}

private actor ServerDeletionOrderProbe {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}
