import Foundation

enum RemoteFileDropPolicy {
    struct MovePlan: Equatable, Sendable {
        let entry: RemoteFileEntry
        let sourcePath: String
        let destinationPath: String
    }

    enum Plan: Sendable {
        case move([MovePlan])
        case copy(sourceServerId: UUID, entries: [RemoteFileEntry])
    }

    static func uniquePayloads(from payloads: [RemoteFileDragPayload]) throws -> [RemoteFileDragPayload] {
        var seenPaths: Set<String> = []
        let uniquePayloads: [RemoteFileDragPayload] = payloads.compactMap { payload in
            let uniqueEntries = payload.entries.filter { entry in
                seenPaths.insert(entry.path).inserted
            }
            guard !uniqueEntries.isEmpty else { return nil }
            return RemoteFileDragPayload(serverId: payload.serverId, entries: uniqueEntries)
        }

        guard !uniquePayloads.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid remote items were dropped."))
        }
        return uniquePayloads
    }

    static func plan(
        payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        destinationServerId: UUID
    ) throws -> Plan {
        let uniquePayloads = try uniquePayloads(from: payloads)
        let sourceServerIDs = Set(uniquePayloads.map(\.serverId))
        guard sourceServerIDs.count == 1, let sourceServerId = sourceServerIDs.first else {
            throw RemoteFileBrowserError.failed(
                String(localized: "A single drop can only contain items from one remote server.")
            )
        }

        let uniqueEntries = uniquePayloads.flatMap(\.entries)
        if sourceServerId == destinationServerId {
            return .move(try movePlans(for: uniqueEntries, to: destinationDirectoryPath))
        }

        return .copy(sourceServerId: sourceServerId, entries: uniqueEntries)
    }

    static func movePlans(
        for payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String
    ) throws -> [MovePlan] {
        let uniqueEntries = try uniquePayloads(from: payloads).flatMap(\.entries)
        return try movePlans(for: uniqueEntries, to: destinationDirectoryPath)
    }

    private static func movePlans(
        for entries: [RemoteFileEntry],
        to destinationDirectoryPath: String
    ) throws -> [MovePlan] {
        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        return try entries.compactMap { entry in
            let destinationPath = RemoteFilePath.appending(entry.name, to: destinationDirectory)
            guard destinationPath != entry.path else { return nil }

            if entry.type == .directory {
                let normalizedSource = RemoteFilePath.normalize(entry.path)
                if destinationDirectory == normalizedSource || destinationDirectory.hasPrefix(normalizedSource + "/") {
                    throw RemoteFileBrowserError.failed(
                        String(localized: "A folder cannot be moved into itself or one of its descendants.")
                    )
                }
            }

            return MovePlan(
                entry: entry,
                sourcePath: entry.path,
                destinationPath: destinationPath
            )
        }
    }
}
