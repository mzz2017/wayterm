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

enum IOSTerminalViewPolicy {
    static let terminalViewId = "terminal"

    static func effectiveSelectedSessionId(
        selectedSessionId: UUID?,
        serverSessionIds: [UUID]
    ) -> UUID? {
        if let selectedSessionId, serverSessionIds.contains(selectedSessionId) {
            return selectedSessionId
        }
        return serverSessionIds.first
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
}
