import Foundation

@MainActor
final class TmuxAttachResolver {
    typealias ServerProvider = @MainActor (UUID) -> Server?

    enum SessionOwnership {
        case managed
        case external
    }

    var sessionNames: [UUID: String] = [:]
    var sessionOwnership: [UUID: SessionOwnership] = [:]
    private var serverProvider: ServerProvider
    private var tmuxService: any TerminalTmuxServicing
    private var preferences: any TmuxAttachPreferenceProviding

    private let bindingStore = TmuxSessionBindingStore()

    init(
        serverProvider: @escaping ServerProvider,
        tmuxService: any TerminalTmuxServicing,
        preferences: any TmuxAttachPreferenceProviding
    ) {
        self.serverProvider = serverProvider
        self.tmuxService = tmuxService
        self.preferences = preferences
        // Hydrate persisted bindings so a chosen session survives an app restart.
        for (idString, binding) in bindingStore.allBindings() {
            guard let id = UUID(uuidString: idString) else { continue }
            sessionNames[id] = binding.sessionName
            sessionOwnership[id] = (binding.ownership == "managed") ? .managed : .external
        }
    }

    func setServerProvider(_ provider: @escaping ServerProvider) {
        serverProvider = provider
    }

    func setTmuxService(_ service: any TerminalTmuxServicing) {
        tmuxService = service
    }

    func setPreferences(_ preferences: any TmuxAttachPreferenceProviding) {
        self.preferences = preferences
    }

    private(set) var currentPrompt: TmuxAttachPrompt?
    private var promptQueue: [TmuxAttachPrompt] = []
    private var promptContinuations: [UUID: CheckedContinuation<TmuxAttachSelection, Never>] = [:]

    // MARK: - Settings

    var tmuxStartupBehaviorDefault: TmuxStartupBehavior {
        preferences.tmuxStartupBehaviorDefault
    }

    var multiplexerDefault: TerminalMultiplexer {
        preferences.multiplexerDefault
    }

    func multiplexer(for serverId: UUID) -> TerminalMultiplexer {
        if let server = serverProvider(serverId),
           let override = server.multiplexerOverride {
            return override
        }
        return multiplexerDefault
    }

    func isTmuxEnabled(for serverId: UUID) -> Bool {
        multiplexer(for: serverId).isEnabled
    }

    /// Status to show when the chosen multiplexer is enabled but not found on the host.
    /// tmux is installable (`.missing` surfaces an install prompt); zmx has no remote
    /// installer, so fall back to a plain shell (`.off`) rather than a dead-end prompt.
    func unavailableStatus(for serverId: UUID) -> TmuxStatus {
        multiplexer(for: serverId) == .zmx ? .off : .missing
    }

    func tmuxStartupBehavior(for serverId: UUID) -> TmuxStartupBehavior {
        guard let server = serverProvider(serverId) else {
            return tmuxStartupBehaviorDefault
        }
        if let override = server.tmuxStartupBehaviorOverride {
            return override
        }
        return tmuxStartupBehaviorDefault
    }

    // MARK: - Session Naming

    func managedSessionName(for entityId: UUID) -> String {
        "vvterm_\(DeviceIdentity.id)_\(entityId.uuidString)"
    }

    func sessionName(for entityId: UUID) -> String {
        sessionNames[entityId] ?? managedSessionName(for: entityId)
    }

    // MARK: - Attachment State

    func clearAttachmentState(for entityId: UUID) {
        sessionNames.removeValue(forKey: entityId)
        sessionOwnership.removeValue(forKey: entityId)
        bindingStore.remove(for: entityId)
    }

    func clearRuntimeState(for entityId: UUID, setPrompt: (TmuxAttachPrompt?) -> Void) {
        clearAttachmentState(for: entityId)
        if promptContinuations[entityId] != nil {
            resolvePrompt(entityId: entityId, selection: .skipTmux, setPrompt: setPrompt)
            return
        }
        if currentPrompt?.id == entityId {
            currentPrompt = nil
            advancePromptQueue(setPrompt: setPrompt)
        }
        promptQueue.removeAll { $0.id == entityId }
    }

    func updateAttachmentState(for entityId: UUID, serverId: UUID, selection: TmuxAttachSelection, setPrompt: (TmuxAttachPrompt?) -> Void) {
        switch selection {
        case .createManaged:
            let name = managedSessionName(for: entityId)
            sessionNames[entityId] = name
            sessionOwnership[entityId] = .managed
            persistBinding(for: entityId, serverId: serverId, name: name, ownership: .managed)
        case .attachExisting(let name):
            sessionNames[entityId] = name
            let own = ownership(for: name)
            sessionOwnership[entityId] = own
            persistBinding(for: entityId, serverId: serverId, name: name, ownership: own)
        case .skipTmux:
            clearRuntimeState(for: entityId, setPrompt: setPrompt)
        }
    }

    private func persistBinding(for entityId: UUID, serverId: UUID, name: String, ownership: SessionOwnership) {
        // The backend kind is also resolved live from the server at attach time; we store
        // it here so the persisted binding is self-describing.
        bindingStore.set(
            TmuxSessionBinding(
                sessionName: name,
                ownership: ownership == .managed ? "managed" : "external",
                multiplexer: multiplexer(for: serverId).rawValue
            ),
            for: entityId
        )
    }

    /// Bind a pane to its managed session and persist it (used after a successful install).
    func bindManagedSession(for entityId: UUID, serverId: UUID) {
        let name = managedSessionName(for: entityId)
        sessionNames[entityId] = name
        sessionOwnership[entityId] = .managed
        persistBinding(for: entityId, serverId: serverId, name: name, ownership: .managed)
    }

    // MARK: - Selection Resolution

    func resolveSelection(
        for entityId: UUID,
        serverId: UUID,
        client: SSHClient,
        setPrompt: @escaping (TmuxAttachPrompt?) -> Void
    ) async -> TmuxAttachSelection {
        // On reconnect, reuse the previous session choice for this tab/pane
        if let existingName = sessionNames[entityId],
           let ownership = sessionOwnership[entityId] {
            switch ownership {
            case .managed:
                return .createManaged
            case .external:
                let sessions = await listSessions(serverId: serverId, client: client)
                if sessions.contains(where: { $0.name == existingName }) {
                    return .attachExisting(sessionName: existingName)
                }
                // Session no longer exists, fall through to normal resolution
                sessionNames.removeValue(forKey: entityId)
                sessionOwnership.removeValue(forKey: entityId)
            }
        }

        let behavior = tmuxStartupBehavior(for: serverId)

        switch behavior {
        case .vvtermManaged:
            return .createManaged
        case .skipTmux:
            return .skipTmux
        case .askEveryTime:
            let sessions = await listSessions(serverId: serverId, client: client)
            return await requestSelection(
                entityId: entityId,
                serverId: serverId,
                availableSessions: sessionInfosForPrompt(from: sessions),
                setPrompt: setPrompt
            )
        }
    }

    /// List sessions using the backend that matches the server's chosen multiplexer
    /// (so a zmx server lists zmx sessions, not tmux).
    private func listSessions(serverId: UUID, client: SSHClient) async -> [RemoteTmuxSession] {
        guard let backend = await tmuxService.tmuxBackend(
            using: client,
            preferred: multiplexer(for: serverId)
        ) else {
            return []
        }
        return await tmuxService.listSessions(using: client, backend: backend)
    }

    // MARK: - Prompt Queue

    func resolvePrompt(entityId: UUID, selection: TmuxAttachSelection, setPrompt: (TmuxAttachPrompt?) -> Void) {
        guard let continuation = promptContinuations.removeValue(forKey: entityId) else { return }

        if currentPrompt?.id == entityId {
            currentPrompt = nil
            continuation.resume(returning: selection)
            advancePromptQueue(setPrompt: setPrompt)
            return
        }

        promptQueue.removeAll { $0.id == entityId }
        continuation.resume(returning: selection)
    }

    func cancelPrompt(entityId: UUID, setPrompt: (TmuxAttachPrompt?) -> Void) {
        resolvePrompt(entityId: entityId, selection: .skipTmux, setPrompt: setPrompt)
    }

    // MARK: - Cleanup

    func runCleanupIfNeeded(
        serverId: UUID,
        cleanupSet: inout Set<UUID>,
        managedNames: Set<String>,
        using client: SSHClient
    ) async {
        guard !cleanupSet.contains(serverId) else { return }
        cleanupSet.insert(serverId)
        let preferred = multiplexer(for: serverId)
        await tmuxService.cleanupLegacySessions(using: client)
        await tmuxService.cleanupDetachedSessions(
            deviceId: DeviceIdentity.id,
            keeping: managedNames,
            using: client,
            preferred: preferred
        )
    }

    // MARK: - Command Building

    func buildAttachCommand(
        for entityId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return tmuxService.startupAttachCommand(
                sessionName: sessionName(for: entityId),
                workingDirectory: workingDirectory,
                backend: backend
            )
        case .attachExisting(let name):
            return tmuxService.startupAttachExistingCommand(
                sessionName: name,
                backend: backend
            )
        }
    }

    func buildAttachExecCommand(
        for entityId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return tmuxService.interactiveAttachCommand(
                sessionName: sessionName(for: entityId),
                workingDirectory: workingDirectory,
                backend: backend
            )
        case .attachExisting(let name):
            return tmuxService.interactiveAttachExistingCommand(sessionName: name, backend: backend)
        }
    }

    // MARK: - Filtering

    func sessionInfosForPrompt(from sessions: [RemoteTmuxSession]) -> [TmuxAttachSessionInfo] {
        let filtered = sessions.filter { !isInternalSessionName($0.name) || $0.attachedClients > 0 }
        let source = filtered.isEmpty ? sessions : filtered
        return source.map {
            TmuxAttachSessionInfo(
                name: $0.name,
                attachedClients: max(0, $0.attachedClients),
                windowCount: max(1, $0.windowCount)
            )
        }
    }

    func isInternalSessionName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasPrefix("vvterm_")
            || lowercased.hasPrefix("vvterm-")
            || lowercased.hasPrefix("vivyterm_")
            || lowercased.hasPrefix("vivyterm-")
    }

    func isCurrentDeviceManagedSessionName(_ name: String) -> Bool {
        name.hasPrefix("vvterm_\(DeviceIdentity.id)_")
    }

    // MARK: - Private

    private func requestSelection(
        entityId: UUID,
        serverId: UUID,
        availableSessions: [TmuxAttachSessionInfo],
        setPrompt: @escaping (TmuxAttachPrompt?) -> Void
    ) async -> TmuxAttachSelection {
        let serverName = serverProvider(serverId)?.name ?? String(localized: "Server")
        let prompt = TmuxAttachPrompt(
            id: entityId,
            serverId: serverId,
            serverName: serverName,
            existingSessions: availableSessions
        )

        return await withCheckedContinuation { continuation in
            enqueuePrompt(prompt, continuation: continuation, setPrompt: setPrompt)
        }
    }

    private func enqueuePrompt(
        _ prompt: TmuxAttachPrompt,
        continuation: CheckedContinuation<TmuxAttachSelection, Never>,
        setPrompt: (TmuxAttachPrompt?) -> Void
    ) {
        promptContinuations[prompt.id] = continuation
        if currentPrompt == nil {
            currentPrompt = prompt
            setPrompt(prompt)
        } else {
            promptQueue.append(prompt)
        }
    }

    private func advancePromptQueue(setPrompt: (TmuxAttachPrompt?) -> Void) {
        guard currentPrompt == nil, !promptQueue.isEmpty else {
            setPrompt(currentPrompt)
            return
        }
        currentPrompt = promptQueue.removeFirst()
        setPrompt(currentPrompt)
    }

    private func ownership(for sessionName: String) -> SessionOwnership {
        isCurrentDeviceManagedSessionName(sessionName) ? .managed : .external
    }
}
