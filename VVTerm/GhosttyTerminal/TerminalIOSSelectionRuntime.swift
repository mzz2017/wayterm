#if os(iOS)
import Foundation

@MainActor
final class TerminalIOSSelectionRuntime {
    func hasGhosttySelection(surface: ghostty_surface_t?) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }
}
#endif
