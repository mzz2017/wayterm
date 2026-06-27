#if os(iOS)
import UIKit

@MainActor
final class TerminalIOSFindRuntime {
    @available(iOS 16.0, *)
    private var nativeFindSession: GhosttyNativeFindSession?
    private var ghosttyFindReportedTotal: Int?
    private var ghosttyFindReportedSelectedIndex: Int?
    private var navigatorLifecycle = TerminalFindNavigatorLifecycle()

    var isNavigatorLifecycleActive: Bool {
        navigatorLifecycle.isActive
    }

    func resetReportedResults() {
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
    }

    func beginNavigatorLifecycle(restoreTerminalFocus: Bool) {
        navigatorLifecycle.begin(restoreTerminalFocus: restoreTerminalFocus)
    }

    func endNavigatorLifecycle() -> Bool {
        navigatorLifecycle.end()
    }

    func suppressNextGhosttySearchEnd() {
        navigatorLifecycle.suppressNextGhosttySearchEnd()
    }

    func cancelSuppressedGhosttySearchEnd() {
        navigatorLifecycle.cancelSuppressedGhosttySearchEnd()
    }

    func consumeSuppressedGhosttySearchEnd() -> Bool {
        navigatorLifecycle.consumeSuppressedGhosttySearchEnd()
    }

    @available(iOS 16.0, *)
    func makeSession(
        onSearch: @escaping GhosttyNativeFindSession.SearchHandler,
        onNavigate: @escaping GhosttyNativeFindSession.NavigateHandler,
        onInvalidate: @escaping GhosttyNativeFindSession.InvalidateHandler,
        updateResultCount: () -> Void
    ) -> UIFindSession {
        if let nativeFindSession {
            return nativeFindSession
        }

        let session = GhosttyNativeFindSession(
            onSearch: onSearch,
            onNavigate: onNavigate,
            onInvalidate: onInvalidate
        )
        nativeFindSession = session
        applyStoredGhosttyFindResultsToNativeSession(updateResultCount: updateResultCount)
        return session
    }

    @available(iOS 16.0, *)
    func applyExternalQuery(_ query: String, updateResultCount: () -> Void) {
        nativeFindSession?.applyExternalQuery(query)
        applyStoredGhosttyFindResultsToNativeSession(updateResultCount: updateResultCount)
    }

    @available(iOS 16.0, *)
    func resetNativeSession(updateResultCount: () -> Void) {
        nativeFindSession?.resetReportedResults()
        updateResultCount()
    }

    @available(iOS 16.0, *)
    func clearSession(updateResultCount: () -> Void) {
        nativeFindSession?.resetReportedResults()
        nativeFindSession = nil
        resetReportedResults()
        updateResultCount()
    }

    @available(iOS 16.0, *)
    func updateReportedTotal(_ total: Int?, updateResultCount: () -> Void) {
        ghosttyFindReportedTotal = total
        applyStoredGhosttyFindResultsToNativeSession(updateResultCount: updateResultCount)
    }

    @available(iOS 16.0, *)
    func updateReportedSelectedIndex(_ selectedIndex: Int?, updateResultCount: () -> Void) {
        ghosttyFindReportedSelectedIndex = selectedIndex
        applyStoredGhosttyFindResultsToNativeSession(updateResultCount: updateResultCount)
    }

    @available(iOS 16.0, *)
    func applyStoredGhosttyFindResultsToNativeSession(updateResultCount: () -> Void) {
        guard let nativeFindSession else { return }
        if nativeFindSession.updateReportedResults(
            total: ghosttyFindReportedTotal,
            highlightedIndex: ghosttyFindReportedSelectedIndex
        ) {
            updateResultCount()
        }
    }
}
#endif
