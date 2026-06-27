import Foundation
import Testing

#if os(iOS)
import CoreGraphics
@testable import VVTerm
#endif

// Test Context:
// These source-boundary tests protect iOS Ghostty surface display ownership.
// The UIKit terminal view may size IOSurface layers and report UI events, but
// Ghostty resize, redraw, external-output, and external-exit C/FFI calls should
// be owned by a focused runtime helper. Update these tests only if those FFI
// responsibilities intentionally move to another non-view owner.

@Suite(.serialized)
struct GhosttyIOSSurfaceDisplayRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesSurfaceDisplayFFIToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSSurfaceDisplayRuntime.swift")
        )

        // Given the iOS terminal view needs Ghostty resize, redraw, and
        // External backend output lifecycle.
        #expect(viewSource.contains("private let surfaceDisplayRuntime = TerminalIOSSurfaceDisplayRuntime()"))
        #expect(viewSource.contains("surfaceDisplayRuntime.resizeIfNeeded"))
        #expect(viewSource.contains("surfaceDisplayRuntime.forceResize"))
        #expect(viewSource.contains("surfaceDisplayRuntime.redraw"))
        #expect(viewSource.contains("surfaceDisplayRuntime.writeOutput"))
        #expect(viewSource.contains("surfaceDisplayRuntime.externalExited"))

        // Then the main UIKit view does not directly own those C/FFI calls or
        // Ghostty pixel-size tracking state.
        #expect(!viewSource.contains("private var lastPixelSize"))
        #expect(!viewSource.contains("private var lastContentScale"))
        #expect(!viewSource.contains("ghostty_surface_set_content_scale"))
        #expect(!viewSource.contains("ghostty_surface_set_size"))
        #expect(!viewSource.contains("ghostty_surface_refresh"))
        #expect(!viewSource.contains("ghostty_surface_draw"))
        #expect(!viewSource.contains("ghostty_surface_write_output"))
        #expect(!viewSource.contains("ghostty_surface_external_exited"))

        #expect(runtimeSource.contains("final class TerminalIOSSurfaceDisplayRuntime"))
        #expect(runtimeSource.contains("ghostty_surface_set_content_scale"))
        #expect(runtimeSource.contains("ghostty_surface_set_size"))
        #expect(runtimeSource.contains("ghostty_surface_refresh"))
        #expect(runtimeSource.contains("ghostty_surface_draw"))
        #expect(runtimeSource.contains("ghostty_surface_write_output"))
        #expect(runtimeSource.contains("ghostty_surface_external_exited"))
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
// These behavior tests protect iOS surface display sizing policy without calling
// Ghostty FFI. The runtime owns the native calls, while TerminalSurfaceDisplaySizeState
// owns pixel conversion and duplicate resize suppression.
@Suite(.serialized)
struct GhosttyIOSSurfaceDisplayRuntimeBehaviorTests {
    @Test
    func sizeStateRejectsInvalidOrSubpixelSizes() {
        var state = TerminalSurfaceDisplaySizeState()

        // Given point sizes that cannot produce a positive pixel surface.
        #expect(state.resizeIfNeeded(pointSize: CGSize(width: 0, height: 12), scale: 2) == nil)
        #expect(state.resizeIfNeeded(pointSize: CGSize(width: 12, height: -1), scale: 2) == nil)
        #expect(state.resizeIfNeeded(pointSize: CGSize(width: 0.2, height: 10), scale: 2) == nil)

        // Then invalid sizes are ignored and do not poison the next valid resize.
        #expect(
            state.resizeIfNeeded(pointSize: CGSize(width: 10.8, height: 5.5), scale: 2)
                == CGSize(width: 21, height: 11),
            "Valid surface sizes should be floored to whole pixels after invalid inputs."
        )
    }

    @Test
    func sizeStateSuppressesDuplicateResizeUntilPixelSizeOrScaleChanges() {
        var state = TerminalSurfaceDisplaySizeState()

        // Given a first valid resize.
        let first = state.resizeIfNeeded(pointSize: CGSize(width: 10.8, height: 5.5), scale: 2)

        // Then duplicate pixel size and scale are suppressed.
        #expect(first == CGSize(width: 21, height: 11))
        #expect(
            state.resizeIfNeeded(pointSize: CGSize(width: 10.9, height: 5.9), scale: 2) == nil,
            "Equivalent floored pixel size at the same scale should not call Ghostty again."
        )

        // But scale or pixel changes still request a native resize.
        #expect(
            state.resizeIfNeeded(pointSize: CGSize(width: 10.9, height: 5.9), scale: 3)
                == CGSize(width: 32, height: 17)
        )
        #expect(
            state.resizeIfNeeded(pointSize: CGSize(width: 11.5, height: 5.9), scale: 3)
                == CGSize(width: 34, height: 17)
        )
    }

    @Test
    func forceResizeRecordsSizeAndResetAllowsNextResize() {
        var state = TerminalSurfaceDisplaySizeState()

        // Given force resize is used for explicit layout refresh.
        let forced = state.forceResize(pointSize: CGSize(width: 10, height: 6), scale: 2)

        // Then it records the applied size, so automatic resize can suppress duplicates.
        #expect(forced == CGSize(width: 20, height: 12))
        #expect(state.resizeIfNeeded(pointSize: CGSize(width: 10, height: 6), scale: 2) == nil)

        // And resetting size tracking allows the same dimensions to be applied again.
        state.reset()
        #expect(state.resizeIfNeeded(pointSize: CGSize(width: 10, height: 6), scale: 2) == CGSize(width: 20, height: 12))
    }
}
#endif
