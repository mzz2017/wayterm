#if os(iOS)
import UIKit

// MARK: - Native Text Selection

extension GhosttyTerminalView: UITextInteractionDelegate {
    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        guard usesNativeTouchSelection else { return false }
        prefersNativeSelectionFirstResponder = true
        shouldRestoreIMEProxyFocusAfterNativeSelection = imeProxyTextView.isFirstResponder
        refreshNativeSelectionSnapshot()
        return nativeSelectionSnapshot.length > 0
    }

    func interactionWillBegin(_ interaction: UITextInteraction) {
        shouldRestoreIMEProxyFocusAfterNativeSelection = shouldRestoreIMEProxyFocusAfterNativeSelection
            || imeProxyTextView.isFirstResponder
        nativeSelectionInteractionActive = true
        if !imeProxyTextView.isFirstResponder {
            _ = becomeFirstResponder()
        }
        refreshNativeSelectionSnapshot()
    }

    func interactionDidEnd(_ interaction: UITextInteraction) {
        nativeSelectionInteractionActive = false
        if nativeSelectedRange == nil {
            prefersNativeSelectionFirstResponder = false
        }
        refreshNativeSelectionSnapshot()
        guard shouldRestoreIMEProxyFocusAfterNativeSelection else { return }
        shouldRestoreIMEProxyFocusAfterNativeSelection = false
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isShuttingDown,
                  self.isTextInputSessionEligible,
                  !self.isFindNavigatorActive else {
                return
            }
            _ = self.imeProxyTextView.becomeFirstResponder()
        }
    }
}

@available(iOS 16.0, *)
extension GhosttyTerminalView: UIFindInteractionDelegate {
    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        guard view === self, usesNativeTouchSelection else { return nil }
        refreshNativeSelectionSnapshot()
        return findRuntime.makeSession(
            onSearch: { [weak self] query, _ in
                guard let self else { return }
                self.performGhosttyFindQuery(
                    query,
                    keepNavigatorVisibleOnSearchEnd: query.isEmpty && self.isFindNavigatorActive
                )
            },
            onNavigate: { [weak self] direction in
                self?.navigateGhosttyFind(direction)
            },
            onInvalidate: { [weak self] in
                self?.invalidateGhosttyFindWithoutClosingNavigator()
            },
            updateResultCount: { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
        )
    }

    func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
        if !findRuntime.isNavigatorLifecycleActive {
            findRuntime.beginNavigatorLifecycle(restoreTerminalFocus: imeProxyTextView.isFirstResponder)
        }
        refreshNativeSelectionSnapshot()
        findRuntime.applyStoredGhosttyFindResultsToNativeSession { [weak self] in
            self?.nativeFindInteraction?.updateResultCount()
        }
        notifyFindNavigatorVisibilityChange()
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        let shouldRestoreTerminalFocus = endFindNavigatorLifecycle()
        nativeFindDecorations.removeAll()
        findRuntime.clearSession { [weak self] in
            self?.nativeFindInteraction?.updateResultCount()
        }
        notifyFindNavigatorVisibilityChange()
        endGhosttyFindSearchForNavigatorDismissal()
        if shouldRestoreTerminalFocus {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFindNavigatorActive else { return }
                self.requestKeyboardFocus(for: .explicitUserRequest)
            }
        }
    }
}

@available(iOS 16.0, *)
extension GhosttyTerminalView: UITextSearching {
    typealias DocumentIdentifier = String

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: String?) -> ComparisonResult {
        guard let lhs = nativeSelectionSnapshot.nativeRange(from: foundRange),
              let rhs = nativeSelectionSnapshot.nativeRange(from: toRange) else {
            return .orderedSame
        }
        if lhs.location < rhs.location { return .orderedAscending }
        if lhs.location > rhs.location { return .orderedDescending }
        if lhs.length < rhs.length { return .orderedAscending }
        if lhs.length > rhs.length { return .orderedDescending }
        return .orderedSame
    }

    func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<String>) {
        refreshNativeSelectionSnapshot()
        nativeFindDecorations.removeAll()

        let ranges = nativeSelectionSnapshot.searchRanges(query: queryString, options: options)
        for range in ranges {
            guard let textRange = nativeSelectionSnapshot.nativeRange(range) else { continue }
            resultAggregator.foundRange(textRange, searchString: queryString, document: nativeFindDocumentIdentifier)
        }
        resultAggregator.finishedSearching()
    }

    func decorate(foundTextRange: UITextRange, document: String?, usingStyle style: UITextSearchFoundTextStyle) {
        guard let range = nativeSelectionSnapshot.nativeRange(from: foundTextRange) else { return }
        nativeFindDecorations.removeAll { NSEqualRanges($0.range, range) }
        nativeFindDecorations.append(TerminalNativeFindDecoration(range: range, style: style))
    }

    func clearAllDecoratedFoundText() {
        nativeFindDecorations.removeAll()
    }

    func willHighlight(foundTextRange: UITextRange, document: String?) {
        requestRender()
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument document: String?) {
        requestRender()
    }

    var selectedTextSearchDocument: String? {
        nativeFindDocumentIdentifier
    }

    func compare(document: String, toDocument other: String) -> ComparisonResult {
        document.compare(other)
    }
}

// MARK: - Gesture Recognizer Delegate

extension GhosttyTerminalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer == pinchRecognizer {
            return canHandlePinchZoom
        }
        if gestureRecognizer == scrollRecognizer {
            if isNativeHostScrollContainerEnabled,
               currentScrollOwner() == .hostScrollback {
                return false
            }
            if usesNativeTouchSelection, nativeSelectionInteractionActive || nativeSelectedRange != nil {
                return false
            }
            if touchSelectionState.hasSelection,
               isPointOnTouchSelectionHandle(touch.location(in: self)) {
                return false
            }
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if usesNativeTouchSelection,
           nativeSelectionInteractionActive || nativeSelectedRange != nil,
           gestureRecognizer == scrollRecognizer || otherGestureRecognizer == scrollRecognizer {
            return false
        }
        if gestureRecognizer == pinchRecognizer || otherGestureRecognizer == pinchRecognizer {
            return false
        }
        // Allow pan and long press to recognize simultaneously. The handlers
        // check isSelecting/isScrolling to avoid conflicts.
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer == scrollRecognizer && otherGestureRecognizer == selectionRecognizer {
            return otherGestureRecognizer.state == .began
        }
        return false
    }
}

// MARK: - Edit Menu Interaction Delegate

extension GhosttyTerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var actions: [UIMenuElement] = []

        if let selectionText = currentSelectionText(), !selectionText.isEmpty {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        if usesAppOwnedTouchSelection {
            actions.append(UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.selectAll(nil)
            })
        }

        return UIMenu(children: actions)
    }
}
#endif
