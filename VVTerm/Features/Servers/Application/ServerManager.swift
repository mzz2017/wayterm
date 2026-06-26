import Foundation
import CloudKit
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

    static let shared = ServerManager()

    @Published var servers: [Server] = []
    @Published var workspaces: [Workspace] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var deletionFailure: ServerDeletionFailure?
    @Published var workspaceSaveFailure: ServerWorkspaceSaveFailure?
    @Published var environmentSaveFailure: ServerEnvironmentSaveFailure?
    @Published var serverSaveFailure: ServerSaveFailure?
    @Published var serverMoveFailure: ServerMoveFailure?

    let cloudKit = CloudKitManager.shared
    let syncCoordinator = CloudKitSyncCoordinator.shared
    private let deletionTeardown: ServerDeletionTeardown
    private let deleteCredentials: ServerCredentialDeletion
    private let storeCredentials: ServerCredentialStore
    let startupLoadAction: ServerStartupLoadAction
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

    struct KnownHostRemovalCandidate: Equatable, Sendable {
        let host: String
        let port: Int
    }

    private init(
        loadLocalDataOnInit: Bool = true,
        startStartupLoad: Bool = true,
        deletionTeardown: @escaping ServerDeletionTeardown = ServerManager.defaultDeletionTeardown,
        deleteCredentials: @escaping ServerCredentialDeletion = ServerManager.defaultCredentialDeletion,
        storeCredentials: @escaping ServerCredentialStore = ServerManager.defaultCredentialStore,
        startupLoadAction: ServerStartupLoadAction? = nil,
        persistsLocalData: Bool = true,
        recordsSyncMutations: Bool = true
    ) {
        self.deletionTeardown = deletionTeardown
        self.deleteCredentials = deleteCredentials
        self.storeCredentials = storeCredentials
        self.startupLoadAction = startupLoadAction ?? { manager in
            await manager.loadData()
        }
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
        startupLoadAction: ServerStartupLoadAction? = nil
    ) -> ServerManager {
        let manager = ServerManager(
            loadLocalDataOnInit: false,
            startStartupLoad: startStartupLoad,
            deletionTeardown: deletionTeardown,
            deleteCredentials: deleteCredentials,
            storeCredentials: storeCredentials,
            startupLoadAction: startupLoadAction,
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


    func deleteServer(_ server: Server) async throws {
        await deletionTeardown(server)
        try await deleteCredentials(server.id)

        servers.removeAll { $0.id == server.id }
        let candidates = Self.knownHostRemovalCandidates(
            removedServers: [server],
            remainingServers: servers
        )
        await removeKnownHosts(for: candidates)
        enqueuePendingServerDelete(server)
        await persistLocalMutations(logMessage: "Deleted server: \(server.name)")
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


    func deleteWorkspace(_ workspace: Workspace) async throws {
        // Delete all servers in workspace
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }
        for server in workspaceServers {
            try await deleteServer(server)
        }

        if pendingBootstrapWorkspaceID == workspace.id {
            pendingBootstrapWorkspaceID = nil
        }
        workspaces.removeAll { $0.id == workspace.id }
        enqueuePendingWorkspaceDelete(workspace)
        await persistLocalMutations(logMessage: "Deleted workspace: \(workspace.name)")
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

    // MARK: - Queries

    func servers(in workspace: Workspace, environment: ServerEnvironment?) -> [Server] {
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }

        guard let environment = environment else {
            return workspaceServers
        }

        return workspaceServers.filter { $0.environment.id == environment.id }
    }

    func recentServers(limit: Int = 5) -> [Server] {
        servers
            .filter { $0.lastConnected != nil }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func favoriteServers() -> [Server] {
        servers.filter { $0.isFavorite }
    }

    func searchServers(_ query: String) -> [Server] {
        guard !query.isEmpty else { return servers }
        let lowercased = query.lowercased()
        return servers.filter {
            $0.name.lowercased().contains(lowercased) ||
            $0.host.lowercased().contains(lowercased) ||
            $0.username.lowercased().contains(lowercased) ||
            $0.tags.contains { $0.lowercased().contains(lowercased) }
        }
    }

    func workspace(withId id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func assignmentWorkspaces(for server: Server?) -> [Workspace] {
        let workspacesSortedByOrder = ServerAccessPolicy.workspacesSortedByOrder(workspaces)

        if StoreManager.shared.isPro {
            return workspacesSortedByOrder
        }

        guard let server,
              let currentWorkspace = workspace(withId: server.workspaceId) else {
            return workspacesSortedByOrder.filter { unlockedWorkspaceIds.contains($0.id) }
        }

        let allowedDestinationIDs = moveDestinationIDs(for: server)
        return workspacesSortedByOrder.filter {
            $0.id == currentWorkspace.id || allowedDestinationIDs.contains($0.id)
        }
    }

    func moveDestinations(for server: Server) -> [Workspace] {
        let destinationIDs = moveDestinationIDs(for: server)
        return ServerAccessPolicy.workspacesSortedByOrder(workspaces).filter { destinationIDs.contains($0.id) }
    }

    func resolvedEnvironment(
        for server: Server,
        destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil
    ) -> ServerEnvironment {
        ServerMoveSupport.resolveEnvironment(
            currentEnvironment: server.environment,
            preferredEnvironment: preferredEnvironment,
            destination: destination
        )
    }

    func moveRequiresEnvironmentFallback(_ server: Server, destination: Workspace) -> Bool {
        ServerMoveSupport.requiresEnvironmentFallback(
            currentEnvironment: server.environment,
            destination: destination
        )
    }

    func canAssignServer(_ server: Server, to destination: Workspace) -> Bool {
        if server.workspaceId == destination.id {
            return true
        }
        return moveDestinationIDs(for: server).contains(destination.id)
    }


    func moveServer(
        _ server: Server,
        to destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil
    ) async throws -> Server {
        guard let refreshedDestination = workspace(withId: destination.id) else {
            throw VVTermError.moveNotAllowed(String(localized: "The destination workspace is no longer available."))
        }

        if let restriction = moveRestriction(for: server, destination: refreshedDestination) {
            throw restriction
        }

        let sourceWorkspace = workspace(withId: server.workspaceId)
        let resolvedEnvironment = resolvedEnvironment(
            for: server,
            destination: refreshedDestination,
            preferredEnvironment: preferredEnvironment
        )

        var updatedServer = server
        updatedServer.workspaceId = refreshedDestination.id
        updatedServer.environment = resolvedEnvironment

        try await updateServer(updatedServer)
        try await updateWorkspaceSelectionMetadataAfterMove(
            serverId: server.id,
            from: sourceWorkspace,
            to: refreshedDestination
        )

        return updatedServer
    }

    // MARK: - Pro Limits

    var canAddServer: Bool {
        ServerAccessPolicy.canAddServer(isPro: StoreManager.shared.isPro, servers: servers)
    }

    var canAddWorkspace: Bool {
        ServerAccessPolicy.canAddWorkspace(isPro: StoreManager.shared.isPro, workspaces: workspaces)
    }

    var canCreateCustomEnvironment: Bool {
        ServerAccessPolicy.canCreateCustomEnvironment(isPro: StoreManager.shared.isPro)
    }

    // MARK: - Downgrade Locking
    // When user downgrades from Pro, excess servers/workspaces are locked

    /// Set of server IDs that are accessible on free tier (oldest N servers)
    var unlockedServerIds: Set<UUID> {
        ServerAccessPolicy.unlockedServerIds(isPro: StoreManager.shared.isPro, servers: servers)
    }

    /// Set of workspace IDs that are accessible on free tier (first N workspaces by order)
    var unlockedWorkspaceIds: Set<UUID> {
        ServerAccessPolicy.unlockedWorkspaceIds(isPro: StoreManager.shared.isPro, workspaces: workspaces)
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server) -> Bool {
        ServerAccessPolicy.isServerLocked(server, isPro: StoreManager.shared.isPro, servers: servers)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace) -> Bool {
        ServerAccessPolicy.isWorkspaceLocked(workspace, isPro: StoreManager.shared.isPro, workspaces: workspaces)
    }

    /// Number of servers that are locked due to downgrade
    var lockedServersCount: Int {
        ServerAccessPolicy.lockedServersCount(isPro: StoreManager.shared.isPro, servers: servers)
    }

    /// Number of workspaces that are locked due to downgrade
    var lockedWorkspacesCount: Int {
        ServerAccessPolicy.lockedWorkspacesCount(isPro: StoreManager.shared.isPro, workspaces: workspaces)
    }

    /// Whether user has any locked items after downgrade
    var hasLockedItems: Bool {
        ServerAccessPolicy.hasLockedItems(
            isPro: StoreManager.shared.isPro,
            servers: servers,
            workspaces: workspaces
        )
    }

    private func moveDestinationIDs(for server: Server) -> Set<UUID> {
        ServerAccessPolicy.moveDestinationIDs(
            isPro: StoreManager.shared.isPro,
            server: server,
            workspaces: workspaces
        )
    }

    private func moveRestriction(for server: Server, destination: Workspace) -> VVTermError? {
        guard server.workspaceId != destination.id else { return nil }

        if moveDestinationIDs(for: server).contains(destination.id) {
            return nil
        }

        if !StoreManager.shared.isPro && isWorkspaceLocked(destination) {
            return VVTermError.proRequired(String(localized: "Upgrade to Pro to move servers into locked workspaces"))
        }

        return VVTermError.moveNotAllowed(String(localized: "This server can't be moved to that workspace right now."))
    }

    private func updateWorkspaceSelectionMetadataAfterMove(
        serverId: UUID,
        from sourceWorkspace: Workspace?,
        to destinationWorkspace: Workspace
    ) async throws {
        if let sourceWorkspace,
           sourceWorkspace.id != destinationWorkspace.id,
           sourceWorkspace.lastSelectedServerId == serverId {
            var updatedSource = sourceWorkspace
            updatedSource.lastSelectedServerId = nil
            try await updateWorkspace(updatedSource)
        }

        if destinationWorkspace.lastSelectedServerId != serverId {
            var updatedDestination = destinationWorkspace
            updatedDestination.lastSelectedServerId = serverId
            try await updateWorkspace(updatedDestination)
        }
    }

    func createCustomEnvironment(name: String, color: String) throws -> ServerEnvironment {
        guard canCreateCustomEnvironment else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for custom environments"))
        }
        return ServerEnvironment(
            id: UUID(),
            name: name,
            shortName: String(name.prefix(4)),
            colorHex: color,
            isBuiltIn: false
        )
    }


    func updateEnvironment(_ environment: ServerEnvironment, in workspace: Workspace) async throws -> Workspace {
        var updatedWorkspace = workspace
        if let envIndex = updatedWorkspace.environments.firstIndex(where: { $0.id == environment.id }) {
            updatedWorkspace.environments[envIndex] = environment
        } else {
            return updatedWorkspace
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = environment
            try await updateServer(updatedServer)
        }

        return updatedWorkspace
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace
    ) async throws -> Workspace {
        try await deleteEnvironment(environment, in: workspace, fallback: .production)
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace,
        fallback: ServerEnvironment
    ) async throws -> Workspace {
        var updatedWorkspace = workspace
        updatedWorkspace.environments.removeAll { $0.id == environment.id }
        if updatedWorkspace.lastSelectedEnvironmentId == environment.id {
            updatedWorkspace.lastSelectedEnvironmentId = fallback.id
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = fallback
            try await updateServer(updatedServer)
        }

        return updatedWorkspace
    }

    func handleAppLanguageChange() {
        guard refreshPendingBootstrapWorkspaceLocalizationIfNeeded() else { return }
        saveLocalData()
    }
}
