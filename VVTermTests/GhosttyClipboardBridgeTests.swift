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

    @Test
    func firstStringSnapshotsFirstTextualClipboardEntryBeforeCallbackReturns() {
        // Given a Ghostty clipboard callback payload with a non-text entry
        // before the textual entry. The C array is only stable during the
        // callback, so production must copy out a Swift String before any
        // deferred main-actor pasteboard handoff.
        let result = withClipboardEntries(
            [
                ClipboardEntryFixture(mime: "image/png", data: "not-text"),
                ClipboardEntryFixture(mime: "text/plain", data: "copied")
            ]
        ) { entries in
            GhosttyClipboardBridge.firstString(in: entries.baseAddress, count: entries.count)
        }

        // Then the bridge snapshots the first textual payload and ignores
        // earlier non-text entries.
        #expect(result == "copied")
    }

    @Test
    func readSnapshotIsConsumedOnceForMatchingSynchronousPasteCallback() {
        // Given UI paste has snapshotted the pasteboard before entering
        // Ghostty's synchronous paste_from_clipboard action.
        let surface = ghostty_surface_t(bitPattern: 0x1234)!
        GhosttyClipboardBridge.publishReadSnapshot(surface: surface, string: "paste me")

        // When the Ghostty read callback runs off the main actor.
        let snapshot = GhosttyClipboardBridge.consumeReadSnapshot(for: surface)
        let secondSnapshot = GhosttyClipboardBridge.consumeReadSnapshot(for: surface)

        // Then the callback can complete synchronously without asking the
        // blocked main thread for pasteboard access, and the snapshot cannot
        // be reused by a later unrelated clipboard read.
        #expect(snapshot?.surface == surface)
        #expect(snapshot?.string == "paste me")
        #expect(secondSnapshot == nil)
    }

    @Test
    func readSnapshotDoesNotCrossSurfaces() {
        // Given two terminal surfaces can paste concurrently or receive late
        // callbacks in different orders.
        let firstSurface = ghostty_surface_t(bitPattern: 0x1234)!
        let secondSurface = ghostty_surface_t(bitPattern: 0x5678)!
        GhosttyClipboardBridge.publishReadSnapshot(surface: firstSurface, string: "first paste")

        // When an unrelated Ghostty read callback arrives for another surface.
        let wrongSurfaceSnapshot = GhosttyClipboardBridge.consumeReadSnapshot(for: secondSurface)
        let matchingSnapshot = GhosttyClipboardBridge.consumeReadSnapshot(for: firstSurface)

        // Then the first surface's clipboard contents and raw surface handle
        // cannot be paired with the second surface's request state.
        #expect(wrongSurfaceSnapshot == nil)
        #expect(matchingSnapshot?.surface == firstSurface)
        #expect(matchingSnapshot?.string == "first paste")
    }

    @Test
    func clearingReadSnapshotPreventsStalePasteReuse() {
        // Given a paste action published a snapshot but returned without a
        // matching Ghostty read request.
        let surface = ghostty_surface_t(bitPattern: 0x1234)!
        GhosttyClipboardBridge.publishReadSnapshot(surface: surface, string: "stale paste")

        // When the UI paste action exits.
        GhosttyClipboardBridge.clearReadSnapshot(for: surface)

        // Then a later unrelated callback for the same raw surface address
        // cannot reuse the stale clipboard payload.
        #expect(GhosttyClipboardBridge.consumeReadSnapshot(for: surface) == nil)
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

    private func withClipboardEntries<Result>(
        _ fixtures: [ClipboardEntryFixture],
        _ body: (UnsafeBufferPointer<ghostty_clipboard_content_s>) -> Result
    ) -> Result {
        var strings: [String] = []
        var entries: [ghostty_clipboard_content_s] = []
        strings.reserveCapacity(fixtures.count * 2)
        entries.reserveCapacity(fixtures.count)

        for fixture in fixtures {
            let mimeIndex = fixture.mime.map { value -> Int in
                strings.append(value)
                return strings.count - 1
            }
            let dataIndex = fixture.data.map { value -> Int in
                strings.append(value)
                return strings.count - 1
            }
            entries.append(ghostty_clipboard_content_s(
                mime: mimeIndex.map { strings[$0] }.map { strdup($0) },
                data: dataIndex.map { strings[$0] }.map { strdup($0) }
            ))
        }
        defer {
            for entry in entries {
                free(UnsafeMutableRawPointer(mutating: entry.mime))
                free(UnsafeMutableRawPointer(mutating: entry.data))
            }
        }

        return entries.withUnsafeBufferPointer(body)
    }

    private struct ClipboardEntryFixture {
        let mime: String?
        let data: String?
    }
}
