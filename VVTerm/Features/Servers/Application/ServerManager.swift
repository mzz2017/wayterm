import Foundation
import Combine
import SwiftUI
import os.log

struct ServerDeletionFailure: Identifiable, Equatable {
    enum Operation: Equatable {
        case deleteServer(UUID)
        case deleteWorkspace(UUID)
        case deleteEnvironment(workspaceID: UUID, environmentID: UUID)
    }

    let id: UUID
    let operation: Operation
    let message: String

    init(id: UUID = UUID(), operation: Operation, error: Error) {
        self.id = id
        self.operation = operation
        self.message = error.localizedDescription
    }
}

enum WorkspaceSaveMode: Equatable {
    case create
    case update
}

enum ServerEnvironmentSaveMode: Equatable {
    case create
    case update
}

enum ServerSaveMode: Equatable {
    case create
    case update
}

struct ServerWorkspaceSaveFailure: Identifiable, Equatable {
    enum Operation: Equatable {
        case createWorkspace(UUID)
        case updateWorkspace(UUID)
    }

    let id: UUID
    let operation: Operation
    let message: String

    init(id: UUID = UUID(), operation: Operation, error: Error) {
        self.id = id
        self.operation = operation
        self.message = error.localizedDescription
    }
}

struct ServerEnvironmentSaveFailure: Identifiable, Equatable {
    enum Operation: Equatable {
        case createEnvironment(workspaceID: UUID, environmentID: UUID)
        case updateEnvironment(workspaceID: UUID, environmentID: UUID)
    }

    let id: UUID
    let operation: Operation
    let message: String

    init(id: UUID = UUID(), operation: Operation, error: Error) {
        self.id = id
        self.operation = operation
        self.message = error.localizedDescription
    }
}

struct ServerSaveFailure: Identifiable, Equatable {
    enum Operation: Equatable {
        case createServer(UUID)
        case updateServer(UUID)
    }

    let id: UUID
    let operation: Operation
    let message: String

    init(id: UUID = UUID(), operation: Operation, error: Error) {
        self.id = id
        self.operation = operation
        self.message = error.localizedDescription
    }
}

struct ServerMoveFailure: Identifiable, Equatable {
    enum Operation: Equatable {
        case moveServer(UUID, UUID)
    }

    let id: UUID
    let operation: Operation
    let message: String

    init(id: UUID = UUID(), operation: Operation, error: Error) {
        self.id = id
        self.operation = operation
        self.message = error.localizedDescription
    }
}

@MainActor
final class ServerManager: ObservableObject {
    typealias ServerDeletionTeardown = @MainActor @Sendable (Server) async -> Void
    typealias ServerCredentialDeletion = @MainActor @Sendable (UUID) async throws -> Void
    typealias ServerCredentialStore = @MainActor @Sendable (Server, ServerCredentials) throws -> Void
    typealias ServerStartupLoadAction = @MainActor @Sendable (ServerManager) async -> Void
    typealias IsProProvider = @MainActor @Sendable () -> Bool
    typealias KnownHostRemovalCandidate = ServerKnownHostRemovalCandidate
    typealias ServerKnownHostRemoval = @MainActor @Sendable ([KnownHostRemovalCandidate]) async -> Void

    @Published var servers: [Server] = []
    @Published var workspaces: [Workspace] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var deletionFailure: ServerDeletionFailure?
    @Published var workspaceSaveFailure: ServerWorkspaceSaveFailure?
    @Published var environmentSaveFailure: ServerEnvironmentSaveFailure?
    @Published var serverSaveFailure: ServerSaveFailure?
    @Published var serverMoveFailure: ServerMoveFailure?

    let cloudKit: any ServerCloudSyncing
    let syncCoordinator: any ServerPendingCloudSyncCoordinating
    let localDataStore: any ServerLocalDataStoring
    private(set) var deletionTeardown: ServerDeletionTeardown
    let deleteCredentials: ServerCredentialDeletion
    private let storeCredentials: ServerCredentialStore
    let removeKnownHostEntries: ServerKnownHostRemoval
    let startupLoadAction: ServerStartupLoadAction
    let isProProvider: IsProProvider
    let syncStateService: ServerSyncStateService
    let persistsLocalData: Bool
    let recordsSyncMutations: Bool
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ServerManager")
    var isSyncEnabled: Bool { SyncSettings.isEnabled }
    var startupLoadRequestID: UUID?
    var startupLoadTask: Task<Void, Never>?
    var deletionRequests: [UUID: Task<Void, Never>] = [:]
    var workspaceSaveRequests: [UUID: Task<Void, Never>] = [:]
    var environmentSaveRequests: [UUID: Task<Void, Never>] = [:]
    var serverSaveRequests: [UUID: Task<Void, Never>] = [:]
    var serverMoveRequests: [UUID: Task<Void, Never>] = [:]
    var pendingStartupLoadRequestIDs: Set<UUID> {
        guard let startupLoadRequestID else { return [] }
        return [startupLoadRequestID]
    }
    var pendingDeletionRequestIDs: Set<UUID> { Set(deletionRequests.keys) }
    var pendingWorkspaceSaveRequestIDs: Set<UUID> { Set(workspaceSaveRequests.keys) }
    var pendingEnvironmentSaveRequestIDs: Set<UUID> { Set(environmentSaveRequests.keys) }
    var pendingServerSaveRequestIDs: Set<UUID> { Set(serverSaveRequests.keys) }
    var pendingServerMoveRequestIDs: Set<UUID> { Set(serverMoveRequests.keys) }

    init(
        cloudKit: any ServerCloudSyncing,
        syncCoordinator: any ServerPendingCloudSyncCoordinating,
        localDataStore: any ServerLocalDataStoring,
        loadLocalDataOnInit: Bool = true,
        startStartupLoad: Bool = true,
        deletionTeardown: @escaping ServerDeletionTeardown = ServerManager.defaultDeletionTeardown,
        deleteCredentials: @escaping ServerCredentialDeletion = ServerManager.defaultCredentialDeletion,
        storeCredentials: @escaping ServerCredentialStore = ServerManager.defaultCredentialStore,
        removeKnownHostEntries: @escaping ServerKnownHostRemoval = ServerManager.defaultKnownHostRemoval,
        startupLoadAction: ServerStartupLoadAction? = nil,
        isProProvider: @escaping IsProProvider,
        syncStateService: ServerSyncStateService = ServerSyncStateService(),
        persistsLocalData: Bool = true,
        recordsSyncMutations: Bool = true
    ) {
        self.cloudKit = cloudKit
        self.syncCoordinator = syncCoordinator
        self.localDataStore = localDataStore
        self.deletionTeardown = deletionTeardown
        self.deleteCredentials = deleteCredentials
        self.storeCredentials = storeCredentials
        self.removeKnownHostEntries = removeKnownHostEntries
        self.startupLoadAction = startupLoadAction ?? { manager in
            await manager.loadData()
        }
        self.isProProvider = isProProvider
        self.syncStateService = syncStateService
        self.persistsLocalData = persistsLocalData
        self.recordsSyncMutations = recordsSyncMutations

        if loadLocalDataOnInit {
            loadLocalData()
        }
        if startStartupLoad {
            self.startStartupLoad()
        }
    }

    #if DEBUG
    static func makeForTesting(
        servers: [Server] = [],
        workspaces: [Workspace] = [],
        startStartupLoad: Bool = false,
        deletionTeardown: @escaping ServerDeletionTeardown = { _ in },
        deleteCredentials: @escaping ServerCredentialDeletion = { _ in },
        storeCredentials: @escaping ServerCredentialStore = { _, _ in },
        removeKnownHostEntries: @escaping ServerKnownHostRemoval = { _ in },
        startupLoadAction: ServerStartupLoadAction? = nil,
        isProProvider: @escaping IsProProvider = { false },
        cloudKit: (any ServerCloudSyncing)? = nil,
        syncCoordinator: (any ServerPendingCloudSyncCoordinating)? = nil,
        localDataStore: (any ServerLocalDataStoring)? = nil
    ) -> ServerManager {
        let manager = ServerManager(
            cloudKit: cloudKit ?? DisabledServerCloudSyncService(),
            syncCoordinator: syncCoordinator ?? NoopServerPendingCloudSyncCoordinator(),
            localDataStore: localDataStore ?? InMemoryServerLocalDataStore(),
            loadLocalDataOnInit: false,
            startStartupLoad: startStartupLoad,
            deletionTeardown: deletionTeardown,
            deleteCredentials: deleteCredentials,
            storeCredentials: storeCredentials,
            removeKnownHostEntries: removeKnownHostEntries,
            startupLoadAction: startupLoadAction,
            isProProvider: isProProvider,
            persistsLocalData: false,
            recordsSyncMutations: false
        )
        manager.servers = servers
        manager.workspaces = workspaces
        return manager
    }
    #endif

    func seedReviewDataIfNeeded() {
        guard servers.isEmpty else { return }

        let workspace: Workspace
        if let firstWorkspace = workspaces.first {
            workspace = firstWorkspace
        } else {
            workspace = Workspace(name: "Review Workspace", colorHex: "#FF9500", order: 0)
            workspaces = [workspace]
        }

        let now = Date()
        servers = [
            Server(
                workspaceId: workspace.id,
                environment: .production,
                name: "Demo - Production",
                host: "example.com",
                username: "demo",
                tags: ["demo", "review"],
                notes: "Demo server for App Review. Replace with your test server if needed.",
                lastConnected: now,
                isFavorite: true
            ),
            Server(
                workspaceId: workspace.id,
                environment: .staging,
                name: "Demo - Staging",
                host: "staging.example.com",
                username: "demo",
                tags: ["demo"],
                notes: "Sample staging entry for App Review."
            ),
            Server(
                workspaceId: workspace.id,
                environment: .development,
                name: "Demo - Development",
                host: "dev.example.com",
                username: "demo",
                tags: ["demo"],
                notes: "Sample development entry for App Review."
            )
        ]

        saveLocalData()
        logger.info("Seeded App Review demo data (\(self.servers.count) servers)")
    }

    func configureDeletionTeardown(_ deletionTeardown: @escaping ServerDeletionTeardown) {
        self.deletionTeardown = deletionTeardown
    }

    // MARK: - Server CRUD

    func addServer(_ server: Server, credentials: ServerCredentials) async throws {
        guard canAddServer else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for unlimited servers"))
        }

        var newServer = server
        newServer = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            cloudflareAccessMode: server.cloudflareAccessMode,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            tags: server.tags,
            notes: server.notes,
            requiresBiometricUnlock: server.requiresBiometricUnlock,
            multiplexerOverride: server.multiplexerOverride,
            tmuxStartupBehaviorOverride: server.tmuxStartupBehaviorOverride,
            createdAt: Date(),
            updatedAt: Date()
        )

        try storeCredentials(newServer, credentials)

        promotePendingBootstrapWorkspaceIfNeeded(for: newServer.workspaceId, reason: "adding a server")
        servers.append(newServer)
        enqueuePendingServerUpsert(newServer)
        await persistLocalMutations(logMessage: "Added server: \(newServer.name)")
    }

    func updateServer(_ server: Server) async throws {
        var updatedServer = server
        updatedServer = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            cloudflareAccessMode: server.cloudflareAccessMode,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            tags: server.tags,
            notes: server.notes,
            lastConnected: server.lastConnected,
            isFavorite: server.isFavorite,
            requiresBiometricUnlock: server.requiresBiometricUnlock,
            multiplexerOverride: server.multiplexerOverride,
            tmuxStartupBehaviorOverride: server.tmuxStartupBehaviorOverride,
            createdAt: server.createdAt,
            updatedAt: Date()
        )

        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = updatedServer
        }
        enqueuePendingServerUpsert(updatedServer)
        await persistLocalMutations(logMessage: "Updated server: \(updatedServer.name)")
    }

    func updateServer(_ server: Server, credentials: ServerCredentials) async throws {
        try storeCredentials(server, credentials)
        try await updateServer(server)
    }

    func updateLastConnected(for server: Server) async {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].lastConnected = Date()
        saveLocalData()
    }

    // MARK: - Workspace CRUD

    func addWorkspace(_ workspace: Workspace) async throws {
        guard canAddWorkspace else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for unlimited workspaces"))
        }

        var newWorkspace = workspace
        newWorkspace = Workspace(
            id: workspace.id,
            name: workspace.name,
            colorHex: workspace.colorHex,
            icon: workspace.icon,
            order: workspaces.count,
            createdAt: Date(),
            updatedAt: Date()
        )

        pendingBootstrapWorkspaceID = nil
        workspaces.append(newWorkspace)
        enqueuePendingWorkspaceUpsert(newWorkspace)
        await persistLocalMutations(logMessage: "Added workspace: \(newWorkspace.name)")
    }

    func updateWorkspace(_ workspace: Workspace) async throws {
        var updatedWorkspace = workspace
        updatedWorkspace = Workspace(
            id: workspace.id,
            name: workspace.name,
            colorHex: workspace.colorHex,
            icon: workspace.icon,
            order: workspace.order,
            environments: workspace.environments,
            lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
            lastSelectedServerId: workspace.lastSelectedServerId,
            createdAt: workspace.createdAt,
            updatedAt: Date()
        )

        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = updatedWorkspace
        }
        promotePendingBootstrapWorkspaceIfNeeded(for: updatedWorkspace.id, reason: "updating workspace metadata")
        enqueuePendingWorkspaceUpsert(updatedWorkspace)
        await persistLocalMutations(logMessage: "Updated workspace: \(updatedWorkspace.name)")
    }

    func reorderWorkspaces(from source: IndexSet, to destination: Int) async throws {
        workspaces.move(fromOffsets: source, toOffset: destination)
        pendingBootstrapWorkspaceID = nil

        // Update order for all workspaces
        for (index, workspace) in workspaces.enumerated() {
            var updated = workspace
            updated = Workspace(
                id: workspace.id,
                name: workspace.name,
                colorHex: workspace.colorHex,
                icon: workspace.icon,
                order: index,
                environments: workspace.environments,
                lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
                lastSelectedServerId: workspace.lastSelectedServerId,
                createdAt: workspace.createdAt,
                updatedAt: Date()
            )
            workspaces[index] = updated
            enqueuePendingWorkspaceUpsert(updated)
        }
        await persistLocalMutations(logMessage: "Reordered workspaces")
    }
}
