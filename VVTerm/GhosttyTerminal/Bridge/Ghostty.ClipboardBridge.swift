import Foundation

enum GhosttyClipboardBridge {
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
}
