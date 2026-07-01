import Foundation
import Testing

// Test Context:
// These source-boundary tests protect Ghostty.App superfile control. Ghostty.App
// should own ghostty_app_t startup, cleanup, callbacks, and surface propagation,
// while reusable support values and pure config text generation live in focused
// bridge files. Update only when that ownership intentionally moves again.

@Suite(.serialized)
struct GhosttyAppSupportBoundaryTests {
    @Test
    func appFileDoesNotOwnSupportTypesOrPureConfigBuilder() throws {
        let root = try sourceRoot()
        let appSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App.swift")
        )
        let configBuilderSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.ConfigBuilder.swift")
        )
        let surfaceReferenceSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.SurfaceReference.swift")
        )
        let clipboardBridgeSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.ClipboardBridge.swift")
        )
        let clipboardCallbackSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App+Clipboard.swift")
        )

        // Given Ghostty.App is the app lifecycle and callback owner.
        #expect(appSource.contains("class App: ObservableObject"))
        #expect(appSource.contains("ghostty_app_new"))
        #expect(appSource.contains("ghostty_app_free"))

        // Then support types and pure config generation stay in focused files.
        #expect(
            !appSource.contains("enum ConfigBuilder"),
            "Ghostty.App.swift should not own pure Ghostty config text generation."
        )
        #expect(
            !appSource.contains("class SurfaceReference"),
            "Ghostty.App.swift should not own the surface registration reference type."
        )
        #expect(
            !appSource.contains("enum GhosttyClipboardBridge"),
            "Ghostty.App.swift should not own clipboard FFI support glue."
        )
        #expect(configBuilderSource.contains("enum ConfigBuilder"))
        #expect(configBuilderSource.contains("static func configContent"))
        #expect(surfaceReferenceSource.contains("final class SurfaceReference"))
        #expect(surfaceReferenceSource.contains("func invalidate()"))
        #expect(clipboardBridgeSource.contains("enum GhosttyClipboardBridge"))
        #expect(clipboardCallbackSource.contains("extension Ghostty.App"))
        #expect(clipboardCallbackSource.contains("static func readClipboard"))
        #expect(clipboardCallbackSource.contains("static func writeClipboard"))

        #expect(
            appSource.split(separator: "\n", omittingEmptySubsequences: false).count < 800,
            "Ghostty.App.swift should stay below the AGENTS.md superfile review threshold."
        )
    }

    @Test
    func appFileDocumentsClipboardAndUserdataFFILifetimeContracts() throws {
        let root = try sourceRoot()
        let appSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App.swift")
        )
        let clipboardBridgeSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.ClipboardBridge.swift")
        )

        #expect(appSource.contains("userdata: callbackContext.opaquePointer"))
        #expect(
            appSource.contains("private let callbackContext = GhosttyAppCallbackContext()"),
            "App-level userdata should be owned by an explicit invalidatable callback context."
        )
        #expect(
            clipboardBridgeSource.contains("enum GhosttyClipboardBridge"),
            "Clipboard C-string conversions should be isolated behind a named FFI bridge."
        )
        #expect(
            clipboardBridgeSource.contains("ghostty_surface_complete_clipboard_request copies the C string synchronously"),
            "Clipboard read completion should document why the temporary withCString pointer cannot escape."
        )
        #expect(
            clipboardBridgeSource.contains("Ghostty provides NUL-terminated clipboard payloads"),
            "Clipboard write conversion should document the NUL-termination contract behind String(cString:)."
        )
    }

    @Test
    func actionCallbackResolvesSurfaceContextOnMainActor() throws {
        let root = try sourceRoot()
        let appSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App.swift")
        )
        let actionContextSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App+ActionSurfaceContext.swift")
        )
        let actionPrefix = try sourceSlice(
            in: appSource,
            from: "static func action(_ app:",
            to: "            switch action.tag"
        )
        let scrollbarCase = try sourceSlice(
            in: appSource,
            from: "case GHOSTTY_ACTION_SCROLLBAR:",
            to: "                return true\n\n            case GHOSTTY_ACTION_MOUSE_SHAPE"
        )

        #expect(
            appSource.contains("dispatchActionSurfaceContext"),
            "Ghostty action callbacks should resolve app-owned surface registry state on the main actor."
        )
        #expect(
            !actionPrefix.contains("activeSurfaceCount()") && !actionPrefix.contains("terminalView(for:"),
            "Ghostty action callback entry must not read MainActor app surface registry before hopping to main."
        )
        #expect(
            actionPrefix.contains("GhosttyAppCallbackContext.context(fromUserdata: ghostty_app_userdata(app))")
                && actionPrefix.contains("GhosttySurfaceCallbackContext.context(fromSurface: surface)"),
            "Ghostty action callback entry should synchronously capture Swift callback contexts while raw C pointers are valid."
        )
        #expect(
            !actionContextSource.contains("ghostty_app_userdata")
                && !actionContextSource.contains("ghostty_surface_userdata"),
            "Deferred Ghostty action delivery must not dereference raw app/surface pointers after teardown may have freed them."
        )
        #expect(
            !actionContextSource.contains("liveSurfaceHandle")
                && !actionContextSource.contains("terminalView(for:"),
            "Deferred Ghostty action delivery should use the synchronously captured Swift surface context instead of re-reading raw surface handles."
        )
        #expect(
            scrollbarCase.contains("dispatchActionSurfaceContext")
                && scrollbarCase.contains("NotificationCenter.default.post("),
                "Scrollbar notifications should be posted from the main-actor action surface context."
        )
    }

    @Test
    func clipboardCallbacksRoutePasteboardAccessThroughMainActor() throws {
        let root = try sourceRoot()
        let clipboardCallbackSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App+Clipboard.swift")
        )
        let iosInputSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TerminalInput+iOS.swift")
        )
        let macOSInputSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/GhosttyTerminalView+macOS.swift")
        )
        let clipboardSource = try source(
            at: root.appendingPathComponent("Waterm/Core/Terminal/Clipboard.swift")
        )
        let readClipboardCallback = try sourceSlice(
            in: clipboardCallbackSource,
            from: "static func readClipboard(",
            to: "    private static func performClipboardReadOnMain("
        )
        let writeClipboardCallback = try sourceSlice(
            in: clipboardCallbackSource,
            from: "static func writeClipboard(",
            to: "\n}"
        )

        #expect(
            clipboardSource.contains("@MainActor\n    static func copy(_ text: String)")
                && clipboardSource.contains("@MainActor\n    static func readString() -> String?")
                && clipboardSource.contains("@MainActor\n    static func copy(lines: [String]"),
            "System pasteboard helpers should be main-actor isolated."
        )
        #expect(
            readClipboardCallback.contains("GhosttyClipboardBridge.consumeReadSnapshot")
                && !clipboardCallbackSource.contains("DispatchQueue.main.sync")
                && !readClipboardCallback.contains("let clipboardString = Clipboard.readString()"),
            "Ghostty read clipboard callbacks must consume UI-paste snapshots instead of synchronously blocking on main."
        )
        #expect(
            iosInputSource.contains("GhosttyClipboardBridge.publishReadSnapshot")
                && iosInputSource.contains("GhosttyClipboardBridge.clearReadSnapshot")
                && macOSInputSource.contains("GhosttyClipboardBridge.publishReadSnapshot"),
            "UI paste entry points should snapshot the main-actor pasteboard before entering Ghostty's synchronous paste action."
        )
        #expect(
            macOSInputSource.contains("GhosttyClipboardBridge.clearReadSnapshot"),
            "macOS paste should clear an unconsumed read snapshot after the synchronous Ghostty paste action returns."
        )
        #expect(
            writeClipboardCallback.contains("GhosttyClipboardBridge.firstString")
                && writeClipboardCallback.contains("DispatchQueue.main.async")
                && !writeClipboardCallback.contains("Clipboard.copy(string)"),
            "Ghostty write clipboard callbacks should snapshot C payloads before asynchronously copying on main."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceSlice(in source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw SourceRootError.notFound
        }
        guard let endRange = source[startRange.lowerBound...].range(of: end) else {
            throw SourceRootError.notFound
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
