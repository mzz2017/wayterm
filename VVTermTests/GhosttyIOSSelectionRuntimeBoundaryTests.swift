import Foundation
import Testing

#if os(iOS)
@testable import VVTerm
#endif

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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Selection/TerminalIOSSelectionRuntime.swift")
        )

        // Given the iOS terminal view needs to decide whether selection menu
        // actions are available.
        #expect(viewSource.contains("private let selectionRuntime = TerminalIOSSelectionRuntime()"))
        #expect(viewSource.contains("selectionRuntime.hasGhosttySelection"))
        #expect(viewSource.contains("selectionRuntime.nativeTextSnapshot"))

        // Then the main UIKit view does not directly own the Ghostty selection
        // C/FFI query.
        #expect(!viewSource.contains("ghostty_surface_has_selection"))
        #expect(!viewSource.contains("private func readNativeSelectionLine"))
        #expect(!viewSource.contains("GhosttyTerminalTextReader.readViewportLine"))

        #expect(runtimeSource.contains("final class TerminalIOSSelectionRuntime"))
        #expect(runtimeSource.contains("func hasGhosttySelection"))
        #expect(runtimeSource.contains("func nativeTextSnapshot"))
        #expect(runtimeSource.contains("ghostty_surface_has_selection"))
        #expect(runtimeSource.contains("GhosttyTerminalTextReader.readViewportLine"))
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

#if os(iOS)
// Test Context:
// TerminalIOSSelectionRuntime owns the safe entry point for Ghostty selection FFI.
// These behavior tests protect the nil-surface guard that lets callers ask about
// selection availability during teardown without touching native surface memory.
@Suite(.serialized)
@MainActor
struct GhosttyIOSSelectionRuntimeBehaviorTests {
    @Test
    func nilSurfaceReportsNoSelectionWithoutCallingGhostty() {
        let runtime = TerminalIOSSelectionRuntime()

        // Given selection availability is queried after the native surface was cleared.
        let hasSelection = runtime.hasGhosttySelection(surface: nil)

        // Then the runtime returns a safe false value instead of crossing the FFI boundary.
        #expect(!hasSelection, "A missing Ghostty surface should never report an active selection.")
    }
}
#endif
