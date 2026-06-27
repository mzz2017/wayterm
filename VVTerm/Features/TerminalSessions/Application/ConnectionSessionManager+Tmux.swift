import Foundation
import os.log

extension ConnectionSessionManager {
    // MARK: - tmux Integration

    private func resolveTmuxWorkingDirectory(for sessionId: UUID, using client: SSHClient) async -> String {
        if let path = await tmuxService.currentPath(
            sessionName: tmuxResolver.sessionName(for: sessionId),
            using: client
        ) {
            setStoredWorkingDirectory(path, for: sessionId)
            return path
        }

        if let candidate = storedWorkingDirectory(for: sessionId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
    }

    func workingDirectory(for sessionId: UUID) -> String? {
        storedWorkingDirectory(for: sessionId)
    }

    func shouldApplyWorkingDirectory(for sessionId: UUID) -> Bool {
        guard let status = tmuxStatus(for: sessionId) else { return false }
        return status == .off || status == .missing
    }

    func normalizeWorkingDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
            let path = String(afterScheme[pathStart...])
            return path.removingPercentEncoding ?? path
        }

        return trimmed
    }

    func updateTmuxSelectionStatuses() {
        guard let selectedId = selectedSessionId else {
            for index in sessions.indices {
                if sessions[index].tmuxStatus == .foreground {
                    setTmuxStatus(.background, for: sessions[index].id)
                }
            }
            return
        }
        for index in sessions.indices {
            let status = sessions[index].tmuxStatus
            guard status == .foreground || status == .background else { continue }
            setTmuxStatus((sessions[index].id == selectedId) ? .foreground : .background, for: sessions[index].id)
        }
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for session in sessions where session.serverId == serverId {
            let ownership = tmuxResolver.sessionOwnership[session.id] ?? .managed
            guard ownership == .managed else { continue }
            names.insert(tmuxResolver.sessionName(for: session.id))
        }
        return names
    }

    private func tmuxSessionNamesToKeep(
        for serverId: UUID,
        sessionId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedTmuxSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(tmuxResolver.sessionName(for: sessionId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    func clearTmuxRuntimeState(for sessionId: UUID) {
        tmuxResolver.clearRuntimeState(for: sessionId, setPrompt: setTmuxAttachPrompt)
    }

    func resolveTmuxAttachPrompt(sessionId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: sessionId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(sessionId: UUID) {
        tmuxResolver.cancelPrompt(entityId: sessionId, setPrompt: setTmuxAttachPrompt)
    }

    private func currentTmuxStatus(for sessionId: UUID) -> TmuxStatus {
        selectedSessionId == sessionId ? .foreground : .background
    }

    private func disableTmuxAttachment(for sessionId: UUID, status: TmuxStatus) {
        tmuxResolver.clearAttachmentState(for: sessionId)
        updateTmuxStatus(sessionId, status: status)
    }

    private func runTmuxCleanupIfNeeded(
        for serverId: UUID,
        sessionId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient
    ) async {
        var cleanupSet = tmuxCleanupStore.serverIDs
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: tmuxSessionNamesToKeep(for: serverId, sessionId: sessionId, selection: selection),
            using: client
        )
        tmuxCleanupStore.replace(with: cleanupSet)
    }

    private func prepareActiveTmuxSession(
        for sessionId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        updateTmuxStatus(sessionId, status: currentTmuxStatus(for: sessionId))
        let terminalType = await client.remoteTerminalType()
        await tmuxService.prepareConfig(using: client, terminalType: terminalType, backend: backend)
    }

    private func immediateTmuxSelection(for sessionId: UUID) -> TmuxAttachSelection {
        if tmuxResolver.sessionOwnership[sessionId] == .external {
            return .attachExisting(sessionName: tmuxResolver.sessionName(for: sessionId))
        }

        tmuxResolver.sessionNames[sessionId] = tmuxResolver.managedSessionName(for: sessionId)
        tmuxResolver.sessionOwnership[sessionId] = .managed
        return .createManaged
    }

    private func tmuxStartupCommand(
        for sessionId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return tmuxService.startupAttachCommand(
                sessionName: tmuxResolver.sessionName(for: sessionId),
                workingDirectory: workingDirectory,
                backend: backend
            )
        case .attachExisting(let sessionName):
            return tmuxService.startupAttachExistingCommand(sessionName: sessionName, backend: backend)
        }
    }

    func handleTmuxLifecycle(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: .off)
            }
            return
        }

        guard await client.supportsTmuxRuntime() else {
            logger.info("Resolved remote environment does not support tmux runtime for session \(sessionId.uuidString, privacy: .public); using plain SSH shell")
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: .off)
            }
            return
        }

        guard let backend = await tmuxService.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: self.tmuxResolver.unavailableStatus(for: serverId))
            }
            return
        }

        let selection = immediateTmuxSelection(for: sessionId)

        await runTmuxCleanupIfNeeded(for: serverId, sessionId: sessionId, selection: selection, using: client)
        await prepareActiveTmuxSession(for: sessionId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
        guard let rebuilt = tmuxResolver.buildAttachExecCommand(
            for: sessionId,
            selection: selection,
            workingDirectory: workingDirectory,
            backend: backend
        ) else {
            return
        }

        await tmuxService.sendScript(rebuilt, using: client, shellId: shellId)
    }

    @discardableResult
    func requestTmuxLifecycle(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) -> UUID {
        if let request = tmuxLifecycleRequestStore.removeMappedRequest(forScope: sessionId) {
            request.task.cancel()
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tmuxLifecycleRequestStore.remove(id: requestID, ifMappedTo: sessionId)
            }

            guard !Task.isCancelled else { return }
            guard self.isCurrentTmuxLifecycleShell(sessionId: sessionId, client: client, shellId: shellId) else {
                return
            }

            #if DEBUG
            if let operation = self.tmuxLifecycleOperationForTesting {
                await operation(sessionId, serverId, shellId)
            } else {
                await self.handleTmuxLifecycle(sessionId: sessionId, serverId: serverId, client: client, shellId: shellId)
            }
            #else
            await self.handleTmuxLifecycle(sessionId: sessionId, serverId: serverId, client: client, shellId: shellId)
            #endif
        }

        tmuxLifecycleRequestStore.insert(
            TmuxLifecycleRequest(
                sessionId: sessionId,
                serverId: serverId,
                shellId: shellId,
                task: task
            ),
            id: requestID,
            scopeID: sessionId
        )
        return requestID
    }

    func waitForTmuxLifecycleRequest(_ requestID: UUID) async {
        await tmuxLifecycleRequestStore[requestID]?.task.value
    }

    private func isCurrentTmuxLifecycleShell(
        sessionId: UUID,
        client: SSHClient,
        shellId: UUID
    ) -> Bool {
        guard let registration = shellRegistry.registration(for: sessionId) else { return false }
        return registration.shellId == shellId
            && ObjectIdentifier(registration.client) == ObjectIdentifier(client)
    }

    func tmuxStartupPlan(
        for sessionId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            disableTmuxAttachment(for: sessionId, status: .off)
            return (nil, true)
        }

        guard await client.supportsTmuxRuntime() else {
            disableTmuxAttachment(for: sessionId, status: .off)
            return (nil, true)
        }

        guard let backend = await tmuxService.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            disableTmuxAttachment(for: sessionId, status: tmuxResolver.unavailableStatus(for: serverId))
            return (nil, true)
        }

        let selection = await tmuxResolver.resolveSelection(
            for: sessionId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: sessionId, serverId: serverId, selection: selection, setPrompt: setTmuxAttachPrompt)

        if case .skipTmux = selection {
            updateTmuxStatus(sessionId, status: .off)
            return (nil, true)
        }

        await runTmuxCleanupIfNeeded(for: serverId, sessionId: sessionId, selection: selection, using: client)
        await prepareActiveTmuxSession(for: sessionId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
        return (
            tmuxStartupCommand(
                for: sessionId,
                selection: selection,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            true
        )
    }

    func startTmuxInstall(for sessionId: UUID) async {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updateTmuxStatus(sessionId, status: .installing)

        let preferred = tmuxResolver.multiplexer(for: serverId)
        guard let backend = await tmuxService.tmuxInstallBackend(using: registration.client, preferred: preferred) else {
            updateTmuxStatus(sessionId, status: .off)
            return
        }

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: registration.client)
        let terminalType = await registration.client.remoteTerminalType()
        let script = tmuxService.installAndAttachScript(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            backend: backend
        )
        await tmuxService.sendScript(script, using: registration.client, shellId: registration.shellId)

        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let available = await tmuxService.isTmuxAvailable(using: registration.client, preferred: preferred)
            if available {
                tmuxResolver.bindManagedSession(for: sessionId, serverId: serverId)
                updateTmuxStatus(sessionId, status: currentTmuxStatus(for: sessionId))
                return
            }
        }
        updateTmuxStatus(sessionId, status: tmuxResolver.unavailableStatus(for: serverId))
    }

    func installMoshServer(for sessionId: UUID) async throws {
        guard let registration = shellRegistry.registration(for: sessionId) else {
            throw SSHError.notConnected
        }
        try await moshService.installMoshServer(using: registration.client)
    }

    func managedTmuxSessionNameToKill(for sessionId: UUID, status: TmuxStatus) -> String? {
        guard status == .foreground || status == .background || status == .installing else { return nil }
        let ownership = tmuxResolver.sessionOwnership[sessionId] ?? .managed
        guard ownership == .managed else { return nil }
        return tmuxResolver.sessionName(for: sessionId)
    }

    func killTmuxIfNeeded(for sessionId: UUID) {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let ownership = tmuxResolver.sessionOwnership[sessionId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        let preferred = tmuxResolver.multiplexer(for: registration.serverId)
        trackTmuxKill(
            for: registration.serverId,
            sessionName: sessionName,
            client: registration.client,
            preferred: preferred
        )
    }

    func disableTmux(for serverId: UUID) {
        for index in sessions.indices where sessions[index].serverId == serverId {
            let sessionId = sessions[index].id
            setTmuxStatus(.off, for: sessionId)
            clearTmuxRuntimeState(for: sessionId)
        }
    }
}
