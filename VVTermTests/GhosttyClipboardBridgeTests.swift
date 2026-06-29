import Testing
@testable import VVTerm

// Test Context:
// These tests protect Ghostty clipboard FFI conversion. Ghostty passes clipboard
// entries as C structs with MIME and NUL-terminated data pointers; VVTerm should
// only turn textual entries into Swift strings for pasteboard writes. Fakes use
// local static C strings only and do not call libghostty.

struct GhosttyClipboardBridgeTests {
    @Test
    func stringDecodesTextualClipboardEntry() {
        // Given a Ghostty clipboard entry with a text MIME type.
        let result = withClipboardEntry(mime: "text/plain", data: "hello") { entry in
            GhosttyClipboardBridge.string(from: entry)
        }

        // Then the NUL-terminated C payload is decoded for Swift clipboard use.
        #expect(result == "hello")
    }

    @Test
    func stringSkipsNonTextualClipboardEntry() {
        // Given a Ghostty clipboard entry whose payload is not textual.
        let result = withClipboardEntry(mime: "image/png", data: "not-text") { entry in
            GhosttyClipboardBridge.string(from: entry)
        }

        // Then writeClipboard can continue scanning for a later textual entry
        // instead of copying binary data into the system pasteboard as text.
        #expect(result == nil)
    }

    @Test
    func stringReturnsNilWhenClipboardDataIsMissing() {
        // Given a Ghostty clipboard entry without a data pointer.
        let result = withClipboardEntry(mime: "text/plain", data: nil) { entry in
            GhosttyClipboardBridge.string(from: entry)
        }

        // Then the bridge fails closed at the FFI boundary.
        #expect(result == nil)
    }

    private func withClipboardEntry<Result>(
        mime: String?,
        data: String?,
        _ body: (ghostty_clipboard_content_s) -> Result
    ) -> Result {
        if let mime, let data {
            return mime.withCString { mimePointer in
                data.withCString { dataPointer in
                    body(ghostty_clipboard_content_s(mime: mimePointer, data: dataPointer))
                }
            }
        }

        if let mime {
            return mime.withCString { mimePointer in
                body(ghostty_clipboard_content_s(mime: mimePointer, data: nil))
            }
        }

        if let data {
            return data.withCString { dataPointer in
                body(ghostty_clipboard_content_s(mime: nil, data: dataPointer))
            }
        }

        return body(ghostty_clipboard_content_s(mime: nil, data: nil))
    }
}
