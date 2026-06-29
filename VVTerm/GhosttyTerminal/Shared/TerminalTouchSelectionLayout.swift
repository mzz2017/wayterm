#if os(iOS)
import CoreGraphics

nonisolated struct TerminalSelectionGridMetrics: Equatable {
    let cols: Int
    let rows: Int
    let cellSize: CGSize

    init(cols: Int, rows: Int, cellSize: CGSize) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.cellSize = CGSize(
            width: max(cellSize.width, 1),
            height: max(cellSize.height, 1)
        )
    }
}

nonisolated struct TerminalTouchSelectionLayout {
    let metrics: TerminalSelectionGridMetrics
    let bounds: CGRect

    func gridPoint(for location: CGPoint) -> TerminalGridPoint {
        let column = min(max(Int(floor(location.x / metrics.cellSize.width)), 0), metrics.cols - 1)
        let row = min(max(Int(floor(location.y / metrics.cellSize.height)), 0), metrics.rows - 1)
        return TerminalGridPoint(row: row, column: column)
    }

    func gridPoint(forLinearOffset offset: Int) -> TerminalGridPoint {
        let clampedOffset = min(max(offset, 0), max(metrics.cols * metrics.rows - 1, 0))
        return TerminalGridPoint(
            row: clampedOffset / metrics.cols,
            column: clampedOffset % metrics.cols
        )
    }

    func selection(fromViewportText text: ghostty_text_s) -> TerminalGridSelection? {
        guard metrics.cols > 0, metrics.rows > 0 else { return nil }
        let start = gridPoint(forLinearOffset: Int(text.offset_start))
        let end = gridPoint(forLinearOffset: Int(text.offset_start + text.offset_len))
        return TerminalGridSelection(start: start, end: end).normalized
    }

    func cellFrame(for point: TerminalGridPoint) -> CGRect {
        CGRect(
            x: CGFloat(point.column) * metrics.cellSize.width,
            y: CGFloat(point.row) * metrics.cellSize.height,
            width: metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    }

    func selectionRects(for selection: TerminalGridSelection) -> [CGRect] {
        let normalized = selection.normalized
        let start = normalized.start
        let end = normalized.end

        return (start.row...end.row).map { row in
            let startColumn = row == start.row ? start.column : 0
            let endColumn = row == end.row ? end.column : max(metrics.cols - 1, 0)
            let width = CGFloat(max(endColumn - startColumn + 1, 1)) * metrics.cellSize.width
            return CGRect(
                x: CGFloat(startColumn) * metrics.cellSize.width,
                y: CGFloat(row) * metrics.cellSize.height,
                width: width,
                height: metrics.cellSize.height
            )
        }
    }

    func menuPoint(for selection: TerminalGridSelection) -> CGPoint? {
        let rects = selectionRects(for: selection)
        guard let firstRect = rects.first else { return nil }
        let selectionBounds = rects.dropFirst().reduce(firstRect) { partialResult, rect in
            partialResult.union(rect)
        }
        return CGPoint(
            x: selectionBounds.midX,
            y: min(selectionBounds.maxY + 12, bounds.maxY - 1)
        )
    }
}
#endif
