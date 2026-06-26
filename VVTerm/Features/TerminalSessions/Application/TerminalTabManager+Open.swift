import Foundation
import os.log

extension TerminalTabManager {
    @discardableResult
    func requestTabOpen(
        for server: Server,
        selectTerminalViewOnSuccess: Bool = false,
        onOpened: @escaping @MainActor (TerminalTab) -> Void = { _ in },
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let requestID = UUID()
        lastTabOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tabOpenRequestStore.remove(id: requestID) }

            do {
                let tab = try await self.openTab(for: server)
                if selectTerminalViewOnSuccess {
                    self.selectedViewByServer[server.id] = self.defaultViewProvider()
                }
                onOpened(tab)
            } catch is CancellationError {
                return
            } catch {
                self.lastTabOpenFailure = error
                onFailed(error)
            }
        }

        tabOpenRequestStore.insert(task, id: requestID)
        return requestID
    }

    @discardableResult
    func requestServerTerminalOpen(
        for server: Server,
        selectTerminalViewOnSuccess: Bool = false,
        onOpened: @escaping @MainActor (TerminalTab) -> Void = { _ in },
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let requestID = UUID()
        lastTabOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tabOpenRequestStore.remove(id: requestID) }

            do {
                guard await self.serverUnlocker(server) else {
                    throw VVTermError.authenticationFailed
                }

                if let tab = self.selectedTab(for: server.id) ?? self.tabs(for: server.id).first {
                    if selectTerminalViewOnSuccess {
                        self.selectedViewByServer[server.id] = self.defaultViewProvider()
                    }
                    onOpened(tab)
                    return
                }

                let tab = try await self.openTab(for: server, shouldEnsureUnlocked: false)
                if selectTerminalViewOnSuccess {
                    self.selectedViewByServer[server.id] = self.defaultViewProvider()
                }
                onOpened(tab)
            } catch is CancellationError {
                return
            } catch {
                self.lastTabOpenFailure = error
                onFailed(error)
            }
        }

        tabOpenRequestStore.insert(task, id: requestID)
        return requestID
    }

    func waitForTabOpenRequest(_ requestID: UUID) async {
        await tabOpenRequestStore[requestID]?.value
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) async throws -> TerminalTab {
        try await openTab(for: server, shouldEnsureUnlocked: true)
    }

    @discardableResult
    private func openTab(for server: Server, shouldEnsureUnlocked: Bool) async throws -> TerminalTab {
        await waitForServerTeardownTasks(server.id)

        if !tabOpenRequestStore.beginOpen(forScope: server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        defer { tabOpenRequestStore.finishOpen(forScope: server.id) }

        if shouldEnsureUnlocked {
            guard await serverUnlocker(server) else {
                throw VVTermError.authenticationFailed
            }
        }

        let tab = TerminalTab(serverId: server.id, title: server.name)

        let sourcePaneId = selectedTab(for: server.id)?.focusedPaneId
        let sourceWorkingDirectory = sourcePaneId
            .flatMap { paneStates[$0]?.workingDirectory }

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var rootState = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: server.id
        )
        rootState.workingDirectory = sourceWorkingDirectory
        rootState.seedPaneId = sourcePaneId
        rootState.tmuxStatus = tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off
        paneStates[tab.rootPaneId] = rootState

        // Now update tabs (triggers @Published, view will have state ready)
        var serverTabs = tabsByServer[server.id] ?? []
        serverTabs.append(tab)
        tabsByServer[server.id] = serverTabs

        // Select the new tab
        selectedTabByServer[server.id] = tab.id

        logger.info("Opened new tab for \(server.name), pane: \(tab.rootPaneId)")
        return tab
    }
}
