#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    // MARK: - IME Proxy State

    func textInputGridMetrics() -> (cols: Int, rows: Int, cellSize: CGSize, length: Int) {
        let cols = max(lastReportedGrid.cols, 1)
        let rows = max(lastReportedGrid.rows, 1)
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        if cellSize.width > 0 {
            cellWidth = cellSize.width
        } else if bounds.width > 0 {
            cellWidth = bounds.width / CGFloat(cols)
        } else {
            cellWidth = 1
        }
        if cellSize.height > 0 {
            cellHeight = cellSize.height
        } else if bounds.height > 0 {
            cellHeight = bounds.height / CGFloat(rows)
        } else {
            cellHeight = 1
        }
        let size = CGSize(width: max(cellWidth, 1), height: max(cellHeight, 1))
        let length = max(cols * rows, 1)
        return (cols, rows, size, length)
    }

    private func textInputDocumentLength() -> Int {
        textInputModel.documentLength
    }

    private func clampTextInputIndex(_ index: Int) -> Int {
        min(max(index, 0), textInputDocumentLength())
    }

    var imeProxyCanBecomeFirstResponder: Bool {
        isTextInputSessionEligible && !isFindNavigatorActive
    }

    var imeProxyCanResignFirstResponder: Bool {
        inputRuntime.canResignIMEProxy(isTextInputSessionEligible: isTextInputSessionEligible)
    }

    var currentTextInputContextIdentifier: String? {
        guard isTextInputSessionEligible, !isFindNavigatorActive else { return nil }
        return Self.textInputContextID
    }

    var resolvedKeyboardAppearance: UIKeyboardAppearance {
        if #available(iOS 13.0, *) {
            return traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        return .default
    }

    func imeProxySnapshot() -> IMEProxySnapshot {
        IMEProxySnapshot(
            text: imeProxyTextView.text ?? "",
            selectedRange: imeProxyTextView.selectedRange,
            markedRange: imeProxyMarkedRange()
        )
    }

    func imeProxyMarkedRange() -> NSRange? {
        guard let range = imeProxyTextView.markedTextRange else { return nil }
        let start = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        let end = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.end)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func withSuppressedIMEProxyCallbacks<T>(_ body: () -> T) -> T {
        let previous = suppressIMEProxyCallbacks
        suppressIMEProxyCallbacks = true
        defer { suppressIMEProxyCallbacks = previous }
        return body()
    }

    private func resetIMEProxyState() {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.text = ""
            imeProxyTextView.selectedRange = NSRange(location: 0, length: 0)
            imeProxyTextView.unmarkText()
        }
    }

    func syncTextInputModelFromIMEProxy() {
        guard !suppressIMEProxyCallbacks else { return }
        let snapshot = imeProxySnapshot()
        let effects = textInputModel.handleExternalState(
            text: snapshot.text,
            selectedRange: .init(location: snapshot.selectedRange.location, length: snapshot.selectedRange.length),
            markedRange: snapshot.markedRange.map { .init(location: $0.location, length: $0.length) }
        )
        runTerminalTextInputEffects(effects)
        if snapshot.markedRange == nil {
            syncIMEPreedit(nil)
        }
    }

    var hasLocalTextInputSession: Bool {
        textInputModel.documentLength > 0 || textInputModel.hasActiveIMEComposition
    }

    private func setIMEProxySelection(_ range: NSRange) {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.selectedRange = range
        }
        syncTextInputModelFromIMEProxy()
    }

    func moveIMEProxyCursorLeft() {
        let selection = imeProxyTextView.selectedRange
        let nsText = (imeProxyTextView.text ?? "") as NSString
        let newLocation: Int
        if selection.length > 0 {
            newLocation = selection.location
        } else if selection.location > 0 {
            let previousRange = nsText.rangeOfComposedCharacterSequence(at: max(selection.location - 1, 0))
            newLocation = previousRange.location
        } else {
            newLocation = 0
        }
        setIMEProxySelection(NSRange(location: newLocation, length: 0))
    }

    func moveIMEProxyCursorRight() {
        let selection = imeProxyTextView.selectedRange
        let nsText = (imeProxyTextView.text ?? "") as NSString
        let newLocation: Int
        if selection.length > 0 {
            newLocation = selection.location + selection.length
        } else if selection.location < nsText.length {
            let nextRange = nsText.rangeOfComposedCharacterSequence(at: selection.location)
            newLocation = nextRange.location + nextRange.length
        } else {
            newLocation = nsText.length
        }
        setIMEProxySelection(NSRange(location: newLocation, length: 0))
    }

    func moveIMEProxyCursorToStart() {
        setIMEProxySelection(NSRange(location: 0, length: 0))
    }

    func moveIMEProxyCursorToEnd() {
        let length = (imeProxyTextView.text ?? "").utf16.count
        setIMEProxySelection(NSRange(location: length, length: 0))
    }

    func imeProxyDidDeleteBackward(before: IMEProxySnapshot?) {
        guard !suppressIMEProxyCallbacks else { return }
        let after = imeProxySnapshot()
        if before == after,
           let before,
           before.text.isEmpty,
           before.markedRange == nil,
           before.selectedRange.length == 0,
           before.selectedRange.location == 0 {
            runTerminalTextInputEffects([.sendSpecialKey(.backspace)])
            return
        }
        syncTextInputModelFromIMEProxy()
    }

    func imeProxyFocusDidChange(isFocused: Bool) {
        surfaceOwner.setFocus(isFocused)
        if isFocused {
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
        } else {
            imeProxyTextView.endDictationSession(commit: true)
            invalidateLocalTextInputSession()
            stopKeyRepeat()
        }
    }

    func imeProxyCaretRect(for position: UITextPosition) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: position)
        return textInputCaretRect(for: index)
    }

    func imeProxyFirstRect(for range: UITextRange) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        return textInputCaretRect(for: index)
    }

    func invalidateLocalTextInputSession() {
        resetIMEProxyState()
        let effects = textInputModel.invalidateSession()
        runTerminalTextInputEffects(effects)
        syncIMEPreedit(nil)
    }

    func runTerminalTextInputEffects(_ effects: [TerminalTextInputModel.Effect]) {
        inputRuntime.handleTerminalTextInputEffects(effects, context: terminalTextInputEffectExecutionContext())
    }

    func textInputCaretRect(for index: Int) -> CGRect {
        guard let imePoint = surfaceOwner.imePoint(using: inputRuntime) else {
            let metrics = textInputGridMetrics()
            return CGRect(x: 0, y: 0, width: metrics.cellSize.width, height: metrics.cellSize.height)
        }

        let cellWidth = max(cellSize.width, max(imePoint.width, 1))
        let cellHeight = max(cellSize.height, max(imePoint.height, 1))
        let currentCharacterIndex = textInputModel.committedCursorCharacterIndex
        let targetCharacterIndex = textInputModel.committedCharacterIndex(forDocumentOffset: clampTextInputIndex(index))
        let delta = targetCharacterIndex - currentCharacterIndex

        return CGRect(
            x: imePoint.minX + CGFloat(delta) * cellWidth,
            y: imePoint.minY,
            width: max(imePoint.width, cellWidth),
            height: max(imePoint.height, cellHeight)
        )
    }
}
#endif
