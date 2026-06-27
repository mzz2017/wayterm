import Foundation
import os.log

extension TerminalTabManager {
    // MARK: - tmux Integration

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    func clearTmuxRuntimeState(for paneId: UUID) {
        tmuxResolver.clearRuntimeState(for: paneId, setPrompt: setTmuxAttachPrompt)
    }

    func resolveTmuxAttachPrompt(paneId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: paneId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(paneId: UUID) {
        tmuxResolver.cancelPrompt(entityId: paneId, setPrompt: setTmuxAttachPrompt)
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for tab in tabs(for: serverId) {
            for paneId in tab.allPaneIds {
                let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
                guard ownership == .managed else { continue }
                names.insert(tmuxResolver.sessionName(for: paneId))
            }
        }
        return names
    }

    private func tmuxSessionNamesToKeep(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedTmuxSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(tmuxResolver.sessionName(for: paneId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func currentTmuxStatus(for paneId: UUID, serverId: UUID) -> TmuxStatus {
        guard let tab = selectedTab(for: serverId) else { return .background }
        return (tab.id == selectedTabByServer[serverId] && tab.focusedPaneId == paneId) ? .foreground : .background
    }

    private func disableTmuxAttachment(for paneId: UUID, status: TmuxStatus) {
        tmuxResolver.clearAttachmentState(for: paneId)
        updatePaneTmuxStatus(paneId, status: status)
    }

    private func runTmuxCleanupIfNeeded(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient
    ) async {
        var cleanupSet = tmuxCleanupStore.serverIDs
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: tmuxSessionNamesToKeep(for: serverId, paneId: paneId, selection: selection),
            using: client
        )
        tmuxCleanupStore.replace(with: cleanupSet)
    }

    private func prepareActiveTmuxPane(
        for paneId: UUID,
        serverId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        updatePaneTmuxStatus(paneId, status: currentTmuxStatus(for: paneId, serverId: serverId))
        let terminalType = await client.remoteTerminalType()
        await tmuxService.prepareConfig(using: client, terminalType: terminalType, backend: backend)
    }

    private func immediateTmuxSelection(for paneId: UUID) -> TmuxAttachSelection {
        if tmuxResolver.sessionOwnership[paneId] == .external {
            return .attachExisting(sessionName: tmuxResolver.sessionName(for: paneId))
        }

        tmuxResolver.sessionNames[paneId] = tmuxResolver.managedSessionName(for: paneId)
        tmuxResolver.sessionOwnership[paneId] = .managed
        return .createManaged
    }

    private func tmuxStartupCommand(
        for paneId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return tmuxService.startupAttachCommand(
                sessionName: tmuxResolver.sessionName(for: paneId),
                workingDirectory: workingDirectory,
                backend: backend
            )
        case .attachExisting(let sessionName):
            return tmuxService.startupAttachExistingCommand(sessionName: sessionName, backend: backend)
        }
    }

    private func resolveTmuxWorkingDirectory(for paneId: UUID, using client: SSHClient) async -> String {
        if let seedPaneId = paneStates[paneId]?.seedPaneId,
           let path = await tmuxService.currentPath(
               sessionName: tmuxResolver.sessionName(for: seedPaneId),
               using: client
           ) {
            setPaneWorkingDirectory(path, for: paneId)
            return path
        }

        if let path = await tmuxService.currentPath(
            sessionName: tmuxResolver.sessionName(for: paneId),
            using: client
        ) {
            setPaneWorkingDirectory(path, for: paneId)
            return path
        }

        if let candidate = paneWorkingDirectory(for: paneId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
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
        for serverId in tabsByServer.keys {
            let tabsForServer = tabs(for: serverId)
            for tab in tabsForServer {
                updateTmuxFocus(for: tab)
            }
        }
    }

    func updateTmuxFocus(for tab: TerminalTab) {
        let isSelectedTab = selectedTabByServer[tab.serverId] == tab.id
        for paneId in tab.allPaneIds {
            guard let state = paneStates[paneId] else { continue }
            guard state.tmuxStatus == .foreground || state.tmuxStatus == .background else { continue }
            let newStatus: TmuxStatus = (isSelectedTab && tab.focusedPaneId == paneId) ? .foreground : .background
            if state.tmuxStatus != newStatus {
                setPaneTmuxStatus(newStatus, for: paneId)
            }
        }
    }

    func handleTmuxLifecycle(
        paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: .off)
            }
            return
        }

        guard await client.supportsTmuxRuntime() else {
            logger.info("Resolved remote environment does not support tmux runtime for pane \(paneId.uuidString, privacy: .public); using plain SSH shell")
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: .off)
            }
            return
        }

        guard let backend = await tmuxService.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: self.tmuxResolver.unavailableStatus(for: serverId))
            }
            return
        }

        let selection = immediateTmuxSelection(for: paneId)
        await runTmuxCleanupIfNeeded(for: serverId, paneId: paneId, selection: selection, using: client)
        await prepareActiveTmuxPane(for: paneId, serverId: serverId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        guard let command = tmuxResolver.buildAttachExecCommand(
            for: paneId,
            selection: selection,
            workingDirectory: workingDirectory,
            backend: backend
        ) else {
            return
        }

        await tmuxService.sendScript(command, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            disableTmuxAttachment(for: paneId, status: .off)
            return (nil, true)
        }

        guard await client.supportsTmuxRuntime() else {
            disableTmuxAttachment(for: paneId, status: .off)
            return (nil, true)
        }

        guard let backend = await tmuxService.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            disableTmuxAttachment(for: paneId, status: tmuxResolver.unavailableStatus(for: serverId))
            return (nil, true)
        }

        let selection = await tmuxResolver.resolveSelection(
            for: paneId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: paneId, serverId: serverId, selection: selection, setPrompt: setTmuxAttachPrompt)

        if case .skipTmux = selection {
            updatePaneTmuxStatus(paneId, status: .off)
            return (nil, true)
        }

        await runTmuxCleanupIfNeeded(for: serverId, paneId: paneId, selection: selection, using: client)
        await prepareActiveTmuxPane(for: paneId, serverId: serverId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        return (
            tmuxStartupCommand(
                for: paneId,
                selection: selection,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            true
        )
    }

    func startTmuxInstall(for paneId: UUID) async {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updatePaneTmuxStatus(paneId, status: .installing)

        let preferred = tmuxResolver.multiplexer(for: serverId)
        guard let backend = await tmuxService.tmuxInstallBackend(using: registration.client, preferred: preferred) else {
            updatePaneTmuxStatus(paneId, status: .off)
            return
        }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: registration.client)
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
                tmuxResolver.bindManagedSession(for: paneId, serverId: serverId)
                updatePaneTmuxStatus(paneId, status: currentTmuxStatus(for: paneId, serverId: serverId))
                return
            }
        }
        updatePaneTmuxStatus(paneId, status: tmuxResolver.unavailableStatus(for: serverId))
    }

    func installMoshServer(for paneId: UUID) async throws {
        guard let registration = shellRegistry.registration(for: paneId) else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    func managedTmuxSessionNameToKill(for paneId: UUID, status: TmuxStatus) -> String? {
        guard status == .foreground || status == .background || status == .installing else { return nil }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return nil }
        return tmuxResolver.sessionName(for: paneId)
    }

    func killTmuxIfNeeded(for paneId: UUID) {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        let preferred = tmuxResolver.multiplexer(for: registration.serverId)
        trackTmuxKill(
            for: registration.serverId,
            sessionName: sessionName,
            client: registration.client,
            preferred: preferred
        )
    }

    func disableTmux(for serverId: UUID) {
        for (paneId, state) in paneStates where state.serverId == serverId {
            setPaneTmuxStatus(.off, for: paneId)
            clearTmuxRuntimeState(for: paneId)
        }
    }
}
