#if os(iOS)
import CoreGraphics
import Foundation

@MainActor
final class TerminalIOSSelectionRuntime {
    func hasGhosttySelection(surface: ghostty_surface_t?) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    func nativeTextSnapshot(
        surface: ghostty_surface_t?,
        metrics: TerminalSelectionGridMetrics?
    ) -> TerminalNativeTextSnapshot {
        guard let surface, let metrics else { return .empty }

        let rows = (0..<metrics.rows).map { row in
            GhosttyTerminalTextReader.readViewportLine(
                surface: surface,
                row: row,
                columns: metrics.cols
            )
        }
        return TerminalNativeTextSnapshot(lines: rows, cellSize: metrics.cellSize, columns: metrics.cols)
    }
}
#endif
