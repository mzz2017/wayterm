import Foundation
import os.log

extension ConnectionSessionManager {
    // MARK: - Terminal Registration (with LRU caching)

    func registerTerminal(_ terminal: GhosttyTerminalView, for sessionId: UUID) {
        // Evict oldest terminals if we're at capacity
        evictOldTerminalsIfNeeded()

        #if os(iOS)
        terminal.onKeyboardBrowseModeChange = { [weak self] isBrowsing in
            Task { @MainActor [weak self] in
                self?.setTerminalBrowseMode(isBrowsing, for: sessionId)
            }
        }
        terminal.onFindNavigatorVisibilityChange = { [weak self] isVisible in
            Task { @MainActor [weak self] in
                self?.setTerminalFindNavigatorVisible(isVisible, for: sessionId)
            }
        }
        #endif
        terminalSurfaceRegistry.register(terminal, for: .session(sessionId))
        #if os(iOS)
        Task { @MainActor [weak self, weak terminal] in
            guard let self, let terminal, self.terminalSurfaceRegistry.surface(for: .session(sessionId)) === terminal else { return }
            self.setTerminalBrowseMode(terminal.isKeyboardInBrowseMode, for: sessionId)
            self.setTerminalFindNavigatorVisible(terminal.isFindNavigatorVisible, for: sessionId)
        }
        #endif

        logger.debug("Registered terminal for session, total: \(self.terminalSurfaceRegistry.count)/\(self.maxTerminals)")
    }

    func unregisterTerminal(for sessionId: UUID) {
        terminalSurfaceRegistry.removeSurface(for: .session(sessionId), cleanup: true)
        terminalsNeedingReconnectReset.remove(sessionId)
        #if os(iOS)
        Task { @MainActor [weak self] in
            self?.terminalBrowseModeBySession.removeValue(forKey: sessionId)
            self?.terminalFindNavigatorVisibleBySession.removeValue(forKey: sessionId)
        }
        #else
        terminalBrowseModeBySession.removeValue(forKey: sessionId)
        terminalFindNavigatorVisibleBySession.removeValue(forKey: sessionId)
        #endif
        logger.debug("Unregistered terminal, remaining: \(self.terminalSurfaceRegistry.count)")
    }

    /// Update access order for LRU tracking.
    func touchTerminal(_ sessionId: UUID) {
        terminalSurfaceRegistry.touch(.session(sessionId))
    }

    func setTerminalBrowseMode(_ isBrowsing: Bool, for sessionId: UUID) {
        if terminalBrowseModeBySession[sessionId] != isBrowsing {
            terminalBrowseModeBySession[sessionId] = isBrowsing
        }
    }

    func setTerminalFindNavigatorVisible(_ isVisible: Bool, for sessionId: UUID) {
        if terminalFindNavigatorVisibleBySession[sessionId] != isVisible {
            terminalFindNavigatorVisibleBySession[sessionId] = isVisible
        }
    }

    /// Evict least recently used terminals if over capacity.
    func evictOldTerminalsIfNeeded() {
        let selectedEntityId = selectedSessionId.map(TerminalEntityID.session)
        terminalSurfaceRegistry.evictOldest(maxCount: maxTerminals, preserving: selectedEntityId) { [weak self] entityId in
            guard let self else { return }
            guard case .session(let oldestId) = entityId else { return }
            logger.info("Evicting oldest terminal to free memory (count: \(self.terminalSurfaceRegistry.count))")
            let unregisterTask = scheduleSSHUnregister(for: oldestId)
            let shellTeardownTask = cancelAndClearShellHandlers(for: oldestId)
            guard let serverId = sessionWithID(oldestId)?.serverId else { return }
            let teardownTask = Task(priority: .utility) {
                await unregisterTask.value
                await shellTeardownTask?.value
            }
            trackServerTeardownTask(teardownTask, for: serverId)
        }
    }

    func getTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        terminalSurfaceRegistry.accessedSurface(for: .session(sessionId))
    }

    /// Returns a terminal without mutating LRU state.
    func peekTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        terminalSurfaceRegistry.surface(for: .session(sessionId))
    }

    /// Returns whether a terminal exists without mutating LRU state.
    func hasTerminal(for sessionId: UUID) -> Bool {
        terminalSurfaceRegistry.hasSurface(for: .session(sessionId))
    }

    func markTerminalForReconnectReset(for sessionId: UUID) {
        terminalsNeedingReconnectReset.insert(sessionId)
    }

    func consumeTerminalReconnectReset(for sessionId: UUID) -> Bool {
        terminalsNeedingReconnectReset.remove(sessionId) != nil
    }
}
