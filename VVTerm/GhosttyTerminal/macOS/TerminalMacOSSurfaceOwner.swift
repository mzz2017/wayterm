//
//  TerminalMacOSSurfaceOwner.swift
//  VVTerm
//
//  Stable owner for macOS Ghostty app and surface references.
//

#if os(macOS)
import CoreGraphics
import Foundation

@MainActor
final class TerminalMacOSSurfaceOwner {
    let ghosttyApp: ghostty_app_t
    weak var appWrapper: Ghostty.App?
    var surface: Ghostty.Surface?

    init(ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App?) {
        self.ghosttyApp = ghosttyApp
        self.appWrapper = appWrapper
    }

    func tickDisplayLink(_ displayLinkRuntime: TerminalMacOSDisplayLinkRuntime, isShuttingDown: Bool) {
        displayLinkRuntime.tick(
            isShuttingDown: isShuttingDown,
            surface: surface?.unsafeCValue,
            appTick: { [weak appWrapper] in
                appWrapper?.appTick()
            }
        )
    }

    func hasSelection() -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return ghostty_surface_has_selection(cSurface)
    }

    @discardableResult
    func forceRefresh(backingSize: CGSize) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }

        ghostty_surface_set_size(
            cSurface,
            UInt32(backingSize.width),
            UInt32(backingSize.height)
        )

        ghostty_surface_refresh(cSurface)
        ghostty_surface_draw(cSurface)
        appWrapper?.appTick()
        return true
    }

    @discardableResult
    func updateSurfaceConfig(_ presentationOverrides: TerminalPresentationOverrides) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        appWrapper?.updateSurfaceConfig(cSurface, presentationOverrides: presentationOverrides)
        return true
    }

    func writeOutput(_ data: Data) {
        guard let cSurface = surface?.unsafeCValue else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_output(cSurface, ptr, UInt(buffer.count))
        }
    }

    func externalExited(_ exitCode: UInt32) {
        guard let cSurface = surface?.unsafeCValue else { return }
        ghostty_surface_external_exited(cSurface, exitCode)
    }
}
#endif
