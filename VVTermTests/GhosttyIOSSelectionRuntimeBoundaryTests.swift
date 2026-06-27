import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty selection FFI ownership. The
// UIKit terminal view may decide when to show menus, but direct Ghostty
// selection availability queries should be owned by a focused runtime helper.
// Update these tests only if selection FFI intentionally moves to another
// non-view owner.

@Suite(.serialized)
struct GhosttyIOSSelectionRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesSelectionAvailabilityFFIToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSSelectionRuntime.swift")
        )

        // Given the iOS terminal view needs to decide whether selection menu
        // actions are available.
        #expect(viewSource.contains("private let selectionRuntime = TerminalIOSSelectionRuntime()"))
        #expect(viewSource.contains("selectionRuntime.hasGhosttySelection"))

        // Then the main UIKit view does not directly own the Ghostty selection
        // C/FFI query.
        #expect(!viewSource.contains("ghostty_surface_has_selection"))

        #expect(runtimeSource.contains("final class TerminalIOSSelectionRuntime"))
        #expect(runtimeSource.contains("func hasGhosttySelection"))
        #expect(runtimeSource.contains("ghostty_surface_has_selection"))
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
