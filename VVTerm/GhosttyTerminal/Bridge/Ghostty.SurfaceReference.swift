//
//  Ghostty.SurfaceReference.swift
//  VVTerm
//
//  Surface registration reference used by Ghostty.App.
//

import Foundation

extension Ghostty {
    /// Wrapper to hold reference to a surface for tracking.
    ///
    /// ghostty_surface_t is an opaque pointer, so we store it directly. The
    /// surface itself is freed by the owning Ghostty terminal view lifecycle.
    final class SurfaceReference {
        let surface: ghostty_surface_t
        weak var terminalView: GhosttyTerminalView?
        var isValid: Bool = true

        init(_ surface: ghostty_surface_t, terminalView: GhosttyTerminalView) {
            self.surface = surface
            self.terminalView = terminalView
        }

        func invalidate() {
            isValid = false
        }
    }
}
