import CoreGraphics
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the pure touch-selection grid geometry used by the iOS
// Ghostty terminal view. They do not create UIKit views or Ghostty surfaces; the
// fake metrics represent a visible terminal grid. Update these tests only when
// the intended mapping between terminal cells, selection rectangles, and menu
// placement changes.

@Suite
struct TerminalTouchSelectionLayoutTests {
    @Test
    func gridPointClampsLocationsToVisibleTerminalGrid() {
        let layout = TerminalTouchSelectionLayout(
            metrics: TerminalSelectionGridMetrics(
                cols: 4,
                rows: 3,
                cellSize: CGSize(width: 10, height: 20)
            ),
            bounds: CGRect(x: 0, y: 0, width: 40, height: 60)
        )

        // Given locations outside and inside the visible terminal grid.
        let negative = layout.gridPoint(for: CGPoint(x: -20, y: -5))
        let middle = layout.gridPoint(for: CGPoint(x: 29, y: 41))
        let overflow = layout.gridPoint(for: CGPoint(x: 999, y: 999))

        // Then hit testing clamps to valid terminal cells.
        #expect(negative == TerminalGridPoint(row: 0, column: 0))
        #expect(middle == TerminalGridPoint(row: 2, column: 2))
        #expect(overflow == TerminalGridPoint(row: 2, column: 3))
    }

    @Test
    func selectionRectsCoverEveryTouchedCellAcrossRows() {
        let layout = TerminalTouchSelectionLayout(
            metrics: TerminalSelectionGridMetrics(
                cols: 4,
                rows: 3,
                cellSize: CGSize(width: 10, height: 20)
            ),
            bounds: CGRect(x: 0, y: 0, width: 40, height: 60)
        )
        let selection = TerminalGridSelection(
            start: TerminalGridPoint(row: 0, column: 2),
            end: TerminalGridPoint(row: 2, column: 1)
        )

        // When a selection spans multiple terminal rows.
        let rects = layout.selectionRects(for: selection)

        // Then first, middle, and final row widths follow terminal-cell bounds.
        #expect(rects == [
            CGRect(x: 20, y: 0, width: 20, height: 20),
            CGRect(x: 0, y: 20, width: 40, height: 20),
            CGRect(x: 0, y: 40, width: 20, height: 20),
        ])
    }

    @Test
    func menuPointUsesSelectionBoundsAndStaysInsideViewBottom() {
        let layout = TerminalTouchSelectionLayout(
            metrics: TerminalSelectionGridMetrics(
                cols: 4,
                rows: 3,
                cellSize: CGSize(width: 10, height: 20)
            ),
            bounds: CGRect(x: 0, y: 0, width: 40, height: 60)
        )
        let selection = TerminalGridSelection(
            start: TerminalGridPoint(row: 2, column: 1),
            end: TerminalGridPoint(row: 2, column: 3)
        )

        // When the menu would otherwise sit below the visible terminal view.
        let point = layout.menuPoint(for: selection)

        // Then it is centered on the selection and clamped above the bottom edge.
        #expect(point == CGPoint(x: 25, y: 59))
    }
}
