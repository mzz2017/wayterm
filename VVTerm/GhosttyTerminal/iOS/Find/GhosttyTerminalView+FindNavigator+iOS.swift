#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    // MARK: - Native Find Navigator

    func setupNativeFindInteraction() {
        guard #available(iOS 16.0, *), nativeFindInteraction == nil else { return }
        let interaction = UIFindInteraction(sessionDelegate: self)
        interaction.optionsMenuProvider = { _ in nil }
        addInteraction(interaction)
        nativeFindInteraction = interaction
    }

    func notifyFindNavigatorVisibilityChange() {
        onFindNavigatorVisibilityChange?(isFindNavigatorVisible)
    }

    func updateNativeFindOverlay() {
        guard usesNativeTouchSelection else { return }
        let highlights = nativeFindDecorations.flatMap { decoration in
            nativeSelectionSnapshot.selectionRects(for: decoration.range).map {
                TerminalNativeFindOverlayView.Highlight(rect: $0.rect, style: decoration.style)
            }
        }
        nativeFindOverlay.highlights = highlights
    }

    @available(iOS 16.0, *)
    private func beginFindNavigatorPresentation(restoreTerminalFocus: Bool) {
        findRuntime.beginNavigatorLifecycle(restoreTerminalFocus: restoreTerminalFocus)
        notifyFindNavigatorVisibilityChange()
        stopKeyRepeat()

        if !super.isFirstResponder {
            _ = super.becomeFirstResponder()
        }

        surfaceOwner.setFocus(false, using: surfaceLifecycleRuntime)
    }

    func endFindNavigatorLifecycle() -> Bool {
        let shouldRestoreTerminalFocus = findRuntime.endNavigatorLifecycle()
        if !shouldRestoreTerminalFocus, super.isFirstResponder {
            _ = super.resignFirstResponder()
        }
        return shouldRestoreTerminalFocus
    }

    @available(iOS 16.0, *)
    func presentFindNavigator(prefillingSelectedText: Bool = false) {
        guard let nativeFindInteraction else { return }
        beginFindNavigatorPresentation(restoreTerminalFocus: imeProxyTextView.isFirstResponder)
        refreshNativeSelectionSnapshot()
        if prefillingSelectedText, let selectionText = normalizedSelectionMenuText() {
            nativeFindInteraction.searchText = selectionText
            findRuntime.applyExternalQuery(selectionText) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
            performGhosttyFindQuery(selectionText)
        }
        nativeFindInteraction.presentFindNavigator(showingReplace: false)
    }

    func showFindNavigator(prefillingSelectedText: Bool = false) {
        guard usesNativeTouchSelection else { return }
        if #available(iOS 16.0, *) {
            presentFindNavigator(prefillingSelectedText: prefillingSelectedText)
        }
    }

    func dismissFindNavigator() {
        guard #available(iOS 16.0, *), nativeFindInteraction?.isFindNavigatorVisible == true else { return }
        nativeFindInteraction?.dismissFindNavigator()
    }

    @MainActor
    @discardableResult
    func performGhosttyFindQuery(
        _ query: String,
        keepNavigatorVisibleOnSearchEnd: Bool = false
    ) -> Bool {
        findRuntime.resetReportedResults()
        let action = "search:\(query)"
        if keepNavigatorVisibleOnSearchEnd {
            findRuntime.suppressNextGhosttySearchEnd()
        }
        guard surfaceOwner.perform(action: action) else {
            if keepNavigatorVisibleOnSearchEnd {
                findRuntime.cancelSuppressedGhosttySearchEnd()
            }
            return false
        }
        if query.isEmpty {
            if #available(iOS 16.0, *) {
                findRuntime.resetNativeSession { [weak self] in
                    self?.nativeFindInteraction?.updateResultCount()
                }
            }
        }
        return true
    }

    @MainActor
    func navigateGhosttyFind(_ direction: UITextStorageDirection) {
        let action = direction == .backward ? "navigate_search:previous" : "navigate_search:next"
        surfaceOwner.perform(action: action)
    }

    @MainActor
    func endGhosttyFindSearchForNavigatorDismissal() {
        findRuntime.resetReportedResults()
        findRuntime.suppressNextGhosttySearchEnd()
        if !surfaceOwner.perform(action: "end_search") {
            findRuntime.cancelSuppressedGhosttySearchEnd()
        }
    }

    @MainActor
    func invalidateGhosttyFindWithoutClosingNavigator() {
        performGhosttyFindQuery("", keepNavigatorVisibleOnSearchEnd: true)
    }

    func handleGhosttySearchStarted(needle: String) {
        guard usesNativeTouchSelection else { return }
        findRuntime.resetReportedResults()
        if #available(iOS 16.0, *) {
            nativeFindInteraction?.searchText = needle
            findRuntime.applyExternalQuery(needle) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
            if nativeFindInteraction?.isFindNavigatorVisible != true {
                beginFindNavigatorPresentation(restoreTerminalFocus: imeProxyTextView.isFirstResponder)
                nativeFindInteraction?.presentFindNavigator(showingReplace: false)
            }
        }
    }

    func handleGhosttySearchEnded() {
        guard usesNativeTouchSelection else { return }
        findRuntime.resetReportedResults()
        if #available(iOS 16.0, *) {
            findRuntime.resetNativeSession { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
            if findRuntime.consumeSuppressedGhosttySearchEnd() {
                return
            } else if nativeFindInteraction?.isFindNavigatorVisible == true {
                nativeFindInteraction?.dismissFindNavigator()
            } else if findRuntime.isNavigatorLifecycleActive {
                _ = endFindNavigatorLifecycle()
                notifyFindNavigatorVisibilityChange()
            }
        }
    }

    func handleGhosttySearchTotalChange(_ total: Int?) {
        guard usesNativeTouchSelection else { return }
        if #available(iOS 16.0, *) {
            findRuntime.updateReportedTotal(total) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
        }
    }

    func handleGhosttySearchSelectedChange(_ selected: Int?) {
        guard usesNativeTouchSelection else { return }
        if #available(iOS 16.0, *) {
            findRuntime.updateReportedSelectedIndex(selected) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
        }
    }
}
#endif
