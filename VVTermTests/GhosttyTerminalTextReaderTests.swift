#if os(iOS)
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the pure string-normalization behavior used after
// Ghostty's C text-read APIs return viewport text. They do not touch Ghostty C
// surfaces; failures usually mean visible native-selection text cleanup changed.
// Update only when viewport line trimming or column clamping intentionally
// changes.

@Suite
struct GhosttyTerminalTextReaderTests {
    @Test
    func sanitizedViewportLineTrimsLineEndingsAndTrailingWhitespace() {
        // Given Ghostty viewport text with line endings and padding spaces.
        let line = GhosttyTerminalTextReader.sanitizedViewportLine("hello world  \r\n", columns: 80)

        // Then native selection snapshots keep only visible text content.
        #expect(line == "hello world")
    }

    @Test
    func sanitizedViewportLineClampsToVisibleColumns() {
        // Given viewport text longer than the visible terminal columns.
        let line = GhosttyTerminalTextReader.sanitizedViewportLine("abcdef", columns: 4)

        // Then text read for one row cannot spill into invisible columns.
        #expect(line == "abcd")
    }
}
#endif
