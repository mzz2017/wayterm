#if os(iOS)
import UIKit

// MARK: - Software Keyboard (UIKeyInput)

extension GhosttyTerminalView: UIKeyInput, UITextInputTraits {
    var hasText: Bool {
        if isNativeSelectionTextInputContext {
            return nativeSelectionSnapshot.length > 0 || (nativeSelectedRange?.length ?? 0) > 0
        }
        return true
    }

    func insertText(_ text: String) {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        let normalized = text.precomposedStringWithCanonicalMapping
        let wasComposing = textInputModel.hasActiveIMEComposition
        _ = handleIMEProxyInsertText(normalized, fromIMEComposition: wasComposing)
    }

    func deleteBackward() {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        runTerminalTextInputEffects(textInputModel.handleDeleteBackward())
    }

    func consumePendingSystemTextInputHardwareKey() -> UIKey? {
        hardwarePressState.consumePendingSystemTextInputHardwareKey()
    }

    func discardPendingSystemTextInputHardwareKey() {
        hardwarePressState.discardPendingSystemTextInputHardwareKey()
    }

    func removeUnconsumedPendingSystemTextInputHardwareKeys(after pendingCount: Int) {
        hardwarePressState.removeUnconsumedPendingSystemTextInputHardwareKeys(after: pendingCount)
    }

    @discardableResult
    func sendInterpretedHardwareKeyText(_ text: String, for key: UIKey) -> Bool {
        guard canRouteTerminalInput, surfaceOwner.hasLiveSurface else { return false }
        guard let sourceEvent = Ghostty.Input.KeyEvent(uiKey: key, action: .press) else {
            sendText(text)
            return true
        }
        let keyCode = UInt16(key.keyCode.rawValue)
        let interpretedEvent = Ghostty.Input.KeyEvent(
            key: sourceEvent.key,
            action: .press,
            text: text.isEmpty ? sourceEvent.text : text,
            composing: false,
            mods: sourceEvent.mods,
            consumedMods: sourceEvent.consumedMods,
            unshiftedCodepoint: sourceEvent.unshiftedCodepoint
        )
        surfaceOwner.sendKeyEvent(interpretedEvent)
        hardwarePressState.recordInterpretedHardwareKey(keyCode: keyCode)
        requestRender()
        return true
    }

    var pendingSystemTextInputHardwareKeyCount: Int {
        hardwarePressState.pendingSystemTextInputHardwareKeyCount
    }

    var keyboardType: UIKeyboardType {
        get { .default }
        set { }
    }

    var keyboardAppearance: UIKeyboardAppearance {
        get { resolvedKeyboardAppearance }
        set { }
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set { }
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set { }
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set { }
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set { }
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set { }
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set { }
    }

    @available(iOS 17.0, *)
    var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set { }
    }

    var enablesReturnKeyAutomatically: Bool {
        get { false }
        set { }
    }

    var returnKeyType: UIReturnKeyType {
        get { .default }
        set { }
    }
}

// MARK: - UITextInput (spacebar cursor control)

extension GhosttyTerminalView: UITextInput {
    var isNativeSelectionTextInputContext: Bool {
        usesNativeTouchSelection
            && (nativeSelectionInteractionActive || nativeSelectedRange != nil || prefersNativeSelectionFirstResponder || isFindNavigatorActive)
    }

    private var activeTextInputDocumentLength: Int {
        isNativeSelectionTextInputContext ? nativeSelectionSnapshot.length : textInputModel.documentLength
    }

    private var activeTextInputColumns: Int {
        isNativeSelectionTextInputContext ? nativeSelectionSnapshot.columns : textInputGridMetrics().cols
    }

    private func activeClampedTextInputOffset(_ offset: Int) -> Int {
        min(max(offset, 0), activeTextInputDocumentLength)
    }

    private func terminalTextRange(_ range: TerminalTextInputModel.Range?) -> TerminalNativeTextRange? {
        guard let range else { return nil }
        let location = activeClampedTextInputOffset(range.location)
        let end = activeClampedTextInputOffset(range.location + range.length)
        return TerminalNativeTextRange(start: location, end: end)
    }

    private func terminalTextInputRange(from range: UITextRange?) -> TerminalTextInputModel.Range? {
        guard let range = range as? TerminalNativeTextRange else { return nil }
        let location = activeClampedTextInputOffset(range.nsRange.location)
        let end = activeClampedTextInputOffset(range.nsRange.location + range.nsRange.length)
        return .init(location: location, length: max(end - location, 0))
    }

    var selectedTextRange: UITextRange? {
        get {
            if isNativeSelectionTextInputContext {
                return nativeSelectionSnapshot.nativeRange(nativeSelectedRange)
            }
            return terminalTextRange(textInputModel.selectedRange)
        }
        set {
            if isNativeSelectionTextInputContext {
                setNativeSelectedRange(nativeSelectionSnapshot.nativeRange(from: newValue))
                return
            }
            guard let range = terminalTextInputRange(from: newValue) else { return }
            runTerminalTextInputEffects(textInputModel.handleSetSelection(location: range.location, length: range.length))
        }
    }

    var markedTextRange: UITextRange? {
        isNativeSelectionTextInputContext ? nil : terminalTextRange(textInputModel.markedRange)
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { }
    }

    var inputDelegate: UITextInputDelegate? {
        get { nativeTextInputDelegate }
        set { nativeTextInputDelegate = newValue }
    }

    var tokenizer: UITextInputTokenizer {
        nativeSelectionTokenizer
    }

    var beginningOfDocument: UITextPosition {
        TerminalNativeTextPosition(offset: 0)
    }

    var endOfDocument: UITextPosition {
        TerminalNativeTextPosition(offset: activeTextInputDocumentLength)
    }

    func text(in range: UITextRange) -> String? {
        if isNativeSelectionTextInputContext {
            guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return nil }
            return nativeSelectionSnapshot.text(in: range)
        }
        guard let range = terminalTextInputRange(from: range) else { return nil }
        return textInputModel.substring(rangeStart: range.location, rangeEnd: range.location + range.length)
    }

    func replace(_ range: UITextRange, withText text: String) {
        if isNativeSelectionTextInputContext {
            guard !text.isEmpty else { return }
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
            _ = handleIMEProxyInsertText(text, fromIMEComposition: false)
            return
        }
        let replacementRange = terminalTextInputRange(from: range)
        runTerminalTextInputEffects(
            textInputModel.handleReplace(
                rangeStart: replacementRange?.location,
                rangeEnd: replacementRange.map { $0.location + $0.length },
                text: text
            )
        )
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        discardPendingSystemTextInputHardwareKey()
        runTerminalTextInputEffects(
            textInputModel.handleSetMarkedText(
                markedText,
                selectedRangeLocation: selectedRange.location,
                selectedRangeLength: selectedRange.length
            )
        )
    }

    func unmarkText() {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        discardPendingSystemTextInputHardwareKey()
        runTerminalTextInputEffects(textInputModel.handleUnmarkText())
    }

    var textInputView: UIView {
        self
    }

    var selectionAffinity: UITextStorageDirection {
        get { nativeSelectionAffinity }
        set { nativeSelectionAffinity = newValue }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalNativeTextPosition,
              let to = toPosition as? TerminalNativeTextPosition else { return nil }
        return TerminalNativeTextRange(start: from.offset, end: to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }
        return TerminalNativeTextPosition(offset: activeClampedTextInputOffset(position.offset + offset))
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }

        let delta: Int
        switch direction {
        case .left:
            delta = -offset
        case .right:
            delta = offset
        case .up:
            delta = -(offset * activeTextInputColumns)
        case .down:
            delta = offset * activeTextInputColumns
        @unknown default:
            delta = offset
        }

        return TerminalNativeTextPosition(offset: activeClampedTextInputOffset(position.offset + delta))
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let position = position as? TerminalNativeTextPosition,
              let other = other as? TerminalNativeTextPosition else { return .orderedSame }
        if position.offset < other.offset { return .orderedAscending }
        if position.offset > other.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to other: UITextPosition) -> Int {
        guard let from = from as? TerminalNativeTextPosition,
              let other = other as? TerminalNativeTextPosition else { return 0 }
        return other.offset - from.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = terminalTextInputRange(from: range) else { return nil }
        switch direction {
        case .left, .up:
            return TerminalNativeTextPosition(offset: range.location)
        case .right, .down:
            return TerminalNativeTextPosition(offset: range.location + range.length)
        @unknown default:
            return TerminalNativeTextPosition(offset: range.location + range.length)
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }
        switch direction {
        case .left, .up:
            let start = activeClampedTextInputOffset(position.offset - 1)
            return TerminalNativeTextRange(start: start, end: position.offset)
        case .right, .down:
            let end = activeClampedTextInputOffset(position.offset + 1)
            return TerminalNativeTextRange(start: position.offset, end: end)
        @unknown default:
            let end = activeClampedTextInputOffset(position.offset + 1)
            return TerminalNativeTextRange(start: position.offset, end: end)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
    }

    func firstRect(for range: UITextRange) -> CGRect {
        if isNativeSelectionTextInputContext {
            guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return .zero }
            return nativeSelectionSnapshot.firstRect(for: range)
        }
        guard let range = terminalTextInputRange(from: range) else { return .zero }
        return textInputCaretRect(for: range.location)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let position = position as? TerminalNativeTextPosition else { return .zero }
        if isNativeSelectionTextInputContext {
            return nativeSelectionSnapshot.caretRect(for: position.offset)
        }
        return textInputCaretRect(for: position.offset)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard isNativeSelectionTextInputContext else { return [] }
        guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return [] }
        return nativeSelectionSnapshot.selectionRects(for: range)
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard isNativeSelectionTextInputContext else {
            return TerminalNativeTextPosition(offset: textInputModel.cursorIndex)
        }
        return TerminalNativeTextPosition(offset: nativeSelectionSnapshot.offset(for: point))
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard isNativeSelectionTextInputContext else {
            return closestPosition(to: point)
        }
        guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return nil }
        let offset = nativeSelectionSnapshot.offset(for: point)
        let clamped = min(max(offset, range.location), range.location + range.length)
        return TerminalNativeTextPosition(offset: clamped)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard isNativeSelectionTextInputContext else {
            let offset = activeClampedTextInputOffset(textInputModel.cursorIndex)
            return TerminalNativeTextRange(start: offset, end: offset)
        }
        guard let range = nativeSelectionSnapshot.characterRange(at: point) else { return nil }
        return TerminalNativeTextRange(start: range.location, end: range.location + range.length)
    }

    func textStyling(at position: UITextPosition, in direction: UITextStorageDirection) -> [NSAttributedString.Key: Any]? {
        nil
    }

    @available(iOS 16.0, *)
    func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard usesNativeTouchSelection else { return nil }
        return UIMenu(children: nativeSelectionMenuElements())
    }

    func position(within range: UITextRange, atCharacterOffset offset: Int) -> UITextPosition? {
        guard let range = terminalTextInputRange(from: range) else { return nil }
        return TerminalNativeTextPosition(offset: activeClampedTextInputOffset(range.location + offset))
    }

    func characterOffset(of position: UITextPosition, within range: UITextRange) -> Int {
        guard let position = position as? TerminalNativeTextPosition,
              let range = terminalTextInputRange(from: range) else { return 0 }
        return position.offset - range.location
    }
}
#endif
