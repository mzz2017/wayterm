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
