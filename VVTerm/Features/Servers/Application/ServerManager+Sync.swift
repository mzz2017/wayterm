import Foundation
import os.log

private struct FullFetchBackfillResult {
    let changes: CloudKitChanges
    let canReplaceLocalState: Bool
}

extension ServerManager {
    // MARK: - Pending CloudKit Sync

    func enqueuePendingServerUpsert(_ server: Server) {
        guard recordsSyncMutations else { return }
        syncCoordinator.enqueueServerUpsert(server)
    }

    func enqueuePendingServerDelete(_ server: Server) {
        guard recordsSyncMutations else { return }
        syncCoordinator.enqueueServerDelete(server)
    }

    func enqueuePendingWorkspaceUpsert(_ workspace: Workspace) {
        guard recordsSyncMutations else { return }
        syncCoordinator.enqueueWorkspaceUpsert(workspace)
    }

    func enqueuePendingWorkspaceDelete(_ workspace: Workspace) {
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

    func persistLocalMutations(logMessage: String? = nil) async {
        saveLocalData()
        if persistsLocalData {
            await drainPendingCloudKitMutations()
        }
        if let logMessage {
            logger.info("\(logMessage)")
        }
    }

    // MARK: - Data Loading

    func startStartupLoad() {
        startupLoadTask?.cancel()

        let requestID = UUID()
        startupLoadRequestID = requestID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.startupLoadRequestID == requestID {
                    self.startupLoadRequestID = nil
                    self.startupLoadTask = nil
                }
            }

            await self.startupLoadAction(self)
        }

        if startupLoadRequestID == requestID {
            startupLoadTask = task
        }
    }

    func waitForStartupLoadRequest(_ requestID: UUID) async {
        guard startupLoadRequestID == requestID else { return }
        await startupLoadTask?.value
    }

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

    func removeKnownHosts(for candidates: [KnownHostRemovalCandidate]) async {
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
}
