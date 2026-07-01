import Foundation

extension ServerManager {
    static func defaultKnownHostRemoval(for candidates: [KnownHostRemovalCandidate]) async {
        await ServerKnownHostRemovalService.shared.removeKnownHosts(for: candidates)
    }
}
