import Foundation
import os.log

extension ConnectionSessionManager {
    // MARK: - Terminal Registration (with LRU caching)

    func registerTerminal(_ terminal: GhosttyTerminalView, for sessionId: UUID) {
        // Evict oldest terminals if we're at capacity
        evictOldTerminalsIfNeeded()

        #if os(iOS)
        terminal.onKeyboardBrowseModeChange = { [weak self] isBrowsing in
            self?.setTerminalBrowseMode(isBrowsing, for: sessionId)
        }
        terminal.onFindNavigatorVisibilityChange = { [weak self] isVisible in
            self?.setTerminalFindNavigatorVisible(isVisible, for: sessionId)
        }
        #endif
        terminalSurfaceRegistry.register(terminal, for: .session(sessionId))
        #if os(iOS)
        guard terminalSurfaceRegistry.surface(for: .session(sessionId)) === terminal else { return }
        setTerminalBrowseMode(terminal.isKeyboardInBrowseMode, for: sessionId)
        setTerminalFindNavigatorVisible(terminal.isFindNavigatorVisible, for: sessionId)
        #endif

        logger.debug("Registered terminal for session, total: \(self.terminalSurfaceRegistry.count)/\(self.maxTerminals)")
    }

    func unregisterTerminal(for sessionId: UUID) {
        terminalSurfaceRegistry.removeSurface(for: .session(sessionId), cleanup: true)
        terminalsNeedingReconnectReset.remove(sessionId)
        terminalBrowseModeBySession.removeValue(forKey: sessionId)
        terminalFindNavigatorVisibleBySession.removeValue(forKey: sessionId)
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
            guard let serverId = sessionWithID(oldestId)?.serverId else { return }
            let unregisterTask = scheduleSSHUnregister(for: oldestId)
            let shellTeardownTask = cancelAndClearShellHandlers(for: oldestId)
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

    /// Marks an existing terminal as recently used without fetching it for body evaluation.
    func markTerminalUsed(for sessionId: UUID) {
        guard terminalSurfaceRegistry.hasSurface(for: .session(sessionId)) else { return }
        touchTerminal(sessionId)
    }

    func attachSurface(_ terminal: GhosttyTerminalView, to sessionId: UUID) async {
        if terminalSurfaceRegistry.surface(for: .session(sessionId)) !== terminal {
            registerTerminal(terminal, for: sessionId)
        }

        registerShellCancelHandler({ [weak self] mode in
            await self?.cancelRuntime(for: sessionId, mode: mode, cleanupTerminal: true)
        }, for: sessionId)
        registerShellSuspendHandler({ [weak self] in
            await self?.suspendRuntime(for: sessionId)
        }, for: sessionId)

        await startRuntimeIfNeeded(for: sessionId, terminal: terminal)
    }

    @discardableResult
    func requestSurfaceAttach(
        sessionId: UUID,
        terminal: GhosttyTerminalView,
        context: TerminalSurfaceAttachContext,
        resetTerminal: @escaping @MainActor () -> Void
    ) -> UUID? {
        requestSurfaceAttach(
            sessionId: sessionId,
            context: context,
            resetTerminal: resetTerminal,
            attachOperation: { [weak self, weak terminal] in
                guard let self, let terminal else { return }
                await self.attachSurface(terminal, to: sessionId)
            }
        )
    }

    @discardableResult
    func requestSurfaceAttach(
        sessionId: UUID,
        context: TerminalSurfaceAttachContext,
        resetTerminal: @escaping @MainActor () -> Void = {},
        attachOperation: @escaping @MainActor () async -> Void
    ) -> UUID? {
        if let requestID = surfaceAttachRequestStore.requestID(forScope: sessionId) {
            guard shouldAcceptSurfaceAttach(sessionId: sessionId, context: context) else {
                surfaceAttachRequestStore.update(requestID) { $0.context = context }
                return nil
            }
            surfaceAttachRequestStore.update(requestID) { $0.context = context }
            return requestID
        }

        guard shouldAcceptSurfaceAttach(sessionId: sessionId, context: context) else { return nil }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.surfaceAttachRequestStore.remove(id: requestID, ifMappedTo: sessionId)
            }

            let latestContext = self.surfaceAttachRequestStore[requestID]?.context ?? context
            guard self.shouldAcceptSurfaceAttach(sessionId: sessionId, context: latestContext) else { return }
            if self.consumeTerminalReconnectReset(for: sessionId) {
                resetTerminal()
            }
            await attachOperation()
        }

        surfaceAttachRequestStore.insert(
            SurfaceAttachRequest(sessionId: sessionId, context: context, task: task),
            id: requestID,
            scopeID: sessionId
        )
        return requestID
    }

    private func shouldAcceptSurfaceAttach(
        sessionId: UUID,
        context: TerminalSurfaceAttachContext
    ) -> Bool {
        guard let session = sessionWithID(sessionId) else { return false }
        guard context.isAppActive, context.isViewActive, !isSuspendingForBackground else { return false }
        guard shellId(for: session) == nil else { return false }
        guard !isShellStartInFlight(for: sessionId) else { return false }

        switch session.connectionState {
        case .connecting, .reconnecting, .connected:
            return true
        case .disconnected:
            return context.autoReconnectEnabled
        case .failed, .idle:
            return false
        }
    }

    func detachSurface(from sessionId: UUID, reason: TerminalSurfaceDetachReason) async {
        switch reason {
        case .viewDisappeared:
            detachSurfaceForViewDisappeared(from: sessionId)
        case .sessionClosed:
            detachSurfaceForClosedSession(sessionId)
        }
    }

    func detachSurfaceForViewDisappeared(from sessionId: UUID) {
        terminalSurfaceRegistry.detachSurface(for: .session(sessionId), cleanup: false)
    }

    func detachSurfaceForClosedSession(_ sessionId: UUID) {
        unregisterTerminal(for: sessionId)
    }

    func handleSurfaceViewDisappeared(
        sessionId: UUID,
        serverId: UUID,
        reason: String
    ) -> TerminalSurfaceViewDisappearanceResolution {
        guard sessionWithID(sessionId) == nil else {
            detachSurfaceForViewDisappeared(from: sessionId)
            return .preservedForReuse
        }

        handleClosedSessionSurfaceTeardown(
            sessionId: sessionId,
            serverId: serverId,
            reason: reason
        )
        return .closedAndCleanedUp
    }

    func prepareSurfaceForUpdate(
        sessionId: UUID,
        serverId: UUID,
        reason: String
    ) -> TerminalSurfaceUpdateDisposition {
        guard sessionWithID(sessionId) == nil else {
            return .continueUpdating
        }

        handleClosedSessionSurfaceTeardown(
            sessionId: sessionId,
            serverId: serverId,
            reason: reason
        )
        return .closedAndCleanedUp
    }

    func handleClosedSessionSurfaceTeardown(
        sessionId: UUID,
        serverId: UUID,
        reason: String
    ) {
        trackShellTeardownForClosedSession(
            sessionId: sessionId,
            serverId: serverId,
            reason: reason
        ) { [weak self] in
            self?.detachSurfaceForClosedSession(sessionId)
        }
    }
}
