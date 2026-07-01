#if os(iOS)
import Testing
@testable import Waterm

@Suite(.serialized)
struct GhosttyIOSTouchSelectionStateTests {
    @MainActor
    @Test
    func wordSeedUsesOppositeEdgeWhenDragLeavesSeed() {
        let state = TerminalIOSTouchSelectionState()
        let seed = TerminalGridSelection(
            start: TerminalGridPoint(row: 2, column: 4),
            end: TerminalGridPoint(row: 2, column: 8)
        )

        // Given a long-press that quick-looked a word selection.
        #expect(state.begin(wordSelection: seed, point: nil))
        #expect(state.selection == seed)

        // When dragging before the seeded word, the opposite edge becomes the anchor.
        #expect(state.update(to: TerminalGridPoint(row: 2, column: 1)))

        // Then the selection extends from the drag point back through the seeded word.
        #expect(state.selection == TerminalGridSelection(
            start: TerminalGridPoint(row: 2, column: 1),
            end: TerminalGridPoint(row: 2, column: 8)
        ))
    }

    @MainActor
    @Test
    func handleUpdateNormalizesSelectionAndClearDropsState() {
        let state = TerminalIOSTouchSelectionState()
        let start = TerminalGridPoint(row: 3, column: 6)

        // Given a point-based app-owned touch selection.
        #expect(state.begin(wordSelection: nil, point: start))

        // When the start handle is dragged past the current end.
        #expect(state.updateHandle(.start, to: TerminalGridPoint(row: 3, column: 10)))

        // Then the state keeps a normalized public selection for readers and overlay layout.
        #expect(state.selection == TerminalGridSelection(
            start: TerminalGridPoint(row: 3, column: 6),
            end: TerminalGridPoint(row: 3, column: 10)
        ))

        state.clear()

        // Then future UI/menu checks observe no app-owned touch selection.
        #expect(!state.hasSelection)
        #expect(state.selection == nil)
    }
}
#endif
