import Foundation
import Testing

#if os(iOS)
import UIKit
@testable import VVTerm
#endif

// Test Context:
// Native find bridges UIKit's UIFindInteraction with Ghostty search state on iOS.
// GhosttyTerminalView may route delegate callbacks and UITextSearching snapshots,
// but the native find session and reported Ghostty result counters should live in
// a focused runtime owner. Update this test only if native find ownership moves
// to another explicit runtime/application boundary.

@Suite(.serialized)
struct GhosttyIOSFindRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesNativeFindSessionStateToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSFindRuntime.swift")
        )

        // Given GhosttyTerminalView owns UIKit delegate routing but not find
        // session/result bookkeeping.
        #expect(viewSource.contains("private let findRuntime = TerminalIOSFindRuntime()"))
        #expect(viewSource.contains("findRuntime.makeSession"))
        #expect(viewSource.contains("findRuntime.applyExternalQuery"))
        #expect(viewSource.contains("findRuntime.updateReportedTotal"))
        #expect(viewSource.contains("findRuntime.updateReportedSelectedIndex"))
        #expect(viewSource.contains("findRuntime.resetReportedResults"))
        #expect(viewSource.contains("findRuntime.beginNavigatorLifecycle"))
        #expect(viewSource.contains("findRuntime.endNavigatorLifecycle"))
        #expect(viewSource.contains("findRuntime.suppressNextGhosttySearchEnd"))
        #expect(viewSource.contains("findRuntime.consumeSuppressedGhosttySearchEnd"))

        // Then session ownership and Ghostty result counters must not stay in
        // the giant iOS terminal view.
        #expect(!viewSource.contains("private var nativeFindSession"))
        #expect(!viewSource.contains("private var ghosttyFindReportedTotal"))
        #expect(!viewSource.contains("private var ghosttyFindReportedSelectedIndex"))
        #expect(!viewSource.contains("private func applyStoredGhosttyFindResultsToNativeSession"))
        #expect(!viewSource.contains("private var findNavigatorLifecycle"))
        #expect(!viewSource.contains("findNavigatorLifecycle."))

        // And the focused runtime owns the stored session and result reporting API.
        #expect(runtimeSource.contains("final class TerminalIOSFindRuntime"))
        #expect(runtimeSource.contains("private var nativeFindSession"))
        #expect(runtimeSource.contains("private var ghosttyFindReportedTotal"))
        #expect(runtimeSource.contains("private var ghosttyFindReportedSelectedIndex"))
        #expect(runtimeSource.contains("private var navigatorLifecycle = TerminalFindNavigatorLifecycle()"))
        #expect(runtimeSource.contains("func makeSession"))
        #expect(runtimeSource.contains("func applyExternalQuery"))
        #expect(runtimeSource.contains("func updateReportedTotal"))
        #expect(runtimeSource.contains("func updateReportedSelectedIndex"))
        #expect(runtimeSource.contains("func resetReportedResults"))
        #expect(runtimeSource.contains("func beginNavigatorLifecycle"))
        #expect(runtimeSource.contains("func endNavigatorLifecycle"))
        #expect(runtimeSource.contains("func suppressNextGhosttySearchEnd"))
        #expect(runtimeSource.contains("func consumeSuppressedGhosttySearchEnd"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

#if os(iOS)
// Test Context:
// These behavior tests protect native find state after it was extracted from the
// iOS terminal view. The runtime owns cached Ghostty result counts, native
// session reuse/clearing, and find navigator lifecycle suppression.
@Suite(.serialized)
@MainActor
struct GhosttyIOSFindRuntimeBehaviorTests {
    @available(iOS 16.0, *)
    @Test
    func cachedGhosttyResultsApplyWhenNativeFindSessionIsCreatedAndCleared() throws {
        let runtime = TerminalIOSFindRuntime()
        var updateResultCountCalls = 0
        var searches: [String] = []
        var navigations: [UITextStorageDirection] = []
        var invalidationCount = 0

        // Given Ghostty reports results before UIKit asks for the native find session.
        runtime.updateReportedTotal(3) {
            updateResultCountCalls += 1
        }
        runtime.updateReportedSelectedIndex(1) {
            updateResultCountCalls += 1
        }

        #expect(updateResultCountCalls == 0, "Cached results should not notify UIKit before a native session exists.")

        // When the native session is created.
        let session = try #require(runtime.makeSession(
            onSearch: { query, _ in searches.append(query) },
            onNavigate: { direction in navigations.append(direction) },
            onInvalidate: { invalidationCount += 1 },
            updateResultCount: { updateResultCountCalls += 1 }
        ) as? GhosttyNativeFindSession)

        // Then cached Ghostty results are applied once to UIKit's find session.
        #expect(session.resultCount == 3)
        #expect(session.highlightedResultIndex == 1)
        #expect(updateResultCountCalls == 1)

        // And repeated makeSession calls reuse the same native owner.
        let reusedSession = runtime.makeSession(
            onSearch: { query, _ in searches.append("new-\(query)") },
            onNavigate: { direction in navigations.append(direction) },
            onInvalidate: { invalidationCount += 10 },
            updateResultCount: { updateResultCountCalls += 1 }
        )
        #expect(reusedSession === session, "The runtime should reuse one native find session until it is cleared.")

        // When UIKit search APIs are invoked, the original handlers remain attached.
        session.performSearch(query: "main", options: nil)
        session.highlightNextResult(in: .forward)
        session.invalidateFoundResults()

        #expect(searches == ["main"])
        #expect(navigations == [.forward])
        #expect(invalidationCount == 1)

        // When the runtime clears the native session, result state is reset and UIKit is notified.
        runtime.clearSession {
            updateResultCountCalls += 1
        }

        let nextSession = try #require(runtime.makeSession(
            onSearch: { query, _ in searches.append("next-\(query)") },
            onNavigate: { direction in navigations.append(direction) },
            onInvalidate: { invalidationCount += 100 },
            updateResultCount: { updateResultCountCalls += 1 }
        ) as? GhosttyNativeFindSession)

        #expect(nextSession !== session, "Clearing should release the old native find session.")
        #expect(nextSession.resultCount == 0, "Clearing should reset cached Ghostty find result count.")
        #expect(nextSession.highlightedResultIndex == NSNotFound, "Clearing should reset highlighted result state.")
    }

    @Test
    func navigatorLifecycleAccumulatesRestoreIntentAndConsumesSuppressedSearchEnds() {
        let runtime = TerminalIOSFindRuntime()

        // Given repeated navigator lifecycles with one restore request.
        runtime.beginNavigatorLifecycle(restoreTerminalFocus: false)
        runtime.beginNavigatorLifecycle(restoreTerminalFocus: true)

        // Then the runtime remains active and restores focus once at lifecycle end.
        #expect(runtime.isNavigatorLifecycleActive)
        #expect(runtime.endNavigatorLifecycle(), "Any restore request during an active lifecycle should win.")
        #expect(!runtime.isNavigatorLifecycleActive)
        #expect(!runtime.endNavigatorLifecycle(), "A completed lifecycle should not restore focus again.")

        // Given multiple Ghostty search-end events are intentionally suppressed.
        runtime.suppressNextGhosttySearchEnd()
        runtime.suppressNextGhosttySearchEnd()
        runtime.cancelSuppressedGhosttySearchEnd()

        // Then exactly one suppression remains consumable.
        #expect(runtime.consumeSuppressedGhosttySearchEnd())
        #expect(!runtime.consumeSuppressedGhosttySearchEnd())
    }
}
#endif
