#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

struct GhosttyNativeFindSessionTests {
    @Test
    @MainActor
    func invalidateClearsReportedResults() {
        guard #available(iOS 16.0, *) else { return }

        var didInvalidate = false
        let session = GhosttyNativeFindSession(
            onSearch: { _, _ in },
            onNavigate: { _ in },
            onInvalidate: {
                didInvalidate = true
            }
        )

        #expect(session.updateReportedResults(total: 7, highlightedIndex: 3))
        session.invalidateFoundResults()

        #expect(didInvalidate)
        #expect(session.resultCount == 0)
        #expect(session.highlightedResultIndex == NSNotFound)
    }

    @Test
    @MainActor
    func clampsHighlightedIndexToKnownResults() {
        guard #available(iOS 16.0, *) else { return }

        let session = GhosttyNativeFindSession(
            onSearch: { _, _ in },
            onNavigate: { _ in },
            onInvalidate: {}
        )

        #expect(session.updateReportedResults(total: 2, highlightedIndex: 9))
        #expect(session.resultCount == 2)
        #expect(session.highlightedResultIndex == NSNotFound)
    }
}
#endif
