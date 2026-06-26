import Foundation

extension ServerManager {
    @discardableResult
    func requestServerSave(
        _ server: Server,
        credentials: ServerCredentials,
        mode: ServerSaveMode,
        onSaved: @escaping @MainActor (Server) -> Void = { _ in },
        onProRequired: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (String) -> Void = { _ in }
    ) -> UUID {
        let operation: ServerSaveFailure.Operation = switch mode {
        case .create:
            .createServer(server.id)
        case .update:
            .updateServer(server.id)
        }

        return trackServerSaveRequest(
            operation: operation,
            onProRequired: onProRequired,
            onFailed: onFailed
        ) { [weak self] in
            guard let self else { return }
            switch mode {
            case .create:
                try await self.addServer(server, credentials: credentials)
            case .update:
                try await self.updateServer(server, credentials: credentials)
            }
            onSaved(self.servers.first { $0.id == server.id } ?? server)
        }
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

    @discardableResult
    func requestServerMove(
        _ server: Server,
        to destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil,
        onMoved: @escaping @MainActor (Server) -> Void = { _ in },
        onProRequired: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (String) -> Void = { _ in }
    ) -> UUID {
        trackServerMoveRequest(
            operation: .moveServer(server.id, destination.id),
            onProRequired: onProRequired,
            onFailed: onFailed
        ) { [weak self] in
            guard let self else { return }
            let movedServer = try await self.moveServer(
                server,
                to: destination,
                preferredEnvironment: preferredEnvironment
            )
            onMoved(movedServer)
        }
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

    func clearServerSaveFailure() {
        serverSaveFailure = nil
    }

    func waitForServerSaveRequest(_ requestID: UUID) async {
        await serverSaveRequests[requestID]?.value
    }

    func clearServerMoveFailure() {
        serverMoveFailure = nil
    }

    func waitForServerMoveRequest(_ requestID: UUID) async {
        await serverMoveRequests[requestID]?.value
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

    private func trackServerSaveRequest(
        operation: ServerSaveFailure.Operation,
        onProRequired: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (String) -> Void = { _ in },
        _ action: @escaping @MainActor () async throws -> Void
    ) -> UUID {
        let requestID = UUID()
        serverSaveFailure = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await action()
            } catch let error as VVTermError {
                self.error = error.localizedDescription
                self.serverSaveFailure = ServerSaveFailure(operation: operation, error: error)
                if case .proRequired = error {
                    onProRequired()
                } else {
                    onFailed(error.localizedDescription)
                }
            } catch {
                self.error = error.localizedDescription
                self.serverSaveFailure = ServerSaveFailure(operation: operation, error: error)
                onFailed(error.localizedDescription)
            }
            self.serverSaveRequests.removeValue(forKey: requestID)
        }

        serverSaveRequests[requestID] = task
        return requestID
    }

    private func trackServerMoveRequest(
        operation: ServerMoveFailure.Operation,
        onProRequired: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (String) -> Void = { _ in },
        _ action: @escaping @MainActor () async throws -> Void
    ) -> UUID {
        let requestID = UUID()
        serverMoveFailure = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await action()
            } catch let error as VVTermError {
                self.error = error.localizedDescription
                self.serverMoveFailure = ServerMoveFailure(operation: operation, error: error)
                if case .proRequired = error {
                    onProRequired()
                } else {
                    onFailed(error.localizedDescription)
                }
            } catch {
                self.error = error.localizedDescription
                self.serverMoveFailure = ServerMoveFailure(operation: operation, error: error)
                onFailed(error.localizedDescription)
            }
            self.serverMoveRequests.removeValue(forKey: requestID)
        }

        serverMoveRequests[requestID] = task
        return requestID
    }
}
