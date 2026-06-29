#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

// Test Context:
// These tests protect native Ghostty find-session state transitions without
// constructing a live terminal surface. Fakes are in-memory search/session values;
// update only when native find behavior intentionally changes.

@MainActor
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

    @Test
    func lifecycleConsumesOnlySuppressedGhosttySearchEndEvents() {
        var lifecycle = TerminalFindNavigatorLifecycle()

        let initialConsume = lifecycle.consumeSuppressedGhosttySearchEnd()
        #expect(initialConsume == false)

        lifecycle.suppressNextGhosttySearchEnd()

        #expect(lifecycle.suppressedGhosttySearchEndCount == 1)
        let suppressedConsume = lifecycle.consumeSuppressedGhosttySearchEnd()
        #expect(suppressedConsume)
        #expect(lifecycle.suppressedGhosttySearchEndCount == 0)
        let finalConsume = lifecycle.consumeSuppressedGhosttySearchEnd()
        #expect(finalConsume == false)
    }

    @Test
    func lifecycleCancelsPendingSuppressionWhenSearchCommandFails() {
        var lifecycle = TerminalFindNavigatorLifecycle()

        lifecycle.suppressNextGhosttySearchEnd()
        lifecycle.cancelSuppressedGhosttySearchEnd()

        #expect(lifecycle.suppressedGhosttySearchEndCount == 0)
        let consumeAfterCancel = lifecycle.consumeSuppressedGhosttySearchEnd()
        #expect(consumeAfterCancel == false)
    }

    @Test
    func lifecyclePreservesTerminalFocusRestoreIntentAcrossRepeatedBegin() {
        var lifecycle = TerminalFindNavigatorLifecycle()

        lifecycle.begin(restoreTerminalFocus: false)
        lifecycle.begin(restoreTerminalFocus: true)

        #expect(lifecycle.isActive)
        let shouldRestoreFocus = lifecycle.end()
        #expect(shouldRestoreFocus)
        #expect(lifecycle.isActive == false)
    }
}
#endif
