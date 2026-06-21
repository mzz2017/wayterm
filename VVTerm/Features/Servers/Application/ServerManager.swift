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

@MainActor
final class ServerManager: ObservableObject {
    typealias ServerDeletionTeardown = @MainActor @Sendable (Server) async -> Void
    typealias ServerCredentialDeletion = @MainActor @Sendable (UUID) async throws -> Void
    typealias ServerCredentialStore = @MainActor @Sendable (Server, ServerCredentials) throws -> Void

    static let shared = ServerManager()

    @Published var servers: [Server] = []
    @Published var workspaces: [Workspace] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var deletionFailure: ServerDeletionFailure?
    @Published private(set) var workspaceSaveFailure: ServerWorkspaceSaveFailure?
    @Published private(set) var environmentSaveFailure: ServerEnvironmentSaveFailure?

    private let cloudKit = CloudKitManager.shared
    private let syncCoordinator = CloudKitSyncCoordinator.shared
    private let deletionTeardown: ServerDeletionTeardown
    private let deleteCredentials: ServerCredentialDeletion
    private let storeCredentials: ServerCredentialStore
    private let persistsLocalData: Bool
    private let recordsSyncMutations: Bool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ServerManager")
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }
    private var deletionRequests: [UUID: Task<Void, Never>] = [:]
    private var workspaceSaveRequests: [UUID: Task<Void, Never>] = [:]
    private var environmentSaveRequests: [UUID: Task<Void, Never>] = [:]
    var pendingDeletionRequestIDs: Set<UUID> { Set(deletionRequests.keys) }
    var pendingWorkspaceSaveRequestIDs: Set<UUID> { Set(workspaceSaveRequests.keys) }
    var pendingEnvironmentSaveRequestIDs: Set<UUID> { Set(environmentSaveRequests.keys) }

    // Local storage keys
    private let serversKey = CloudKitSyncConstants.serverStorageKey
    private let workspacesKey = CloudKitSyncConstants.workspaceStorageKey
    private let didBootstrapDefaultWorkspaceKey = CloudKitSyncConstants.didBootstrapDefaultWorkspaceKey
    private let pendingBootstrapWorkspaceIDKey = CloudKitSyncConstants.pendingBootstrapWorkspaceIDKey
    private let hasSeenWelcomeKey = "hasSeenWelcome"

    private struct FullFetchBackfillResult {
        let changes: CloudKitChanges
        let canReplaceLocalState: Bool
    }

    struct KnownHostRemovalCandidate: Equatable, Sendable {
        let host: String
        let port: Int
    }

    private init(
        loadLocalDataOnInit: Bool = true,
        deletionTeardown: @escaping ServerDeletionTeardown = ServerManager.defaultDeletionTeardown,
        deleteCredentials: @escaping ServerCredentialDeletion = ServerManager.defaultCredentialDeletion,
        storeCredentials: @escaping ServerCredentialStore = ServerManager.defaultCredentialStore,
        persistsLocalData: Bool = true,
        recordsSyncMutations: Bool = true
    ) {
        self.deletionTeardown = deletionTeardown
        self.deleteCredentials = deleteCredentials
        self.storeCredentials = storeCredentials
        self.persistsLocalData = persistsLocalData
        self.recordsSyncMutations = recordsSyncMutations

        guard loadLocalDataOnInit else { return }

        loadLocalData()
        Task { await loadData() }
    }

    private static func defaultDeletionTeardown(for server: Server) async {
        await ConnectionSessionManager.shared.disconnectServerAndWait(server.id)
        await TerminalTabManager.shared.disconnectServerAndWait(server.id)
    }

    private static func defaultCredentialDeletion(for serverId: UUID) async throws {
        try KeychainManager.shared.deleteCredentials(for: serverId)
    }

    private static func defaultCredentialStore(for server: Server, credentials: ServerCredentials) throws {
        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                if let password = credentials.password, !password.isEmpty {
                    try KeychainManager.shared.storePassword(for: server.id, password: password)
                }
            case .sshKey:
                if let sshKey = credentials.sshKey, !sshKey.isEmpty {
                    try KeychainManager.shared.storeSSHKey(
                        for: server.id,
                        privateKey: sshKey,
                        passphrase: nil,
                        publicKey: credentials.publicKey
                    )
                }
            case .sshKeyWithPassphrase:
                if let sshKey = credentials.sshKey, !sshKey.isEmpty {
                    let passphrase = credentials.sshPassphrase?.isEmpty == true ? nil : credentials.sshPassphrase
                    try KeychainManager.shared.storeSSHKey(
                        for: server.id,
                        privateKey: sshKey,
                        passphrase: passphrase,
                        publicKey: credentials.publicKey
                    )
                }
            }
        }

        if server.connectionMode == .cloudflare,
           server.cloudflareAccessMode == .serviceToken,
           let cloudflareClientID = credentials.cloudflareClientID,
           let cloudflareClientSecret = credentials.cloudflareClientSecret {
            try KeychainManager.shared.storeCloudflareServiceToken(
                for: server.id,
                clientID: cloudflareClientID,
                clientSecret: cloudflareClientSecret
            )
        } else {
            KeychainManager.shared.deleteCloudflareServiceToken(for: server.id)
        }
    }

    #if DEBUG
    static func makeForTesting(
        servers: [Server] = [],
        workspaces: [Workspace] = [],
        deletionTeardown: @escaping ServerDeletionTeardown = { _ in },
        deleteCredentials: @escaping ServerCredentialDeletion = { _ in },
        storeCredentials: @escaping ServerCredentialStore = { _, _ in }
    ) -> ServerManager {
        let manager = ServerManager(
            loadLocalDataOnInit: false,
            deletionTeardown: deletionTeardown,
            deleteCredentials: deleteCredentials,
            storeCredentials: storeCredentials,
            persistsLocalData: false,
            recordsSyncMutations: false
        )
        manager.servers = servers
        manager.workspaces = workspaces
        return manager
    }
    #endif

    // MARK: - Local Storage

    private func loadLocalData() {
        var shouldPersist = false

        if let decoded = loadStoredServers() {
            servers = decoded
            logger.info("Loaded \(decoded.count) servers from local storage")
        }

        if let decoded = loadStoredWorkspaces() {
            workspaces = decoded
            logger.info("Loaded \(decoded.count) workspaces from local storage")
        }

        shouldPersist = reconcilePendingBootstrapWorkspaceState() || shouldPersist

        if Self.shouldCreateBootstrapWorkspace(
            didBootstrapDefaultWorkspace: didBootstrapDefaultWorkspace,
            hasSeenWelcome: hasSeenWelcome,
            hasLocalWorkspaces: !workspaces.isEmpty
        ) {
            createBootstrapWorkspace()
            didBootstrapDefaultWorkspace = true
            shouldPersist = true
        }

        if shouldPersist {
            saveLocalData()
        }
    }

    private func saveLocalData() {
        guard persistsLocalData else { return }

        storeServers(servers)
        storeWorkspaces(workspaces)
    }

    private func loadStoredServers() -> [Server]? {
        guard let data = UserDefaults.standard.data(forKey: serversKey) else {
            return nil
        }
        return try? JSONDecoder().decode([Server].self, from: data)
    }

    private func loadStoredWorkspaces() -> [Workspace]? {
        guard let data = UserDefaults.standard.data(forKey: workspacesKey) else {
            return nil
        }
        return try? JSONDecoder().decode([Workspace].self, from: data)
    }

    private func storeServers(_ servers: [Server]) {
        guard let data = try? JSONEncoder().encode(servers) else {
            return
        }
        UserDefaults.standard.set(data, forKey: serversKey)
    }

    private func storeWorkspaces(_ workspaces: [Workspace]) {
        guard let data = try? JSONEncoder().encode(workspaces) else {
            return
        }
        UserDefaults.standard.set(data, forKey: workspacesKey)
    }

    private var didBootstrapDefaultWorkspace: Bool {
        get { UserDefaults.standard.bool(forKey: didBootstrapDefaultWorkspaceKey) }
        set { UserDefaults.standard.set(newValue, forKey: didBootstrapDefaultWorkspaceKey) }
    }

    private var hasSeenWelcome: Bool {
        UserDefaults.standard.bool(forKey: hasSeenWelcomeKey)
    }

    private var pendingBootstrapWorkspaceID: UUID? {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: pendingBootstrapWorkspaceIDKey) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: pendingBootstrapWorkspaceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pendingBootstrapWorkspaceIDKey)
            }
        }
    }

    private var transientBootstrapWorkspaceID: UUID? {
        pendingBootstrapWorkspaceID
    }

    private func createBootstrapWorkspace() {
        let workspace = createDefaultWorkspace()
        workspaces = [workspace]

        if isSyncEnabled {
            pendingBootstrapWorkspaceID = workspace.id
            logger.info("Created pending default workspace: \(workspace.name)")
        } else {
            pendingBootstrapWorkspaceID = nil
            logger.info("Created default workspace: \(workspace.name)")
        }
    }

    @discardableResult
    private func reconcilePendingBootstrapWorkspaceState() -> Bool {
        guard let pendingBootstrapWorkspaceID else {
            return false
        }

        guard workspaces.contains(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            self.pendingBootstrapWorkspaceID = nil
            return true
        }

        if servers.contains(where: { $0.workspaceId == pendingBootstrapWorkspaceID }) || workspaces.count > 1 {
            self.pendingBootstrapWorkspaceID = nil
            logger.info("Promoted pending bootstrap workspace \(pendingBootstrapWorkspaceID.uuidString) into regular local state")
            return true
        }

        return refreshPendingBootstrapWorkspaceLocalizationIfNeeded()
    }

    @discardableResult
    private func refreshPendingBootstrapWorkspaceLocalizationIfNeeded() -> Bool {
        guard let pendingBootstrapWorkspaceID,
              let index = workspaces.firstIndex(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            return false
        }

        let localizedName = AppLanguage.localizedString("My Servers")
        guard workspaces[index].name != localizedName,
              Self.isCanonicalDefaultWorkspaceCandidate(workspaces[index]) else {
            return false
        }

        workspaces[index].name = localizedName
        logger.info("Updated pending bootstrap workspace name to match selected app language")
        return true
    }

    private func promotePendingBootstrapWorkspaceIfNeeded(for workspaceID: UUID, reason: String) {
        guard pendingBootstrapWorkspaceID == workspaceID else { return }
        pendingBootstrapWorkspaceID = nil
        logger.info("Promoted pending bootstrap workspace after \(reason)")
    }

    private func resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(_ changes: CloudKitChanges) {
        guard changes.isFullFetch,
              changes.workspaces.isEmpty,
              let pendingBootstrapWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            return
        }

        self.pendingBootstrapWorkspaceID = nil
        enqueuePendingWorkspaceUpsert(workspace)
        logger.info("Promoted pending bootstrap workspace after authoritative CloudKit fetch returned no workspaces")
    }

    // MARK: - Pending CloudKit Sync

    private func enqueuePendingServerUpsert(_ server: Server) {
        guard recordsSyncMutations else { return }
        syncCoordinator.enqueueServerUpsert(server)
    }

    private func enqueuePendingServerDelete(_ server: Server) {
        guard recordsSyncMutations else { return }
        syncCoordinator.enqueueServerDelete(server)
    }

    private func enqueuePendingWorkspaceUpsert(_ workspace: Workspace) {
        guard recordsSyncMutations else { return }
        syncCoordinator.enqueueWorkspaceUpsert(workspace)
    }

    private func enqueuePendingWorkspaceDelete(_ workspace: Workspace) {
        guard recordsSyncMutations else { return }
        syncCoordinator.enqueueWorkspaceDelete(workspace)
    }

    private func applyPendingSyncOverlay() {
        let snapshot = syncCoordinator.snapshot()
        applyPendingUpsertOverlay(in: snapshot)
        applyPendingDeleteOverlay(in: snapshot)
    }

    private func applyPendingUpsertOverlay(in snapshot: [PendingCloudKitMutation]) {
        for mutation in pendingMutations(in: snapshot, entity: .workspace, operation: .upsert) {
            if let workspace = mutation.workspace {
                applyPendingWorkspaceUpsert(workspace)
            }
        }

        for mutation in pendingMutations(in: snapshot, entity: .server, operation: .upsert) {
            if let server = mutation.server {
                applyPendingServerUpsert(server)
            }
        }
    }

    private func applyPendingDeleteOverlay(in snapshot: [PendingCloudKitMutation]) {
        for mutation in pendingMutations(in: snapshot, entity: .server, operation: .delete) {
            applyPendingServerDelete(mutation.entityKey)
        }

        for mutation in pendingMutations(in: snapshot, entity: .workspace, operation: .delete) {
            applyPendingWorkspaceDelete(mutation.entityKey)
        }
    }

    private func reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit(_ changes: CloudKitChanges) {
        let snapshot = syncCoordinator.snapshot()
        let fetchedServersByID = Dictionary(uniqueKeysWithValues: changes.servers.map { ($0.id, $0) })
        let fetchedWorkspacesByID = Dictionary(uniqueKeysWithValues: changes.workspaces.map { ($0.id, $0) })

        removeResolvedPendingServerUpserts(in: snapshot, fetchedServersByID: fetchedServersByID)
        removeResolvedPendingWorkspaceUpserts(in: snapshot, fetchedWorkspacesByID: fetchedWorkspacesByID)
    }

    private func pendingMutations(
        in snapshot: [PendingCloudKitMutation],
        entity: PendingCloudKitEntity,
        operation: PendingCloudKitOperation
    ) -> [PendingCloudKitMutation] {
        snapshot.filter { $0.entity == entity && $0.operation == operation }
    }

    private func removeResolvedPendingServerUpserts(
        in snapshot: [PendingCloudKitMutation],
        fetchedServersByID: [UUID: Server]
    ) {
        for mutation in pendingMutations(in: snapshot, entity: .server, operation: .upsert) {
            guard let pendingServer = mutation.server,
                  let fetchedServer = fetchedServersByID[pendingServer.id] else {
                continue
            }

            if fetchedServer.updatedAt >= pendingServer.updatedAt {
                syncCoordinator.removePendingMutation(mutation.id)
            }
        }
    }

    private func removeResolvedPendingWorkspaceUpserts(
        in snapshot: [PendingCloudKitMutation],
        fetchedWorkspacesByID: [UUID: Workspace]
    ) {
        for mutation in pendingMutations(in: snapshot, entity: .workspace, operation: .upsert) {
            guard let pendingWorkspace = mutation.workspace,
                  let fetchedWorkspace = fetchedWorkspacesByID[pendingWorkspace.id] else {
                continue
            }

            if fetchedWorkspace.updatedAt >= pendingWorkspace.updatedAt {
                syncCoordinator.removePendingMutation(mutation.id)
            }
        }
    }

    private func applyPendingServerUpsert(_ server: Server) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
    }

    private func applyPendingServerDelete(_ serverKey: String) {
        guard let serverID = UUID(uuidString: serverKey) else { return }
        servers.removeAll { $0.id == serverID }
    }

    private func applyPendingWorkspaceUpsert(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    private func applyPendingWorkspaceDelete(_ workspaceKey: String) {
        guard let workspaceID = UUID(uuidString: workspaceKey) else { return }
        workspaces.removeAll { $0.id == workspaceID }
        servers.removeAll { $0.workspaceId == workspaceID }
    }

    private func drainPendingCloudKitMutations() async {
        guard isSyncEnabled else { return }
        await syncCoordinator.drainPendingMutations()
    }

    private func persistLocalMutations(logMessage: String? = nil) async {
        saveLocalData()
        if persistsLocalData {
            await drainPendingCloudKitMutations()
        }
        if let logMessage {
            logger.info("\(logMessage)")
        }
    }

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

    /// Clear all local data and re-download from CloudKit
    func clearLocalDataAndResync() async {
        logger.info("Clearing local data and re-syncing from CloudKit...")

        // Clear local storage
        UserDefaults.standard.removeObject(forKey: serversKey)
        UserDefaults.standard.removeObject(forKey: workspacesKey)
        pendingBootstrapWorkspaceID = nil
        syncCoordinator.clearPendingMutations(for: [.server, .workspace])

        // Clear in-memory data
        servers = []
        workspaces = []
        error = nil

        // Re-fetch from CloudKit
        await loadData()

        logger.info("Clear and re-sync complete: \(self.workspaces.count) workspaces, \(self.servers.count) servers")
    }

    // MARK: - Data Loading

    func loadData() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard isSyncEnabled else {
            logger.info("iCloud sync disabled; using local data only")
            return
        }

        do {
            let shouldForceFullFetch = shouldForceCloudKitFullFetchForBootstrap
            let fetchedChanges = try await cloudKit.fetchChanges(forceFullFetch: shouldForceFullFetch)
            resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(fetchedChanges)
            let backfillResult = await backfillMissingLocalRecordsIfNeeded(for: fetchedChanges)
            let changes = backfillResult.changes

            // Merge CloudKit data with local (CloudKit wins for conflicts, dedupe by ID)
            logger.info(
                "CloudKit returned \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
            )

            await applyCloudKitChanges(changes, canReplaceLocalState: backfillResult.canReplaceLocalState)
            reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit(changes)
            applyPendingSyncOverlay()
            _ = reconcilePendingBootstrapWorkspaceState()

            // Check for and repair orphaned servers (workspaceId doesn't match any workspace)
            await repairOrphanedServers()
            await drainPendingCloudKitMutations()

            // Save merged data locally
            saveLocalData()

            logger.info("Loaded \(self.workspaces.count) workspaces and \(self.servers.count) servers from CloudKit")
        } catch {
            logger.error("Failed to load from CloudKit: \(error.localizedDescription)")
            self.error = error.localizedDescription
            // Local data is already loaded in init, so nothing to do here
            logger.info("Using local data: \(self.workspaces.count) workspaces and \(self.servers.count) servers")

            // Only try to push local data if it's a schema error (record type not found)
            // This auto-creates schema in development mode
            if cloudKit.isAvailable && CloudKitManager.isSchemaError(error) {
                logger.info("Schema error detected, attempting to initialize schema...")
                await initializeCloudKitSchema()
            }
        }
    }

    /// If a full fetch is missing local records (common after schema was unavailable),
    /// push the missing records to CloudKit so users don't need to edit each item manually.
    private func backfillMissingLocalRecordsIfNeeded(for changes: CloudKitChanges) async -> FullFetchBackfillResult {
        guard changes.isFullFetch, isSyncEnabled, cloudKit.isAvailable else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        if changes.workspaces.isEmpty && changes.servers.isEmpty && localCacheContainsUserData {
            logger.warning(
                "CloudKit full fetch returned no workspaces or servers while local cache contains user data; preserving local state until an explicit recovery path resolves the mismatch"
            )
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: false)
        }

        let cloudWorkspaceIDs = Set(changes.workspaces.map(\.id))
        let cloudServerIDs = Set(changes.servers.map(\.id))
        let missingCandidates = Self.backfillCandidates(
            localWorkspaces: workspaces,
            localServers: servers,
            cloudWorkspaceIDs: cloudWorkspaceIDs,
            cloudServerIDs: cloudServerIDs,
            transientBootstrapWorkspaceID: transientBootstrapWorkspaceID
        )
        let missingWorkspaces = missingCandidates.workspaces
        let missingServers = missingCandidates.servers

        guard !missingWorkspaces.isEmpty || !missingServers.isEmpty else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        logger.warning(
            "CloudKit full fetch is missing \(missingWorkspaces.count) local workspaces and \(missingServers.count) local servers; queuing recovery upserts and attempting backfill"
        )

        for workspace in missingWorkspaces {
            enqueuePendingWorkspaceUpsert(workspace)
        }

        for server in missingServers {
            enqueuePendingServerUpsert(server)
        }

        var uploadedWorkspaces: [Workspace] = []
        for workspace in missingWorkspaces {
            do {
                try await cloudKit.saveWorkspace(workspace)
                uploadedWorkspaces.append(workspace)
            } catch {
                logger.warning("Failed to backfill workspace \(workspace.name): \(error.localizedDescription)")
            }
        }

        var knownWorkspaceIDs = cloudWorkspaceIDs
        knownWorkspaceIDs.formUnion(uploadedWorkspaces.map(\.id))

        var uploadedServers: [Server] = []
        for server in missingServers {
            guard knownWorkspaceIDs.contains(server.workspaceId) else {
                logger.warning("Skipping server backfill for \(server.name) because workspace \(server.workspaceId) is unavailable in CloudKit")
                continue
            }

            do {
                try await cloudKit.saveServer(server)
                uploadedServers.append(server)
            } catch {
                logger.warning("Failed to backfill server \(server.name): \(error.localizedDescription)")
            }
        }

        let backfillCompleted = uploadedWorkspaces.count == missingWorkspaces.count &&
            uploadedServers.count == missingServers.count

        return FullFetchBackfillResult(
            changes: CloudKitChanges(
                servers: changes.servers + uploadedServers,
                workspaces: changes.workspaces + uploadedWorkspaces,
                deletedServerIDs: changes.deletedServerIDs,
                deletedWorkspaceIDs: changes.deletedWorkspaceIDs,
                isFullFetch: changes.isFullFetch
            ),
            canReplaceLocalState: backfillCompleted
        )
    }

    private var localCacheContainsUserData: Bool {
        if !servers.isEmpty {
            return true
        }

        let effectiveWorkspaces = workspaces.filter { $0.id != transientBootstrapWorkspaceID }

        guard !effectiveWorkspaces.isEmpty else {
            return false
        }

        if effectiveWorkspaces.count > 1 {
            return true
        }

        guard let workspace = effectiveWorkspaces.first else {
            return false
        }

        return !isCanonicalDefaultWorkspace(workspace)
    }

    private var shouldForceCloudKitFullFetchForBootstrap: Bool {
        pendingBootstrapWorkspaceID != nil
    }

    private func isCanonicalDefaultWorkspace(_ workspace: Workspace) -> Bool {
        Self.isCanonicalDefaultWorkspaceCandidate(workspace)
    }

    private func createDefaultWorkspace() -> Workspace {
        Workspace(
            name: AppLanguage.localizedString("My Servers"),
            colorHex: "#007AFF",
            order: 0
        )
    }

    static func shouldCreateBootstrapWorkspace(
        didBootstrapDefaultWorkspace: Bool,
        hasSeenWelcome: Bool,
        hasLocalWorkspaces: Bool
    ) -> Bool {
        !(didBootstrapDefaultWorkspace || hasSeenWelcome) && !hasLocalWorkspaces
    }

    static func isCanonicalDefaultWorkspaceCandidate(_ workspace: Workspace) -> Bool {
        AppLanguage.localizedValues(for: "My Servers").contains(workspace.name) &&
            workspace.colorHex == "#007AFF" &&
            workspace.icon == nil &&
            workspace.order == 0 &&
            workspace.environments == ServerEnvironment.builtInEnvironments &&
            workspace.lastSelectedEnvironmentId == nil &&
            workspace.lastSelectedServerId == nil
    }

    static func backfillCandidates(
        localWorkspaces: [Workspace],
        localServers: [Server],
        cloudWorkspaceIDs: Set<UUID>,
        cloudServerIDs: Set<UUID>,
        transientBootstrapWorkspaceID: UUID?
    ) -> (workspaces: [Workspace], servers: [Server]) {
        let missingWorkspaces = localWorkspaces.filter {
            !cloudWorkspaceIDs.contains($0.id) && $0.id != transientBootstrapWorkspaceID
        }

        let missingWorkspaceIDs = Set(missingWorkspaces.map(\.id))
        let missingServers = localServers.filter {
            !cloudServerIDs.contains($0.id) &&
                $0.workspaceId != transientBootstrapWorkspaceID &&
                (cloudWorkspaceIDs.contains($0.workspaceId) || missingWorkspaceIDs.contains($0.workspaceId))
        }

        return (missingWorkspaces, missingServers)
    }

    static func workspaceForOrphanRepair(
        existingWorkspaces: [Workspace],
        servers: [Server],
        fallbackWorkspace: Workspace
    ) -> Workspace? {
        let workspaceIDs = Set(existingWorkspaces.map(\.id))
        guard servers.contains(where: { !workspaceIDs.contains($0.workspaceId) }) else {
            return nil
        }

        return existingWorkspaces.first ?? fallbackWorkspace
    }

    private func makeWorkspaceMap(from workspaces: [Workspace]) -> [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
    }

    private func makeServerMap(from servers: [Server]) -> [UUID: Server] {
        Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
    }

    private func removeKnownHosts(for candidates: [KnownHostRemovalCandidate]) async {
        for candidate in candidates {
            await KnownHostsStore.shared.remove(host: candidate.host, port: candidate.port)
        }
    }

    private func sortedWorkspaces(from workspaceMap: [UUID: Workspace]) -> [Workspace] {
        Array(workspaceMap.values).sorted { $0.order < $1.order }
    }

    private func sortedServers(from serverMap: [UUID: Server]) -> [Server] {
        Array(serverMap.values).sorted { $0.name < $1.name }
    }

    static func knownHostRemovalCandidates(
        removedServers: [Server],
        remainingServers: [Server]
    ) -> [KnownHostRemovalCandidate] {
        var candidates: [KnownHostRemovalCandidate] = []
        var seen = Set<String>()

        for server in removedServers {
            let isStillUsed = remainingServers.contains {
                $0.host == server.host && $0.port == server.port
            }
            guard !isStillUsed else { continue }

            let key = "\(server.host):\(server.port)"
            guard seen.insert(key).inserted else { continue }
            candidates.append(KnownHostRemovalCandidate(host: server.host, port: server.port))
        }

        return candidates
    }

    private func applyCloudKitChanges(_ changes: CloudKitChanges, canReplaceLocalState: Bool = true) async {
        if changes.isFullFetch && canReplaceLocalState {
            applyFullFetchCloudKitChanges(changes)
            return
        }

        await applyIncrementalCloudKitChanges(changes)
    }

    private func applyFullFetchCloudKitChanges(_ changes: CloudKitChanges) {
        workspaces = dedupedWorkspaces(from: changes.workspaces)
        servers = dedupedServers(from: changes.servers)
    }

    private func applyIncrementalCloudKitChanges(_ changes: CloudKitChanges) async {
        if !changes.workspaces.isEmpty {
            upsertWorkspaces(changes.workspaces)
        }
        if !changes.deletedWorkspaceIDs.isEmpty {
            removeWorkspaces(withIDs: changes.deletedWorkspaceIDs)
        }
        if !changes.servers.isEmpty {
            upsertServers(changes.servers)
        }
        if !changes.deletedServerIDs.isEmpty {
            await removeServers(withIDs: changes.deletedServerIDs)
        }
    }

    private func dedupedWorkspaces(from updates: [Workspace]) -> [Workspace] {
        var workspaceMap: [UUID: Workspace] = [:]
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
            logger.info("Workspace from CloudKit: \(workspace.name) (id: \(workspace.id))")
        }
        return sortedWorkspaces(from: workspaceMap)
    }

    private func dedupedServers(from updates: [Server]) -> [Server] {
        var serverMap: [UUID: Server] = [:]
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        return sortedServers(from: serverMap)
    }

    private func upsertWorkspaces(_ updates: [Workspace]) {
        var workspaceMap = makeWorkspaceMap(from: workspaces)
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
            logger.info("Workspace updated from CloudKit: \(workspace.name) (id: \(workspace.id))")
        }
        workspaces = sortedWorkspaces(from: workspaceMap)
    }

    private func upsertServers(_ updates: [Server]) {
        var serverMap = makeServerMap(from: servers)
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server updated from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        servers = sortedServers(from: serverMap)
    }

    private func removeWorkspaces(withIDs ids: [UUID]) {
        let idSet = Set(ids)
        workspaces.removeAll { idSet.contains($0.id) }
    }

    private func removeServers(withIDs ids: [UUID]) async {
        let idSet = Set(ids)
        let removedServers = servers.filter { idSet.contains($0.id) }
        servers.removeAll { idSet.contains($0.id) }
        let candidates = Self.knownHostRemovalCandidates(
            removedServers: removedServers,
            remainingServers: servers
        )
        await removeKnownHosts(for: candidates)
    }

    /// Repairs servers that reference non-existent workspaces by reassigning them to the first available workspace
    private func repairOrphanedServers() async {
        let workspaceIds = Set(workspaces.map { $0.id })
        let orphanedServers = servers.filter { !workspaceIds.contains($0.workspaceId) }

        guard !orphanedServers.isEmpty else { return }

        if workspaces.isEmpty {
            let repairWorkspace = Self.workspaceForOrphanRepair(
                existingWorkspaces: workspaces,
                servers: servers,
                fallbackWorkspace: createDefaultWorkspace()
            )
            guard let repairWorkspace else { return }

            workspaces = [repairWorkspace]
            if isSyncEnabled {
                enqueuePendingWorkspaceUpsert(repairWorkspace)
            }
            logger.warning("Created repair workspace '\(repairWorkspace.name)' to recover orphaned servers")
        }

        logger.warning("Found \(orphanedServers.count) ORPHANED servers (workspaceId doesn't match any workspace):")
        for server in orphanedServers {
            logger.warning("  - \(server.name) (id: \(server.id)) references missing workspaceId: \(server.workspaceId)")
        }

        // Auto-repair: reassign orphaned servers to first workspace
        let defaultWorkspace = workspaces[0]
        logger.info("Auto-repairing: reassigning orphaned servers to workspace '\(defaultWorkspace.name)'")
        for i in servers.indices {
            if !workspaceIds.contains(servers[i].workspaceId) {
                let oldWorkspaceId = servers[i].workspaceId
                servers[i] = Server(
                    id: servers[i].id,
                    workspaceId: defaultWorkspace.id,
                    environment: servers[i].environment,
                    name: servers[i].name,
                    host: servers[i].host,
                    port: servers[i].port,
                    username: servers[i].username,
                    connectionMode: servers[i].connectionMode,
                    authMethod: servers[i].authMethod,
                    cloudflareAccessMode: servers[i].cloudflareAccessMode,
                    cloudflareTeamDomainOverride: servers[i].cloudflareTeamDomainOverride,
                    cloudflareAppDomainOverride: servers[i].cloudflareAppDomainOverride,
                    tags: servers[i].tags,
                    notes: servers[i].notes,
                    lastConnected: servers[i].lastConnected,
                    isFavorite: servers[i].isFavorite,
                    requiresBiometricUnlock: servers[i].requiresBiometricUnlock,
                    multiplexerOverride: servers[i].multiplexerOverride,
                    tmuxStartupBehaviorOverride: servers[i].tmuxStartupBehaviorOverride,
                    createdAt: servers[i].createdAt,
                    updatedAt: Date()
                )
                logger.info("Reassigned server '\(self.servers[i].name)' from \(oldWorkspaceId) to \(defaultWorkspace.id)")

                if isSyncEnabled {
                    enqueuePendingServerUpsert(servers[i])
                }
            }
        }
    }

    /// Push local data to CloudKit to auto-create schema in development mode
    private func initializeCloudKitSchema() async {
        logger.info("Attempting to initialize CloudKit schema by pushing local data...")

        // Push workspaces first
        for workspace in workspaces {
            do {
                if isSyncEnabled {
                    try await cloudKit.saveWorkspace(workspace)
                }
                logger.info("Pushed workspace to CloudKit: \(workspace.name)")
            } catch {
                logger.error("Failed to push workspace \(workspace.name): \(error.localizedDescription)")
            }
        }

        // Push servers
        for server in servers {
            do {
                if isSyncEnabled {
                    try await cloudKit.saveServer(server)
                }
                logger.info("Pushed server to CloudKit: \(server.name)")
            } catch {
                logger.error("Failed to push server \(server.name): \(error.localizedDescription)")
            }
        }

        logger.info("CloudKit schema initialization complete")
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

    @discardableResult
    func requestServerDeletion(
        _ server: Server,
        onDeleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        trackDeletionRequest(operation: .deleteServer(server.id)) { [weak self] in
            guard let self else { return }
            try await self.deleteServer(server)
            onDeleted()
        }
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

    @discardableResult
    func requestWorkspaceSave(
        _ workspace: Workspace,
        mode: WorkspaceSaveMode,
        onSaved: @escaping @MainActor (Workspace) -> Void = { _ in },
        onProRequired: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (String) -> Void = { _ in }
    ) -> UUID {
        let operation: ServerWorkspaceSaveFailure.Operation = switch mode {
        case .create:
            .createWorkspace(workspace.id)
        case .update:
            .updateWorkspace(workspace.id)
        }

        return trackWorkspaceSaveRequest(
            operation: operation,
            onProRequired: onProRequired,
            onFailed: onFailed
        ) { [weak self] in
            guard let self else { return }
            switch mode {
            case .create:
                try await self.addWorkspace(workspace)
            case .update:
                try await self.updateWorkspace(workspace)
            }
            onSaved(self.workspaces.first { $0.id == workspace.id } ?? workspace)
        }
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

    @discardableResult
    func requestWorkspaceDeletion(
        _ workspace: Workspace,
        onDeleted: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (String) -> Void = { _ in }
    ) -> UUID {
        trackDeletionRequest(
            operation: .deleteWorkspace(workspace.id),
            onFailed: onFailed
        ) { [weak self] in
            guard let self else { return }
            try await self.deleteWorkspace(workspace)
            onDeleted()
        }
    }

    @discardableResult
    func requestEnvironmentDeletion(
        _ environment: ServerEnvironment,
        in workspace: Workspace,
        fallback: ServerEnvironment,
        onDeleted: @escaping @MainActor (Workspace) -> Void = { _ in }
    ) -> UUID {
        trackDeletionRequest(
            operation: .deleteEnvironment(workspaceID: workspace.id, environmentID: environment.id)
        ) { [weak self] in
            guard let self else { return }
            let updatedWorkspace = try await self.deleteEnvironment(
                environment,
                in: workspace,
                fallback: fallback
            )
            onDeleted(updatedWorkspace)
        }
    }

    func clearDeletionFailure() {
        deletionFailure = nil
    }

    func waitForDeletionRequest(_ requestID: UUID) async {
        await deletionRequests[requestID]?.value
    }

    func clearWorkspaceSaveFailure() {
        workspaceSaveFailure = nil
    }

    func waitForWorkspaceSaveRequest(_ requestID: UUID) async {
        await workspaceSaveRequests[requestID]?.value
    }

    func clearEnvironmentSaveFailure() {
        environmentSaveFailure = nil
    }

    func waitForEnvironmentSaveRequest(_ requestID: UUID) async {
        await environmentSaveRequests[requestID]?.value
    }

    private func trackDeletionRequest(
        operation: ServerDeletionFailure.Operation,
        onFailed: @escaping @MainActor (String) -> Void = { _ in },
        _ action: @escaping @MainActor () async throws -> Void
    ) -> UUID {
        let requestID = UUID()
        deletionFailure = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await action()
            } catch {
                self.error = error.localizedDescription
                self.deletionFailure = ServerDeletionFailure(operation: operation, error: error)
                onFailed(error.localizedDescription)
            }
            self.deletionRequests.removeValue(forKey: requestID)
        }

        deletionRequests[requestID] = task
        return requestID
    }

    private func trackWorkspaceSaveRequest(
        operation: ServerWorkspaceSaveFailure.Operation,
        onProRequired: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (String) -> Void = { _ in },
        _ action: @escaping @MainActor () async throws -> Void
    ) -> UUID {
        let requestID = UUID()
        workspaceSaveFailure = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await action()
            } catch let error as VVTermError {
                self.error = error.localizedDescription
                self.workspaceSaveFailure = ServerWorkspaceSaveFailure(operation: operation, error: error)
                if case .proRequired = error {
                    onProRequired()
                } else {
                    onFailed(error.localizedDescription)
                }
            } catch {
                self.error = error.localizedDescription
                self.workspaceSaveFailure = ServerWorkspaceSaveFailure(operation: operation, error: error)
                onFailed(error.localizedDescription)
            }
            self.workspaceSaveRequests.removeValue(forKey: requestID)
        }

        workspaceSaveRequests[requestID] = task
        return requestID
    }

    private func trackEnvironmentSaveRequest(
        operation: ServerEnvironmentSaveFailure.Operation,
        onFailed: @escaping @MainActor (String) -> Void = { _ in },
        _ action: @escaping @MainActor () async throws -> Void
    ) -> UUID {
        let requestID = UUID()
        environmentSaveFailure = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await action()
            } catch {
                self.error = error.localizedDescription
                self.environmentSaveFailure = ServerEnvironmentSaveFailure(operation: operation, error: error)
                onFailed(error.localizedDescription)
            }
            self.environmentSaveRequests.removeValue(forKey: requestID)
        }

        environmentSaveRequests[requestID] = task
        return requestID
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
        return workspacesSortedByOrder.filter { destinationIDs.contains($0.id) }
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
        if StoreManager.shared.isPro { return true }
        return servers.count < FreeTierLimits.maxServers
    }

    var canAddWorkspace: Bool {
        if StoreManager.shared.isPro { return true }
        return workspaces.count < FreeTierLimits.maxWorkspaces
    }

    var canCreateCustomEnvironment: Bool {
        StoreManager.shared.isPro
    }

    // MARK: - Downgrade Locking
    // When user downgrades from Pro, excess servers/workspaces are locked

    /// Returns sorted servers with oldest (by createdAt) first - these get priority access
    private var serversSortedByCreation: [Server] {
        servers.sorted { $0.createdAt < $1.createdAt }
    }

    /// Returns sorted workspaces with oldest (by order, then createdAt) first
    private var workspacesSortedByOrder: [Workspace] {
        workspaces.sorted { $0.order < $1.order }
    }

    /// Set of server IDs that are accessible on free tier (oldest N servers)
    var unlockedServerIds: Set<UUID> {
        if StoreManager.shared.isPro { return Set(servers.map(\.id)) }
        let unlocked = serversSortedByCreation.prefix(FreeTierLimits.maxServers)
        return Set(unlocked.map(\.id))
    }

    /// Set of workspace IDs that are accessible on free tier (first N workspaces by order)
    var unlockedWorkspaceIds: Set<UUID> {
        if StoreManager.shared.isPro { return Set(workspaces.map(\.id)) }
        let unlocked = workspacesSortedByOrder.prefix(FreeTierLimits.maxWorkspaces)
        return Set(unlocked.map(\.id))
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server) -> Bool {
        if StoreManager.shared.isPro { return false }
        return !unlockedServerIds.contains(server.id)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace) -> Bool {
        if StoreManager.shared.isPro { return false }
        return !unlockedWorkspaceIds.contains(workspace.id)
    }

    /// Number of servers that are locked due to downgrade
    var lockedServersCount: Int {
        if StoreManager.shared.isPro { return 0 }
        return max(0, servers.count - FreeTierLimits.maxServers)
    }

    /// Number of workspaces that are locked due to downgrade
    var lockedWorkspacesCount: Int {
        if StoreManager.shared.isPro { return 0 }
        return max(0, workspaces.count - FreeTierLimits.maxWorkspaces)
    }

    /// Whether user has any locked items after downgrade
    var hasLockedItems: Bool {
        lockedServersCount > 0 || lockedWorkspacesCount > 0
    }

    private func moveDestinationIDs(for server: Server) -> Set<UUID> {
        ServerMoveSupport.allowedDestinationIDs(
            isPro: StoreManager.shared.isPro,
            sourceWorkspaceId: server.workspaceId,
            workspacesInOrder: workspacesSortedByOrder,
            unlockedWorkspaceIds: unlockedWorkspaceIds
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

    @discardableResult
    func requestEnvironmentSave(
        _ environment: ServerEnvironment,
        in workspace: Workspace,
        mode: ServerEnvironmentSaveMode,
        onSaved: @escaping @MainActor (Workspace, ServerEnvironment) -> Void = { _, _ in },
        onFailed: @escaping @MainActor (String) -> Void = { _ in }
    ) -> UUID {
        let operation: ServerEnvironmentSaveFailure.Operation = switch mode {
        case .create:
            .createEnvironment(workspaceID: workspace.id, environmentID: environment.id)
        case .update:
            .updateEnvironment(workspaceID: workspace.id, environmentID: environment.id)
        }

        return trackEnvironmentSaveRequest(
            operation: operation,
            onFailed: onFailed
        ) { [weak self] in
            guard let self else { return }
            let currentWorkspace = self.workspace(withId: workspace.id) ?? workspace
            let savedWorkspace: Workspace

            switch mode {
            case .create:
                guard self.canCreateCustomEnvironment else {
                    throw VVTermError.proRequired(String(localized: "Upgrade to Pro for custom environments"))
                }
                var updatedWorkspace = currentWorkspace
                if !updatedWorkspace.environments.contains(where: { $0.id == environment.id }) {
                    updatedWorkspace.environments.append(environment)
                }
                try await self.updateWorkspace(updatedWorkspace)
                savedWorkspace = self.workspace(withId: workspace.id) ?? updatedWorkspace
            case .update:
                savedWorkspace = try await self.updateEnvironment(environment, in: currentWorkspace)
            }

            onSaved(savedWorkspace, environment)
        }
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

// MARK: - Free Tier Limits

enum FreeTierLimits {
    static let maxWorkspaces = 1
    static let maxServers = 3
    static let maxTabs = 2
    static let maxFileTabs = 1
    static let maxCustomActions = 3
}

// MARK: - VVTerm Error

enum VVTermError: LocalizedError {
    case proRequired(String)
    case serverLocked(String)
    case workspaceLocked(String)
    case moveNotAllowed(String)
    case connectionFailed(String)
    case authenticationFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .proRequired(let message): return message
        case .serverLocked(let serverName):
            return String(format: String(localized: "Server '%@' is locked"), serverName)
        case .workspaceLocked(let workspaceName):
            return String(format: String(localized: "Workspace '%@' is locked"), workspaceName)
        case .moveNotAllowed(let message):
            return message
        case .connectionFailed(let message):
            return String(format: String(localized: "Connection failed: %@"), message)
        case .authenticationFailed:
            return String(localized: "Authentication failed")
        case .timeout:
            return String(localized: "Connection timed out")
        }
    }

    var isLockedError: Bool {
        switch self {
        case .serverLocked, .workspaceLocked: return true
        default: return false
        }
    }
}
