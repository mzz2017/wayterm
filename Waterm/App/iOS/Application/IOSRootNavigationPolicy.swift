import Foundation

struct IOSRootNavigationState: Equatable {
    var isConnecting: Bool
    var connectingServerId: UUID?
    var sessionServerIds: [UUID]
}

enum IOSRootNavigationPolicy {
    static func hasTerminalNavigationContext(_ state: IOSRootNavigationState) -> Bool {
        state.isConnecting || state.connectingServerId != nil || !state.sessionServerIds.isEmpty
    }

    static func shouldDismissTerminal(
        isShowingTerminal: Bool,
        state: IOSRootNavigationState
    ) -> Bool {
        isShowingTerminal && !hasTerminalNavigationContext(state)
    }

    static func shouldDismissTerminalAfterSelectedSessionChange(
        isShowingTerminal: Bool,
        selectedSessionId: UUID?,
        state: IOSRootNavigationState
    ) -> Bool {
        isShowingTerminal && selectedSessionId == nil && !hasTerminalNavigationContext(state)
    }

    static func shouldClearConnectingState(_ state: IOSRootNavigationState) -> Bool {
        guard let connectingServerId = state.connectingServerId else { return false }
        return state.sessionServerIds.contains(connectingServerId)
    }
}
