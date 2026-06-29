import Foundation

nonisolated enum ServerTransportSelection: String, CaseIterable, Identifiable, Equatable {
    case standard
    case tailscale
    case mosh
    case cloudflare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return String(localized: "SSH")
        case .tailscale:
            return String(localized: "Tailscale")
        case .mosh:
            return String(localized: "Mosh")
        case .cloudflare:
            return String(localized: "Cloudflare")
        }
    }

    var icon: String {
        switch self {
        case .standard:
            return "terminal"
        case .tailscale:
            return "network"
        case .mosh:
            return "antenna.radiowaves.left.and.right"
        case .cloudflare:
            return "shield.lefthalf.filled"
        }
    }

    var connectionMode: SSHConnectionMode {
        switch self {
        case .standard:
            return .standard
        case .tailscale:
            return .tailscale
        case .mosh:
            return .mosh
        case .cloudflare:
            return .cloudflare
        }
    }

    init(server: Server) {
        switch server.connectionMode {
        case .tailscale:
            self = .tailscale
        case .mosh:
            self = .mosh
        case .cloudflare:
            self = .cloudflare
        case .standard:
            self = .standard
        }
    }
}
