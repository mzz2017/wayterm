import Foundation

nonisolated enum TerminalEntityConnectionState: Hashable, Sendable {
    case idle
    case connecting
    case reconnecting
    case authenticating
    case verifyingHostKey
    case startingShell
    case streaming
    case closing
    case suspended
    case disconnected
    case failed(String)

    var isOpening: Bool {
        switch self {
        case .connecting, .reconnecting, .authenticating, .verifyingHostKey, .startingShell:
            return true
        default:
            return false
        }
    }

    var isConnected: Bool {
        if case .streaming = self { return true }
        return false
    }

    var isClosing: Bool {
        if case .closing = self { return true }
        return false
    }

    var isTerminalReusable: Bool {
        switch self {
        case .streaming, .suspended, .disconnected:
            return true
        default:
            return false
        }
    }

    init(connectionState: ConnectionState) {
        switch connectionState {
        case .connecting:
            self = .connecting
        case .reconnecting:
            self = .reconnecting
        case .connected:
            self = .streaming
        case .disconnected, .idle:
            self = .disconnected
        case .failed(let message):
            self = .failed(message)
        }
    }
}
