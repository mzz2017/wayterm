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
