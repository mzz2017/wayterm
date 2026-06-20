import Testing
@testable import VVTerm

// Test Context:
// These tests protect touch-selection geometry and gesture policy for terminal
// text selection. They use pure coordinate/value fakes and no UIKit gestures;
// update only when terminal selection behavior is intentionally redesigned.

struct TerminalTouchSelectionTests {
    @Test
    func normalizesSelectionOrderAcrossRows() {
        let selection = TerminalGridSelection(
            start: TerminalGridPoint(row: 4, column: 8),
            end: TerminalGridPoint(row: 1, column: 2)
        )

        #expect(selection.orderedStart == TerminalGridPoint(row: 1, column: 2))
        #expect(selection.orderedEnd == TerminalGridPoint(row: 4, column: 8))
        #expect(selection.normalized == TerminalGridSelection(
            start: TerminalGridPoint(row: 1, column: 2),
            end: TerminalGridPoint(row: 4, column: 8)
        ))
    }

    @Test
    func comparesColumnsWithinSameRow() {
        let left = TerminalGridPoint(row: 3, column: 1)
        let right = TerminalGridPoint(row: 3, column: 9)

        #expect(left < right)
        #expect(max(left, right) == right)
        #expect(min(left, right) == left)
    }
}
