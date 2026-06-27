import Foundation
import Testing

#if os(iOS)
@testable import VVTerm
#endif

// Test Context:
// These source-boundary tests protect iOS Ghostty selection ownership. Selection
// UI may collect gestures, layout, and menu intent, but raw Ghostty surface
// handles and selection text reader FFI should remain behind
// TerminalIOSSurfaceOwner and TerminalIOSSelectionRuntime. Update these tests
// only if selection FFI intentionally moves to another non-view owner.

@Suite(.serialized)
struct GhosttyIOSSelectionRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesSelectionAvailabilityFFIToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Selection/GhosttyTerminalView+SelectionInteractions+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Selection/TerminalIOSSelectionRuntime.swift")
        )
        let ownerSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )

        // Given the iOS terminal view needs to decide whether selection menu
        // actions are available.
        #expect(viewSource.contains("let selectionRuntime = TerminalIOSSelectionRuntime()"))
        #expect(selectionSource.contains("surfaceOwner.hasGhosttySelection(using: selectionRuntime)"))
        #expect(selectionSource.contains("surfaceOwner.nativeTextSnapshot("))
        #expect(selectionSource.contains("surfaceOwner.quickLookWordSelection("))
        #expect(selectionSource.contains("surfaceOwner.touchSelectionText("))
        #expect(selectionSource.contains("surfaceOwner.ghosttySelectionText("))
        #expect(selectionSource.contains("surfaceOwner.sendMousePosition(pos)"))
        #expect(selectionSource.contains("surfaceOwner.sendMouseButton("))

        // Then the main UIKit view does not directly own the Ghostty selection
        // C/FFI query.
        #expect(!selectionSource.contains("unsafeCValue"))
        #expect(!selectionSource.contains("ghostty_surface_has_selection"))
        #expect(!selectionSource.contains("GhosttyTerminalTextReader."))
        #expect(!selectionSource.contains("surface.sendMousePos"))
        #expect(!selectionSource.contains("surface.sendMouseButton"))
        #expect(!selectionSource.contains("guard let surface = surface"))

        #expect(runtimeSource.contains("final class TerminalIOSSelectionRuntime"))
        #expect(runtimeSource.contains("func hasGhosttySelection"))
        #expect(runtimeSource.contains("func nativeTextSnapshot"))
        #expect(runtimeSource.contains("func quickLookWordSelection"))
        #expect(runtimeSource.contains("func touchSelectionText"))
        #expect(runtimeSource.contains("func ghosttySelectionText"))
        #expect(runtimeSource.contains("ghostty_surface_has_selection"))
        #expect(runtimeSource.contains("GhosttyTerminalTextReader.readViewportLine"))
        #expect(runtimeSource.contains("GhosttyTerminalTextReader.quickLookWordSelection"))
        #expect(runtimeSource.contains("GhosttyTerminalTextReader.readText"))
        #expect(runtimeSource.contains("GhosttyTerminalTextReader.readSelection"))

        #expect(ownerSource.contains("func hasGhosttySelection(using selectionRuntime: TerminalIOSSelectionRuntime)"))
        #expect(ownerSource.contains("func nativeTextSnapshot("))
        #expect(ownerSource.contains("func quickLookWordSelection("))
        #expect(ownerSource.contains("func touchSelectionText("))
        #expect(ownerSource.contains("func ghosttySelectionText("))
        #expect(ownerSource.contains("func sendMousePosition("))
        #expect(ownerSource.contains("func sendMouseButton("))
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
