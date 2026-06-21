import Foundation

enum TerminalAutoReconnectPolicy {
    static func shouldAttemptReconnect(
        isSceneActive: Bool,
        autoReconnectEnabled: Bool,
        reconnectInFlight: Bool,
        isSuspendingForBackground: Bool,
        connectionState: ConnectionState,
        hasLiveRuntime: Bool
    ) -> Bool {
        isSceneActive
            && autoReconnectEnabled
            && !reconnectInFlight
            && !isSuspendingForBackground
            && connectionState == .disconnected
            && !hasLiveRuntime
    }
}

enum TerminalManualReconnectPolicy {
    static func shouldAttemptReconnect(
        reconnectInFlight: Bool,
        snapshotState _: ConnectionState,
        hasLiveRuntime: Bool
    ) -> Bool {
        return !reconnectInFlight && !hasLiveRuntime
    }
}

enum TerminalConnectWatchdogAction {
    case none
    case retry
    case continueWatching
}

enum TerminalReconnectRequestResult {
    case skipped
    case credentialLoadFailed(String)
    case started(ServerCredentials)

    var isSkipped: Bool {
        if case .skipped = self {
            return true
        }
        return false
    }

    var credentials: ServerCredentials? {
        if case .started(let credentials) = self {
            return credentials
        }
        return nil
    }

    var errorMessage: String? {
        if case .credentialLoadFailed(let message) = self {
            return message
        }
        return nil
    }
}

enum TerminalCredentialLoadResult {
    case loaded(ServerCredentials)
    case failed(String)

    var credentials: ServerCredentials? {
        if case .loaded(let credentials) = self {
            return credentials
        }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }
}

struct TerminalForegroundReconnectAction: Equatable {
    let sessionId: UUID
    let shouldRefreshTerminal: Bool
    let shouldReconnect: Bool
    let shouldForceTerminalVisible: Bool
}

enum TerminalForegroundReconnectPolicy {
    static func action(
        selectedViewId: String,
        terminalViewId: String,
        selectedSessionId: UUID?,
        selectedSessionHasLiveRuntime: Bool,
        refreshTerminal: Bool,
        autoReconnectEnabled: Bool,
        isSuspendingForBackground: Bool
    ) -> TerminalForegroundReconnectAction? {
        guard selectedViewId == terminalViewId else { return nil }
        guard let selectedSessionId else { return nil }

        let canReconnect = autoReconnectEnabled
            && !isSuspendingForBackground
            && !selectedSessionHasLiveRuntime

        return TerminalForegroundReconnectAction(
            sessionId: selectedSessionId,
            shouldRefreshTerminal: refreshTerminal,
            shouldReconnect: canReconnect,
            shouldForceTerminalVisible: canReconnect
        )
    }
}
