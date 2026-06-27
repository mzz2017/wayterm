import Foundation
import os.log

extension TerminalTabManager {
    // MARK: - Tab and Pane Close Lifecycle

    /// Close a tab.
    func closeTab(_ tab: TerminalTab) {
        guard let closeResult = closeTabUI(tab) else { return }
        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishTabClose(closeResult)
        }
        trackServerTeardownTask(teardownTask, for: closeResult.serverId)
    }

    /// Close a tab and wait for every pane's SSH teardown to finish.
    func closeTabAndWait(_ tab: TerminalTab) async {
        await waitForServerTeardownTasks(tab.serverId)
        guard let closeResult = closeTabUI(tab) else { return }
        await finishTabClose(closeResult)
    }

    private func closeTabUI(_ tab: TerminalTab) -> TabCloseResult? {
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("closeTab: tab not found \(tab.id.uuidString, privacy: .public)")
            return nil
        }

        // Clean up all panes in this tab.
        let paneCloseResults = currentTab.allPaneIds.map { preparePaneClose($0) }

        if var serverTabs = tabsByServer[currentTab.serverId] {
            serverTabs.removeAll { $0.id == currentTab.id }
            tabsByServer[currentTab.serverId] = serverTabs

            if selectedTabByServer[currentTab.serverId] == currentTab.id {
                selectedTabByServer[currentTab.serverId] = serverTabs.first?.id
            }
        }

        terminalSessionEndRecorder(hasConnectedPanes, isProProvider())

        logger.info("Closed tab \(currentTab.id)")
        return TabCloseResult(
            serverId: currentTab.serverId,
            paneCloseResults: paneCloseResults
        )
    }

    /// Close all tabs for a server.
    func closeAllTabs(for serverId: UUID) {
        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            closeTab(tab)
        }
    }

    /// Disconnect all tabs for every server and wait for SSH teardown to finish.
    func disconnectAllAndWait() async {
        await waitForAllServerTeardownTasks()
        for serverId in Array(tabsByServer.keys) {
            await disconnectServerAndWait(serverId)
        }
        await waitForAllServerTeardownTasks()
    }

    /// Disconnect all tabs for a server and wait for SSH teardown to finish.
    func disconnectServerAndWait(_ serverId: UUID) async {
        await waitForServerTeardownTasks(serverId)
        let closeResults = tabs(for: serverId).compactMap { closeTabUI($0) }
        selectedViewByServer.removeValue(forKey: serverId)
        for closeResult in closeResults {
            await finishTabClose(closeResult)
        }
    }

    /// Close a pane within a tab.
    func closePane(tab: TerminalTab, paneId: UUID) {
        guard let closeResult = closePaneUI(tab: tab, paneId: paneId) else { return }
        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishTabClose(closeResult)
        }
        trackServerTeardownTask(teardownTask, for: closeResult.serverId)
    }

    /// Close a pane and wait for SSH teardown to finish.
    func closePaneAndWait(_ paneId: UUID) async {
        guard let state = paneStates[paneId],
              let tab = tabs(for: state.serverId).first(where: { $0.id == state.tabId }) else {
            return
        }
        await closePaneAndWait(tab: tab, paneId: paneId)
    }

    /// Close a pane and wait for SSH teardown to finish.
    func closePaneAndWait(tab: TerminalTab, paneId: UUID) async {
        await waitForServerTeardownTasks(tab.serverId)
        guard let closeResult = closePaneUI(tab: tab, paneId: paneId) else { return }
        await finishTabClose(closeResult)
    }

    private func closePaneUI(tab: TerminalTab, paneId: UUID) -> TabCloseResult? {
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("closePane: tab not found")
            return nil
        }

        guard let closePlan = TerminalTabClosePanePolicy.plan(tab: currentTab, paneId: paneId) else {
            logger.warning("closePane: pane not found \(paneId)")
            return nil
        }

        if closePlan == .closeTab {
            return closeTabUI(currentTab)
        }

        if case .closePane(let updatedTab) = closePlan {
            updateTab(updatedTab)
        }

        let paneCloseResult = preparePaneClose(paneId)
        logger.info("Closed pane \(paneId)")
        return TabCloseResult(
            serverId: currentTab.serverId,
            paneCloseResults: [paneCloseResult]
        )
    }

    /// Remove pane UI/runtime state and return the SSH teardown that must be awaited.
    func preparePaneClose(_ paneId: UUID) -> PaneCloseResult {
        let serverId = paneStates[paneId]?.serverId
        let tmuxSessionToKill = paneTmuxStatus(for: paneId)
            .flatMap { managedTmuxSessionNameToKill(for: paneId, status: $0) }

        if let serverId {
            terminalConnectionRegistry.updateState(
                .disconnected,
                for: .pane(paneId),
                serverId: serverId
            )
        }
        cancelInstallRequests(for: paneId)
        cancelPaneRetryRequest(for: paneId)
        cancelPaneHostRetrustRequest(for: paneId)
        cancelPaneCredentialLoadRequest(for: paneId)
        cancelInputRequests(for: paneId)
        let richPasteUploadTasks = cancelPaneRichPasteUploadRequests(for: paneId)
        cancelResizeRequests(for: paneId)
        cancelProcessExitRequests(for: paneId)
        clearTmuxRuntimeState(for: paneId)
        unregisterTerminal(for: paneId)
        paneStates.removeValue(forKey: paneId)
        runtimeTitleByPane.removeValue(forKey: paneId)

        return PaneCloseResult(
            paneId: paneId,
            tmuxSessionNameToKill: tmuxSessionToKill,
            richPasteUploadTasks: richPasteUploadTasks
        )
    }

    private func cancelInstallRequests(for paneId: UUID) {
        if let request = tmuxInstallRequestStore.removeMappedRequest(forScope: paneId) {
            request.task.cancel()
            request.onCompleted.forEach { $0() }
        }

        if let request = moshInstallRequestStore.removeMappedRequest(forScope: paneId) {
            request.task.cancel()
            request.onCompleted.forEach { $0() }
        }
    }

    private func cancelProcessExitRequests(for paneId: UUID) {
        processExitRequestStore.removeMappedRequest(forScope: paneId)?.task.cancel()
    }

    private func cancelPaneRetryRequest(for paneId: UUID) {
        if let request = paneRetryRequestStore.removeMappedRequest(forScope: paneId) {
            request.task.cancel()
            request.onCompleted.forEach { $0(.skipped) }
        }
    }

    private func cancelPaneHostRetrustRequest(for paneId: UUID) {
        if let request = paneHostRetrustRequestStore.removeMappedRequest(forScope: paneId) {
            request.task.cancel()
            request.onCompleted.forEach { $0(false) }
        }
    }

    private func cancelPaneCredentialLoadRequest(for paneId: UUID) {
        paneCredentialLoadRequestStore.removeScopeMapping(forScope: paneId)?.task.cancel()
    }

    private func finishTabClose(_ closeResult: TabCloseResult) async {
        for paneCloseResult in closeResult.paneCloseResults {
            await finishPaneClose(paneCloseResult)
        }
    }

    func finishPaneClose(_ closeResult: PaneCloseResult) async {
        for task in closeResult.richPasteUploadTasks {
            await task.value
        }

        if await closeTestingRuntimeIfNeeded(forPane: closeResult.paneId) {
            paneRuntimes.removeValue(forKey: closeResult.paneId)
        } else {
            await cancelRuntime(
                forPane: closeResult.paneId,
                mode: .fullDisconnect,
                cleanupTerminal: false,
                closeRegisteredShell: false
            )
        }

        await unregisterSSHClient(
            for: closeResult.paneId,
            killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
        )
    }

    func waitForServerTeardownTasks(_ serverId: UUID) async {
        while !serverTeardownTaskStore.tasks(forServer: serverId).isEmpty {
            for entry in serverTeardownTaskStore.tasks(forServer: serverId) {
                await entry.task.value
                finishServerTeardownTask(entry.id, for: serverId)
            }
        }
    }

    func waitForAllServerTeardownTasks() async {
        while !serverTeardownTaskStore.isEmpty {
            for serverId in serverTeardownTaskStore.serverIDs {
                await waitForServerTeardownTasks(serverId)
            }
        }
    }

    func trackServerTeardownTask(_ task: Task<Void, Never>, for serverId: UUID) {
        let taskId = serverTeardownTaskStore.insert(task, forServer: serverId)
        logger.info("Tracking tab teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), count: \(self.serverTeardownTaskStore.count(forServer: serverId))]")

        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.finishServerTeardownTask(taskId, for: serverId)
        }
    }

    private func finishServerTeardownTask(_ taskId: UUID, for serverId: UUID) {
        guard let remainingTasks = serverTeardownTaskStore.finish(taskId, forServer: serverId) else { return }
        logger.info("Finished tab teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), remaining: \(remainingTasks)]")
    }

    func trackShellCleanup(
        for serverId: UUID,
        reason: String,
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async -> Void
    ) {
#if DEBUG
        let testingOperation = rejectedShellCleanupOperationForTesting
#endif
        let task = Task.detached(priority: priority) { [logger] in
            logger.info("Pane shell cleanup started [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await operation()
            }
#else
            await operation()
#endif
            logger.info("Pane shell cleanup finished [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }

    func trackTmuxKill(
        for serverId: UUID,
        sessionName: String,
        client: SSHClient,
        preferred: TerminalMultiplexer
    ) {
#if DEBUG
        let testingOperation = tmuxKillOperationForTesting
#endif
        let tmuxService = tmuxService
        let task = Task.detached(priority: .utility) { [logger, tmuxService] in
            logger.info("Managed pane tmux kill started [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await tmuxService.killSession(named: sessionName, using: client, preferred: preferred)
            }
#else
            await tmuxService.killSession(named: sessionName, using: client, preferred: preferred)
#endif
            logger.info("Managed pane tmux kill finished [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }
}
