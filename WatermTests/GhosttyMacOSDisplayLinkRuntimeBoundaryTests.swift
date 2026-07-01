import Foundation
import Testing

// Test Context:
// These source-boundary tests protect macOS Ghostty render-loop ownership.
// GhosttyTerminalView+macOS should request rendering, while the dedicated
// runtime owns CVDisplayLink, idle detection, callback retention, and render
// tick state. Update these tests only when that ownership intentionally moves.
@Suite(.serialized)
struct GhosttyMacOSDisplayLinkRuntimeBoundaryTests {
    @Test
    func macOSTerminalViewDelegatesDisplayLinkLifecycleToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/GhosttyTerminalView+macOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/TerminalMacOSDisplayLinkRuntime.swift")
        )

        #expect(
            !viewSource.contains("private var displayLink: CVDisplayLink?"),
            "GhosttyTerminalView+macOS.swift should not own the CVDisplayLink."
        )
        #expect(
            !viewSource.contains("private var idleCheckTimer"),
            "GhosttyTerminalView+macOS.swift should not own render idle timers."
        )
        #expect(
            !viewSource.contains("private func displayLinkTick"),
            "GhosttyTerminalView+macOS.swift should not own display-link tick processing."
        )
        #expect(
            !viewSource.contains("private final class DisplayLinkCallbackContext"),
            "GhosttyTerminalView+macOS.swift should not own display-link callback retention."
        )

        #expect(viewSource.contains("let displayLinkRuntime = TerminalMacOSDisplayLinkRuntime()"))
        #expect(viewSource.contains("displayLinkRuntime.setup"))
        #expect(viewSource.contains("displayLinkRuntime.requestRender"))
        #expect(viewSource.contains("displayLinkRuntime.stop"))

        #expect(runtimeSource.contains("final class TerminalMacOSDisplayLinkRuntime"))
        #expect(runtimeSource.contains("private var displayLink: CVDisplayLink?"))
        #expect(runtimeSource.contains("private var idleCheckTimer"))
        #expect(runtimeSource.contains("func tick"))
        #expect(runtimeSource.contains("final class TerminalMacOSDisplayLinkCallbackContext"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
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
