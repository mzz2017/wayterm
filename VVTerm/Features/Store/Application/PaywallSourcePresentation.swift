import Foundation

extension PaywallSource {
    var paywallTitle: String {
        switch self {
        case .general, .settings, .sidebarBanner:
            return String(localized: "Upgrade to Pro")
        case .serverLimit:
            return String(localized: "Unlock unlimited servers")
        case .workspaceLimit:
            return String(localized: "Unlock unlimited workspaces")
        case .tabLimit:
            return String(localized: "Unlock simultaneous connections")
        case .fileTabLimit:
            return String(localized: "Unlock multiple file tabs")
        case .splitPane:
            return String(localized: "Unlock split panes")
        case .customEnvironment:
            return String(localized: "Unlock custom environments")
        case .snippetLimit:
            return String(localized: "Unlock unlimited custom actions")
        case .postFirstConnection:
            return String(localized: "You're connected")
        case .welcome:
            return String(localized: "VVTerm Pro")
        }
    }

    var paywallSubtitle: String {
        switch self {
        case .general, .settings, .sidebarBanner, .welcome:
            return String(localized: "Connect everywhere, without limits.")
        case .serverLimit:
            return String(localized: "Pro removes every limit on servers, tabs, and workspaces.")
        case .workspaceLimit:
            return String(localized: "Pro removes every limit on workspaces, servers, and tabs.")
        case .tabLimit:
            return String(localized: "Run all your servers side by side.")
        case .fileTabLimit:
            return String(localized: "Browse files on all your servers at once.")
        case .splitPane:
            return String(localized: "Split your terminal into multiple panes.")
        case .customEnvironment:
            return String(localized: "Organize servers with your own environments.")
        case .snippetLimit:
            return String(localized: "Keep every command one tap away.")
        case .postFirstConnection:
            return String(localized: "Free covers one machine. Pro works across all of them.")
        }
    }
}
