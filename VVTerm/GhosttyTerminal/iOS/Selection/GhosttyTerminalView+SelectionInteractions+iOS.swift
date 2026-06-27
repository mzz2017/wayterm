#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    var usesNativeTouchSelection: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
    
    var usesAppOwnedTouchSelection: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !usesNativeTouchSelection
    }
    
    func selectionGridMetrics() -> TerminalSelectionGridMetrics? {
        guard let terminalSize = terminalSize() else { return nil }
        let cols = max(Int(terminalSize.columns), 1)
        let rows = max(Int(terminalSize.rows), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : max(bounds.width / CGFloat(cols), 1)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : max(bounds.height / CGFloat(rows), 1)
        return TerminalSelectionGridMetrics(
            cols: cols,
            rows: rows,
            cellSize: CGSize(width: resolvedCellWidth, height: resolvedCellHeight)
        )
    }
    
    private func touchSelectionLayout() -> TerminalTouchSelectionLayout? {
        guard let metrics = selectionGridMetrics() else { return nil }
        return TerminalTouchSelectionLayout(metrics: metrics, bounds: bounds)
    }
    
    private func updateTouchSelectionOverlay() {
        guard usesAppOwnedTouchSelection,
              let touchSelection = touchSelectionState.selection,
              let layout = touchSelectionLayout() else {
            touchSelectionOverlay.isHidden = true
            touchSelectionOverlay.clear()
            return
        }
    
        let normalized = touchSelection.normalized
        let rects = layout.selectionRects(for: normalized)
        let startFrame = layout.cellFrame(for: normalized.start)
        let endFrame = layout.cellFrame(for: normalized.end)
        touchSelectionOverlay.isHidden = false
        touchSelectionOverlay.update(
            rects: rects,
            startAnchor: CGPoint(x: startFrame.minX, y: startFrame.minY),
            endAnchor: CGPoint(x: endFrame.maxX, y: endFrame.maxY)
        )
    }
    
    func isPointOnTouchSelectionHandle(_ point: CGPoint) -> Bool {
        guard usesAppOwnedTouchSelection, touchSelectionState.hasSelection else { return false }
    
        let startHandlePoint = touchSelectionOverlay.convert(point, from: self)
        return touchSelectionOverlay.startHandle.frame.insetBy(dx: -22, dy: -22).contains(startHandlePoint) ||
            touchSelectionOverlay.endHandle.frame.insetBy(dx: -22, dy: -22).contains(startHandlePoint)
    }
    
    private func dismissEditMenuIfNeeded() {
        editMenuInteraction?.dismissMenu()
    }
    
    func clearTouchSelection() {
        touchSelectionState.clear()
        updateTouchSelectionOverlay()
        touchSelectionLoupe.hideLoupe()
        isSelecting = false
    }
    
    private func updateTouchSelectionLoupe(at location: CGPoint) {
        guard usesAppOwnedTouchSelection else { return }
    
        let previousVisibility = touchSelectionLoupe.isHidden
        touchSelectionLoupe.isHidden = true
        touchSelectionLoupe.update(
            from: self,
            focusPoint: location,
            in: bounds,
            safeAreaInsets: safeAreaInsets
        )
        if previousVisibility {
            bringSubviewToFront(touchSelectionOverlay)
            bringSubviewToFront(touchSelectionLoupe)
        }
    }
    
    private func quickLookWordSelection(at location: CGPoint) -> TerminalGridSelection? {
        guard let layout = touchSelectionLayout(),
              let surface,
              let cSurface = surface.unsafeCValue else { return nil }
    
        let pos = ghosttyPoint(location)
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        return GhosttyTerminalTextReader.quickLookWordSelection(
            surface: cSurface,
            layout: layout
        )
    }
    
    private func startTouchSelection(at location: CGPoint) {
        let wordSelection = quickLookWordSelection(at: location)
        let point = touchSelectionLayout()?.gridPoint(for: location)
        guard touchSelectionState.begin(wordSelection: wordSelection, point: point) else {
            return
        }
        updateTouchSelectionOverlay()
        isSelecting = true
    }
    
    private func updateTouchSelection(at location: CGPoint) {
        guard let point = touchSelectionLayout()?.gridPoint(for: location) else { return }
        if touchSelectionState.update(to: point) {
            updateTouchSelectionOverlay()
            isSelecting = true
        }
    }
    
    private func updateTouchSelectionHandle(_ kind: TerminalTouchSelectionHandleKind, at location: CGPoint) {
        guard let point = touchSelectionLayout()?.gridPoint(for: location) else { return }
        guard touchSelectionState.updateHandle(kind, to: point) else { return }
        updateTouchSelectionOverlay()
    }
    
    private func finishTouchSelection() {
        isSelecting = false
        touchSelectionLoupe.hideLoupe()
        guard let touchSelection = touchSelectionState.selection,
              let menuPoint = touchSelectionLayout()?.menuPoint(for: touchSelection) else { return }
        showEditMenu(at: menuPoint)
    }
    
    func currentSelectionText() -> String? {
        if let nativeSelectionText = selectedNativeSelectionText() {
            return nativeSelectionText
        }
        if let touchSelectionText = touchSelectionText() {
            return touchSelectionText
        }
        return ghosttySelectionText()
    }
    
    private func touchSelectionText() -> String? {
        guard let touchSelection = touchSelectionState.selection,
              let surface = surface?.unsafeCValue else { return nil }
    
        let normalized = touchSelection.normalized
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(normalized.start.column),
                y: UInt32(normalized.start.row)
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(normalized.end.column),
                y: UInt32(normalized.end.row)
            ),
            rectangle: false
        )
        return GhosttyTerminalTextReader.readText(surface: surface, selection: selection)
    }
    
    private func ghosttySelectionText() -> String? {
        guard let surface = surface?.unsafeCValue else { return nil }
        return GhosttyTerminalTextReader.readSelection(surface: surface)
    }
    
    private func copyTextToClipboard(_ text: String) {
        let cleaned = TerminalTextCleaner.cleanText(text, settings: .current())
        Clipboard.copy(cleaned)
    }
    
    func normalizedSelectionMenuText() -> String? {
        guard let text = currentSelectionText()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
    
    private func selectionMenuSourceRect() -> CGRect {
        if usesNativeTouchSelection,
           let selectedTextRange {
            let rect = firstRect(for: selectedTextRange)
            if !rect.isNull, !rect.isEmpty {
                return rect
            }
        }
        return CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
    }
    
    private func presentSelectionMenuController(_ controller: UIViewController) {
        presentationEnvironment.presentController(controller, self, selectionMenuSourceRect())
    }
    
    private func presentShareSheet(for text: String) {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        presentSelectionMenuController(controller)
    }
    
    private func presentDictionaryLookup(for text: String) {
        guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text) else { return }
        let controller = UIReferenceLibraryViewController(term: text)
        presentSelectionMenuController(controller)
    }
    
    private func searchWeb(for text: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components?.url else { return }
        presentationEnvironment.openURL(url)
    }
    
    @available(iOS 16.0, *)
    func nativeSelectionMenuElements() -> [UIMenuElement] {
        let selectionText = normalizedSelectionMenuText()
        var actions: [UIMenuElement] = []
    
        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }
    
        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })
    
        if nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil {
            actions.append(UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.selectAll(nil)
            })
        }
    
        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Find"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.presentFindNavigator(prefillingSelectedText: true)
            })
        }
    
        return actions
    }
    
    private func selectAllVisibleText() {
        if usesNativeTouchSelection {
            refreshNativeSelectionSnapshot()
            guard nativeSelectionSnapshot.length > 0 else { return }
            setNativeSelectedRange(NSRange(location: 0, length: nativeSelectionSnapshot.length))
            return
        }
    
        guard usesAppOwnedTouchSelection,
              let metrics = selectionGridMetrics() else { return }
        touchSelectionState.setSelection(TerminalGridSelection(
            start: TerminalGridPoint(row: 0, column: 0),
            end: TerminalGridPoint(row: metrics.rows - 1, column: metrics.cols - 1)
        ))
        updateTouchSelectionOverlay()
        finishTouchSelection()
    }
    
    // MARK: - Selection Gestures
    
    /// Double-tap to select word
    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)
    
        clearTouchSelection()
        requestKeyboardFocus(for: .selectionGesture)
    
        // Double-click to select word (no modifiers)
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        requestRender()
    
        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }
    
    /// Triple-tap to select line
    @objc func handleTripleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)
    
        clearTouchSelection()
        requestKeyboardFocus(for: .selectionGesture)
    
        // Triple-click to select line
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        for _ in 0..<3 {
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        }
        requestRender()
    
        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }
    
    /// Long press + drag for custom selection
    @objc func handleSelectionPress(_ recognizer: UILongPressGestureRecognizer) {
        if usesAppOwnedTouchSelection {
            let location = recognizer.location(in: self)
    
            switch recognizer.state {
            case .began:
                dismissEditMenuIfNeeded()
                startTouchSelection(at: location)
                requestKeyboardFocus(for: .selectionGesture)
                updateTouchSelectionLoupe(at: location)
            case .changed:
                updateTouchSelection(at: location)
                updateTouchSelectionLoupe(at: location)
            case .ended:
                updateTouchSelection(at: location)
                finishTouchSelection()
            case .cancelled, .failed:
                clearTouchSelection()
            default:
                break
            }
            return
        }
    
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)
    
        switch recognizer.state {
        case .began:
            isSelecting = true
            requestKeyboardFocus(for: .selectionGesture)
            // Start selection with click (no shift for initial position)
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            requestRender()
        case .changed:
            // Drag to extend selection
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            requestRender()
        case .ended, .cancelled, .failed:
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
            isSelecting = false
            requestRender()
            showEditMenu(at: location)
        default:
            break
        }
    }
    
    @objc func handleSelectionHandlePan(_ recognizer: UIPanGestureRecognizer) {
        guard usesAppOwnedTouchSelection, touchSelectionState.hasSelection else { return }
    
        let kind: TerminalTouchSelectionHandleKind
        if recognizer.view === touchSelectionOverlay.startHandle {
            kind = .start
        } else {
            kind = .end
        }
    
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            dismissEditMenuIfNeeded()
            isSelecting = true
            updateTouchSelectionHandle(kind, at: location)
            updateTouchSelectionLoupe(at: location)
        case .changed:
            updateTouchSelectionHandle(kind, at: location)
            updateTouchSelectionLoupe(at: location)
        case .ended:
            updateTouchSelectionHandle(kind, at: location)
            isSelecting = false
            finishTouchSelection()
        case .cancelled, .failed:
            isSelecting = false
            touchSelectionLoupe.hideLoupe()
        default:
            break
        }
    }
    
    private func showEditMenu(at location: CGPoint) {
        let hasGhosttySelection = selectionRuntime.hasGhosttySelection(surface: surface?.unsafeCValue)
        guard touchSelectionState.hasSelection || hasGhosttySelection else {
            return
        }
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        editMenuInteraction?.presentEditMenu(with: config)
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            if let nativeSelectedRange, nativeSelectedRange.length > 0 {
                return true
            }
            if touchSelectionState.hasSelection {
                return true
            }
            return selectionRuntime.hasGhosttySelection(surface: surface?.unsafeCValue)
        case #selector(selectAll(_:)):
            if usesNativeTouchSelection {
                return nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil
            }
            return usesAppOwnedTouchSelection && selectionGridMetrics() != nil
        case #selector(find(_:)):
            return usesNativeTouchSelection
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            if #available(iOS 16.0, *), usesNativeTouchSelection {
                return nativeFindInteraction?.isFindNavigatorVisible == true
            }
            return false
        case #selector(useSelectionForFind(_:)):
            if usesNativeTouchSelection {
                return normalizedSelectionMenuText() != nil
            }
            return false
        case #selector(paste(_:)):
            return true
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }
    
    @objc override func copy(_ sender: Any?) {
        guard let selectionText = currentSelectionText(), !selectionText.isEmpty else { return }
        copyTextToClipboard(selectionText)
    }
    
    @objc override func selectAll(_ sender: Any?) {
        selectAllVisibleText()
    }
    
    @objc override func paste(_ sender: Any?) {
        performPasteAction()
    }
    
    @objc override func find(_ sender: Any?) {
        showFindNavigator()
    }
    
    @objc override func useSelectionForFind(_ sender: Any?) {
        showFindNavigator(prefillingSelectedText: true)
    }
    
    @objc override func findNext(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findNext()
    }
    
    @objc override func findPrevious(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findPrevious()
    }
    
    func clearSelectionAfterPaste() {
        if usesNativeTouchSelection, nativeSelectedRange != nil {
            setNativeSelectedRange(nil)
            prefersNativeSelectionFirstResponder = false
        }
        if usesAppOwnedTouchSelection, touchSelectionState.hasSelection {
            clearTouchSelection()
        }
    }
}
#endif
