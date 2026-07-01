import Foundation

nonisolated enum IOSConnectionViewSelectionPolicy {
    static let terminalViewId = "terminal"

    static func preferredConnectViewId(
        isTerminalVisible: Bool,
        effectiveDefaultViewId: String
    ) -> String {
        isTerminalVisible ? terminalViewId : effectiveDefaultViewId
    }

    static func storedViewId(
        requestedViewId: String,
        isRequestedViewVisible: Bool,
        effectiveDefaultViewId: String
    ) -> String {
        isRequestedViewVisible ? requestedViewId : effectiveDefaultViewId
    }
}
