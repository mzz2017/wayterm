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
        let scope = TerminalOpenRequestScope(serverId: server.id, kind: .tabOpen)
        if let requestID = tabOpenRequestStore.requestID(forScope: scope) {
            tabOpenRequestStore.update(requestID) { request in
                request.selectTerminalViewOnSuccess = request.selectTerminalViewOnSuccess || selectTerminalViewOnSuccess
                request.onOpened.append(onOpened)
                request.onFailed.append(onFailed)
            }
            return requestID
        }

        let requestID = UUID()
        lastTabOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tabOpenRequestStore.remove(id: requestID) }

            do {
                let tab = try await self.openTab(for: server)
                let request = self.tabOpenRequestStore[requestID]
                if request?.selectTerminalViewOnSuccess == true {
                    self.selectedViewByServer[server.id] = self.defaultViewProvider()
                }
                request?.onOpened.forEach { $0(tab) }
            } catch is CancellationError {
                return
            } catch {
                self.lastTabOpenFailure = error
                self.tabOpenRequestStore[requestID]?.onFailed.forEach { $0(error) }
            }
        }

        tabOpenRequestStore.insert(
            TabOpenRequest(
                serverId: server.id,
                task: task,
                selectTerminalViewOnSuccess: selectTerminalViewOnSuccess,
                onOpened: [onOpened],
                onFailed: [onFailed]
            ),
            id: requestID,
            scope: scope
        )
        return requestID
    }

    @discardableResult
    func requestServerTerminalOpen(
        for server: Server,
        selectTerminalViewOnSuccess: Bool = false,
        onOpened: @escaping @MainActor (TerminalTab) -> Void = { _ in },
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let scope = TerminalOpenRequestScope(serverId: server.id, kind: .serverTerminalOpen)
        if let requestID = tabOpenRequestStore.requestID(forScope: scope) {
            tabOpenRequestStore.update(requestID) { request in
                request.selectTerminalViewOnSuccess = request.selectTerminalViewOnSuccess || selectTerminalViewOnSuccess
                request.onOpened.append(onOpened)
                request.onFailed.append(onFailed)
            }
            return requestID
        }

        let requestID = UUID()
        lastTabOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tabOpenRequestStore.remove(id: requestID) }

            do {
                guard await self.serverUnlocker(server) else {
                    throw WatermError.authenticationFailed
                }

                if let tab = self.selectedTab(for: server.id) ?? self.tabs(for: server.id).first {
                    let request = self.tabOpenRequestStore[requestID]
                    if request?.selectTerminalViewOnSuccess == true {
                        self.selectedViewByServer[server.id] = self.defaultViewProvider()
                    }
                    request?.onOpened.forEach { $0(tab) }
                    return
                }

                let tab = try await self.openTab(for: server, shouldEnsureUnlocked: false)
                let request = self.tabOpenRequestStore[requestID]
                if request?.selectTerminalViewOnSuccess == true {
                    self.selectedViewByServer[server.id] = self.defaultViewProvider()
                }
                request?.onOpened.forEach { $0(tab) }
            } catch is CancellationError {
                return
            } catch {
                self.lastTabOpenFailure = error
                self.tabOpenRequestStore[requestID]?.onFailed.forEach { $0(error) }
            }
        }

        tabOpenRequestStore.insert(
            TabOpenRequest(
                serverId: server.id,
                task: task,
                selectTerminalViewOnSuccess: selectTerminalViewOnSuccess,
                onOpened: [onOpened],
                onFailed: [onFailed]
            ),
            id: requestID,
            scope: scope
        )
        return requestID
    }

    func waitForTabOpenRequest(_ requestID: UUID) async {
        await tabOpenRequestStore[requestID]?.task.value
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
            throw WatermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        defer { tabOpenRequestStore.finishOpen(forScope: server.id) }

        if shouldEnsureUnlocked {
            guard await serverUnlocker(server) else {
                throw WatermError.authenticationFailed
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
