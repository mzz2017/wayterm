import Foundation

nonisolated enum GhosttyClipboardBridge {
    struct ReadSnapshot: @unchecked Sendable {
        let surface: ghostty_surface_t
        let string: String
        let createdAt: Date
    }

    private static let readSnapshotStore = GhosttyClipboardReadSnapshotStore()

    static func publishReadSnapshot(surface: ghostty_surface_t, string: String) {
        readSnapshotStore.publish(ReadSnapshot(surface: surface, string: string, createdAt: Date()))
    }

    static func consumeReadSnapshot(maxAge: TimeInterval = 1) -> ReadSnapshot? {
        readSnapshotStore.consume(maxAge: maxAge)
    }

    static func completeReadRequest(
        surface: ghostty_surface_t,
        string: String,
        state: UnsafeMutableRawPointer?
    ) {
        // ghostty_surface_complete_clipboard_request copies the C string synchronously before this call returns.
        string.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
    }

    static func string(from entry: ghostty_clipboard_content_s) -> String? {
        // Ghostty provides NUL-terminated clipboard payloads for text entries.
        guard let dataPointer = entry.data else { return nil }
        if let mimePointer = entry.mime {
            let mime = String(cString: mimePointer).lowercased()
            guard mime.hasPrefix("text/") else { return nil }
        }
        return String(cString: dataPointer)
    }

    static func firstString(
        in contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) -> String? {
        guard let contents, count > 0 else { return nil }
        for index in 0..<count {
            if let string = string(from: contents.advanced(by: index).pointee) {
                return string
            }
        }
        return nil
    }
}

nonisolated private final class GhosttyClipboardReadSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: GhosttyClipboardBridge.ReadSnapshot?

    nonisolated func publish(_ snapshot: GhosttyClipboardBridge.ReadSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    nonisolated func consume(maxAge: TimeInterval) -> GhosttyClipboardBridge.ReadSnapshot? {
        lock.lock()
        let snapshot = snapshot
        if let snapshot, Date().timeIntervalSince(snapshot.createdAt) <= maxAge {
            self.snapshot = nil
            lock.unlock()
            return snapshot
        }
        self.snapshot = nil
        lock.unlock()
        return nil
    }
}
