import Foundation

extension TerminalTabManager {
    // MARK: - Pane Terminal Surface Lifecycle

    /// Register a terminal view for a pane.
    @discardableResult
    func registerTerminal(_ terminal: GhosttyTerminalView, for paneId: UUID) -> TerminalSurfaceRegistrationToken {
        let token = terminalSurfaceRegistry.register(terminal, for: .pane(paneId))
        scheduleTerminalRegistryVersionUpdate()
        return token
    }

    /// Unregister a terminal view.
    func unregisterTerminal(for paneId: UUID) {
        terminalSurfaceRegistry.removeSurface(for: .pane(paneId), cleanup: true)
        scheduleTerminalRegistryVersionUpdate()
    }

    private func scheduleTerminalRegistryVersionUpdate() {
        bumpTerminalRegistryVersion()
    }

    /// Get terminal for a pane.
    func getTerminal(for paneId: UUID) -> GhosttyTerminalView? {
        terminalSurfaceRegistry.surface(for: .pane(paneId))
    }

    func surfaceRegistrationToken(for paneId: UUID) -> TerminalSurfaceRegistrationToken? {
        terminalSurfaceRegistry.registrationToken(for: .pane(paneId))
    }

    func attachSurface(_ terminal: GhosttyTerminalView, toPane paneId: UUID) async {
        if terminalSurfaceRegistry.surface(for: .pane(paneId)) !== terminal {
            registerTerminal(terminal, for: paneId)
        }

        await startRuntimeIfNeeded(forPane: paneId, terminal: terminal)
    }

    @discardableResult
    func requestSurfaceAttach(
        paneId: UUID,
        terminal: GhosttyTerminalView,
        context: TerminalSurfaceAttachContext
    ) -> UUID? {
        if surfaceAttachRequestStore.requestID(forScope: paneId) != nil,
           shouldAcceptSurfaceReplacement(paneId: paneId, context: context) {
            registerTerminal(terminal, for: paneId)
        }

        return requestSurfaceAttach(
            paneId: paneId,
            context: context,
            attachOperation: { [weak self, weak terminal] in
                guard let self, let terminal else { return }
                await self.attachSurface(terminal, toPane: paneId)
            }
        )
    }

    private func shouldAcceptSurfaceReplacement(
        paneId: UUID,
        context: TerminalSurfaceAttachContext
    ) -> Bool {
        paneStates[paneId] != nil
            && context.isAppActive
            && context.isViewActive
    }

    @discardableResult
    func requestSurfaceAttach(
        paneId: UUID,
        context: TerminalSurfaceAttachContext,
        attachOperation: @escaping @MainActor () async -> Void
    ) -> UUID? {
        if let requestID = surfaceAttachRequestStore.requestID(forScope: paneId) {
            guard shouldAcceptSurfaceAttach(paneId: paneId, context: context) else {
                surfaceAttachRequestStore.update(requestID) { $0.context = context }
                return nil
            }
            surfaceAttachRequestStore.update(requestID) {
                $0.context = context
                $0.attachOperation = attachOperation
            }
            return requestID
        }

        guard shouldAcceptSurfaceAttach(paneId: paneId, context: context) else { return nil }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.surfaceAttachRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            let latestRequest = self.surfaceAttachRequestStore[requestID]
            let latestContext = latestRequest?.context ?? context
            guard self.shouldAcceptSurfaceAttach(paneId: paneId, context: latestContext) else { return }
            await (latestRequest?.attachOperation ?? attachOperation)()
        }

        surfaceAttachRequestStore.insert(
            SurfaceAttachRequest(
                paneId: paneId,
                context: context,
                attachOperation: attachOperation,
                task: task
            ),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    private func shouldAcceptSurfaceAttach(
        paneId: UUID,
        context: TerminalSurfaceAttachContext
    ) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        guard context.isAppActive, context.isViewActive else { return false }
        guard shellId(for: paneId) == nil else { return false }
        guard !isShellStartInFlight(for: paneId) else { return false }
        return true
    }

    func detachSurface(fromPane paneId: UUID, reason: TerminalSurfaceDetachReason) async {
        switch reason {
        case .viewDisappeared:
            detachSurfaceForPaneViewDisappeared(paneId)
        case .sessionClosed:
            detachSurfaceForClosedPane(paneId)
        }
    }

    @discardableResult
    func detachSurfaceForPaneViewDisappeared(
        _ paneId: UUID,
        surfaceToken: TerminalSurfaceRegistrationToken? = nil
    ) -> Bool {
        terminalSurfaceRegistry.detachSurface(
            for: .pane(paneId),
            matching: surfaceToken,
            cleanup: false
        )
    }

    func detachSurfaceForClosedPane(_ paneId: UUID) {
        unregisterTerminal(for: paneId)
    }

    func handlePaneSurfaceViewDisappeared(
        _ paneId: UUID,
        surfaceToken: TerminalSurfaceRegistrationToken? = nil
    ) -> TerminalSurfaceViewDisappearanceResolution {
        guard paneStates[paneId] == nil else {
            guard detachSurfaceForPaneViewDisappeared(paneId, surfaceToken: surfaceToken) else {
                return .staleSurfaceIgnored
            }
            return .preservedForReuse
        }

        detachSurfaceForClosedPane(paneId)
        return .closedAndCleanedUp
    }
}
