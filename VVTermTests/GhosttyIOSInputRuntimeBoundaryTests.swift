import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty input FFI ownership. The
// UIKit terminal view may decide routing policy, but direct hardware key and
// IME preedit C calls should be owned by a focused runtime helper. Update these
// tests only if those FFI responsibilities intentionally move to another
// non-view owner.

@Suite(.serialized)
struct GhosttyIOSInputRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesHardwareKeyAndPreeditFFIToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSInputRuntime.swift")
        )

        // Given the iOS terminal view routes hardware keys and IME preedit.
        #expect(viewSource.contains("private let inputRuntime = TerminalIOSInputRuntime()"))
        #expect(viewSource.contains("inputRuntime.sendDirectHardwareKeyEvent"))
        #expect(viewSource.contains("inputRuntime.syncPreedit"))

        // Then the main UIKit view does not directly own those C/FFI calls or
        // the Ghostty action conversion helper.
        #expect(!viewSource.contains("ghostty_surface_key"))
        #expect(!viewSource.contains("ghostty_surface_preedit"))
        #expect(!viewSource.contains("private func ghosttyInputAction"))

        #expect(runtimeSource.contains("final class TerminalIOSInputRuntime"))
        #expect(runtimeSource.contains("func sendDirectHardwareKeyEvent"))
        #expect(runtimeSource.contains("func syncPreedit"))
        #expect(runtimeSource.contains("ghostty_surface_key"))
        #expect(runtimeSource.contains("ghostty_surface_preedit"))
        #expect(runtimeSource.contains("private func ghosttyInputAction"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
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
