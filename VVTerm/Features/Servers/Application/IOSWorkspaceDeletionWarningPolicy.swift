import Foundation

nonisolated enum IOSWorkspaceDeletionWarningPolicy {
    static func warningText(serverCount: Int?) -> String {
        guard let serverCount else {
            return "This will delete the workspace and all servers in it. This cannot be undone."
        }
        if serverCount == 0 {
            return "This will delete the workspace. This cannot be undone."
        }
        if serverCount == 1 {
            return "This will delete the workspace and its 1 server. This cannot be undone."
        }
        return "This will delete the workspace and all \(serverCount) servers in it. This cannot be undone."
    }
}
