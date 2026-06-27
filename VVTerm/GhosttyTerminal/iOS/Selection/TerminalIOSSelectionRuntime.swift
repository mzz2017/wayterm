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

    func quickLookWordSelection(
        surface: ghostty_surface_t?,
        layout: TerminalTouchSelectionLayout
    ) -> TerminalGridSelection? {
        guard let surface else { return nil }
        return GhosttyTerminalTextReader.quickLookWordSelection(
            surface: surface,
            layout: layout
        )
    }

    func touchSelectionText(
        surface: ghostty_surface_t?,
        selection: TerminalGridSelection
    ) -> String? {
        guard let surface else { return nil }

        let normalized = selection.normalized
        let cSelection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(normalized.start.column),
                y: UInt32(normalized.start.row)
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(normalized.end.column),
                y: UInt32(normalized.end.row)
            ),
            rectangle: false
        )
        return GhosttyTerminalTextReader.readText(surface: surface, selection: cSelection)
    }

    func ghosttySelectionText(surface: ghostty_surface_t?) -> String? {
        guard let surface else { return nil }
        return GhosttyTerminalTextReader.readSelection(surface: surface)
    }
}
#endif
