import Foundation

struct IOSTerminalSessionSnapshot: Equatable, Identifiable {
    let id: UUID
    let serverId: UUID
}

enum IOSTerminalPreparationAction: Equatable {
    case none
    case markVisible(UUID)
    case refreshExisting(UUID)
}

struct IOSTerminalForegroundReconnectAction: Equatable {
    let sessionId: UUID
    let shouldRefreshTerminal: Bool
    let shouldReconnect: Bool
    let shouldForceTerminalVisible: Bool
}

struct IOSTerminalRecoveredState: Equatable {
    let shouldShowZenPanel: Bool?
    let isZenModeEnabled: Bool?
    let requestedTerminalDismissal: Bool
    let shouldCallBack: Bool
}

struct IOSTerminalFloatingControlsVisibility: Equatable {
    let shouldShowControls: Bool
    let shouldShowVoiceButton: Bool
    let shouldShowReturnButton: Bool
}

enum IOSTerminalViewPolicy {
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
