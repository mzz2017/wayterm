import Foundation
#if canImport(VVTermRemoteFilesDomain)
import VVTermRemoteFilesDomain
#endif

struct IOSFileTabTitleInput: Equatable, Identifiable {
    let id: UUID
    let serverId: UUID
    let seedPath: String?
    let lastKnownPath: String?
    let lastVisitedPath: String?
}

enum IOSFileTabTitlePolicy {
    static func baseTitle(for tab: IOSFileTabTitleInput, serverName: String?) -> String {
        let fallbackTitle = nonEmpty(serverName) ?? "/"
        let candidatePath = tab.lastVisitedPath ?? tab.lastKnownPath ?? tab.seedPath

        guard let candidatePath else {
            return fallbackTitle
        }

        let normalizedPath = RemoteFilePath.normalize(candidatePath)
        guard normalizedPath != "/" else {
            return fallbackTitle
        }

        return RemoteFilePath.breadcrumbs(for: normalizedPath).last?.title ?? fallbackTitle
    }

    static func displayedTitles(
        for tabs: [IOSFileTabTitleInput],
        serverName: String?
    ) -> [UUID: String] {
        let baseTitles = Dictionary(
            uniqueKeysWithValues: tabs.map { ($0.id, baseTitle(for: $0, serverName: serverName)) }
        )
        let titleCounts = Dictionary(grouping: baseTitles.values, by: { $0 }).mapValues(\.count)
        var seenCounts: [String: Int] = [:]
        var resolvedTitles: [UUID: String] = [:]

        for tab in tabs {
            let baseTitle = baseTitles[tab.id] ?? (nonEmpty(serverName) ?? "/")
            guard (titleCounts[baseTitle] ?? 0) > 1 else {
                resolvedTitles[tab.id] = baseTitle
                continue
            }

            seenCounts[baseTitle, default: 0] += 1
            resolvedTitles[tab.id] = "\(baseTitle) (\(seenCounts[baseTitle, default: 0]))"
        }

        return resolvedTitles
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
