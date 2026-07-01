import Foundation

enum RemoteFileConflictPolicy: String, Sendable {
    case replaceExisting
    case keepBoth
}

struct RemoteFileConflictResolution: Equatable, Sendable {
    let originalName: String
    let resolvedName: String
    let existingEntry: RemoteFileEntry?

    nonisolated var hasConflict: Bool {
        existingEntry != nil
    }
}
