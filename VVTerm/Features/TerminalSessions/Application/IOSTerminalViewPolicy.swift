import Foundation

nonisolated struct IOSTerminalSessionSnapshot: Equatable, Identifiable {
    let id: UUID
    let serverId: UUID
}

nonisolated enum IOSTerminalPreparationAction: Equatable {
    case none
    case markVisible(UUID)
    case refreshExisting(UUID)
}

nonisolated struct IOSTerminalForegroundReconnectAction: Equatable {
    let sessionId: UUID
    let shouldRefreshTerminal: Bool
    let shouldReconnect: Bool
    let shouldForceTerminalVisible: Bool
}

nonisolated struct IOSTerminalRecoveredState: Equatable {
    let shouldShowZenPanel: Bool?
    let isZenModeEnabled: Bool?
    let requestedTerminalDismissal: Bool
    let shouldCallBack: Bool
}

nonisolated struct IOSTerminalFloatingControlsVisibility: Equatable {
    let shouldShowControls: Bool
    let shouldShowVoiceButton: Bool
    let shouldShowReturnButton: Bool
}

nonisolated enum IOSTerminalViewPolicy {
    static let terminalViewId = "terminal"

    static func resolvedServerId(
        currentServerId: UUID?,
        selectedSessionServerId: UUID?,
        selectedServerId: UUID?,
        connectingServerId: UUID?
    ) -> UUID? {
        currentServerId
            ?? selectedSessionServerId
            ?? selectedServerId
            ?? connectingServerId
    }

    static func fileTabServerId(
        currentServerId: UUID?,
        selectedServerId: UUID?,
        connectingServerId: UUID?
    ) -> UUID? {
        currentServerId
            ?? selectedServerId
            ?? connectingServerId
    }

    static func canUseZenMode(
        isConnecting: Bool,
        hasSelectedServer: Bool,
        serverSessionCount: Int
    ) -> Bool {
        isConnecting || hasSelectedServer || serverSessionCount > 0
    }

    static func effectiveZenModeEnabled(
        isZenModeEnabled: Bool,
        canUseZenMode: Bool
    ) -> Bool {
        isZenModeEnabled && canUseZenMode
    }

    static func shouldShowViewSwitcher(visibleTabCount: Int) -> Bool {
        visibleTabCount > 1
    }

    static func effectiveSelectedSessionId(
        selectedSessionId: UUID?,
        serverSessionIds: [UUID]
    ) -> UUID? {
        if let selectedSessionId, serverSessionIds.contains(selectedSessionId) {
            return selectedSessionId
        }
        return serverSessionIds.first
    }

    static func recoveredSelectedSessionId(
        currentServerId: UUID?,
        selectedSessionId: UUID?,
        serverSessionIds: [UUID]
    ) -> UUID? {
        guard currentServerId != nil,
              let selectedSessionId,
              !serverSessionIds.contains(selectedSessionId) else {
            return nil
        }
        return serverSessionIds.first
    }

    static func prunedSessionState<Value>(
        _ stateBySession: [UUID: Value],
        activeSessionIds: Set<UUID>
    ) -> [UUID: Value] {
        stateBySession.filter { activeSessionIds.contains($0.key) }
    }

    static func terminalPreparation(
        sessionId: UUID,
        selectedViewId: String,
        terminalAlreadyExists: Bool,
        isTerminalAlreadyScheduled: Bool
    ) -> IOSTerminalPreparationAction {
        guard selectedViewId == terminalViewId else { return .none }
        if terminalAlreadyExists {
            return .refreshExisting(sessionId)
        }
        if isTerminalAlreadyScheduled {
            return .none
        }
        return .markVisible(sessionId)
    }

    static func foregroundReconnectAction(
        selectedViewId: String,
        selectedSession: IOSTerminalSessionSnapshot?,
        selectedSessionHasLiveRuntime: Bool,
        refreshTerminal: Bool,
        autoReconnectEnabled: Bool,
        isSuspendingForBackground: Bool
    ) -> IOSTerminalForegroundReconnectAction? {
        guard selectedViewId == terminalViewId else { return nil }
        guard let selectedSession else { return nil }

        let canReconnect = autoReconnectEnabled
            && !isSuspendingForBackground
            && !selectedSessionHasLiveRuntime

        return IOSTerminalForegroundReconnectAction(
            sessionId: selectedSession.id,
            shouldRefreshTerminal: refreshTerminal,
            shouldReconnect: canReconnect,
            shouldForceTerminalVisible: canReconnect
        )
    }

    static func recoveredTerminalState(
        canUseZenMode: Bool,
        requestedTerminalDismissal: Bool
    ) -> IOSTerminalRecoveredState {
        guard canUseZenMode else {
            return IOSTerminalRecoveredState(
                shouldShowZenPanel: false,
                isZenModeEnabled: false,
                requestedTerminalDismissal: true,
                shouldCallBack: !requestedTerminalDismissal
            )
        }

        return IOSTerminalRecoveredState(
            shouldShowZenPanel: nil,
            isZenModeEnabled: nil,
            requestedTerminalDismissal: false,
            shouldCallBack: false
        )
    }

    static func floatingControlsVisibility(
        isPhone: Bool,
        selectedViewId: String,
        isBrowseModeEnabled: Bool,
        isFindNavigatorVisible: Bool,
        isVoiceRecording: Bool,
        isVoiceButtonEnabled: Bool,
        hasPendingVoiceReturn: Bool
    ) -> IOSTerminalFloatingControlsVisibility {
        let shouldShowControls = isPhone
            && selectedViewId == terminalViewId
            && isBrowseModeEnabled
            && !isFindNavigatorVisible
            && !isVoiceRecording

        return IOSTerminalFloatingControlsVisibility(
            shouldShowControls: shouldShowControls,
            shouldShowVoiceButton: shouldShowControls && isVoiceButtonEnabled,
            shouldShowReturnButton: shouldShowControls && hasPendingVoiceReturn
        )
    }
}
