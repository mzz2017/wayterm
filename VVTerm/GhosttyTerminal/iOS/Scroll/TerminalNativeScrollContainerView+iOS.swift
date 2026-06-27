#if os(iOS)
import UIKit

private final class TerminalHostScrollView: UIScrollView {
    var shouldBeginHostPan: (() -> Bool)?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            guard abs(velocity.y) >= abs(velocity.x) else { return false }
            return shouldBeginHostPan?() ?? true
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

final class TerminalNativeScrollContainerView: UIView {
    static let featureFlagKey = "iosNativeTerminalScroll"

    static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: featureFlagKey) as? Bool {
            return stored
        }
        return true
    }

    let terminalView: GhosttyTerminalView

    private let scrollView = TerminalHostScrollView()
    private let virtualContentView = UIView()
    private var scrollbarObserver: NSObjectProtocol?
    private var cellSizeObserver: NSObjectProtocol?
    private var lastSentRow: Int?
    private var isSynchronizingFromTerminal = false
    private var isDetachedForReuse = false

    init(terminalView: GhosttyTerminalView) {
        self.terminalView = terminalView
        super.init(frame: terminalView.frame)

        backgroundColor = .clear
        isOpaque = false

        scrollView.backgroundColor = .clear
        scrollView.isOpaque = false
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .none
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.scrollsToTop = false
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.delegate = self
        scrollView.shouldBeginHostPan = { [weak terminalView] in
            terminalView?.currentScrollOwner() == .hostScrollback
        }

        virtualContentView.backgroundColor = .clear
        virtualContentView.isOpaque = false
        virtualContentView.isUserInteractionEnabled = false

        addSubview(scrollView)
        scrollView.addSubview(virtualContentView)

        Self.detachExistingContainer(containing: terminalView)
        scrollView.addSubview(terminalView)
        terminalView.setNativeHostScrollContainerEnabled(true)

        scrollbarObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: terminalView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        }
        cellSizeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNativeScrollState()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeObservers()
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            removeObservers()
            disableNativeHostScrollContainerIfOwned()
        }
        super.willMove(toSuperview: newSuperview)
    }

    static func nativeScrollContainer(containing terminalView: GhosttyTerminalView) -> TerminalNativeScrollContainerView? {
        var view = terminalView.superview
        while let current = view {
            if let container = current as? TerminalNativeScrollContainerView {
                return container
            }
            view = current.superview
        }
        return nil
    }

    static func detachExistingContainer(containing terminalView: GhosttyTerminalView) {
        if let container = nativeScrollContainer(containing: terminalView) {
            container.detachTerminalForReuse()
        } else if terminalView.superview != nil {
            terminalView.removeFromSuperview()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateContentSize()
        synchronizeScrollPositionFromTerminalIfNeeded()
        positionTerminalViewport()
    }

    func refreshNativeScrollState() {
        updateContentSize()
        synchronizeScrollPositionFromTerminalIfNeeded()
        positionTerminalViewport()
    }

    func refreshTerminalViewport() -> CGSize {
        setNeedsLayout()
        layoutIfNeeded()
        refreshNativeScrollState()
        return scrollView.bounds.size
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[Notification.Name.ScrollbarKey] as? Ghostty.Action.Scrollbar else {
            return
        }

        terminalView.scrollbar = scrollbar
        updateContentSize()
        synchronizeScrollPositionFromTerminalIfNeeded()
        positionTerminalViewport()
    }

    private func updateContentSize() {
        let height: CGFloat
        if let geometry = scrollGeometry() {
            height = CGFloat(geometry.contentHeight(viewportHeight: Double(scrollView.bounds.height)))
        } else {
            height = scrollView.bounds.height
        }

        let contentSize = CGSize(
            width: max(scrollView.bounds.width, 1),
            height: max(height, scrollView.bounds.height)
        )
        if scrollView.contentSize != contentSize {
            scrollView.contentSize = contentSize
        }
        virtualContentView.frame = CGRect(origin: .zero, size: contentSize)
    }

    private func synchronizeScrollPositionFromTerminalIfNeeded() {
        guard !isUserScrolling else { return }
        guard let scrollbar = terminalView.scrollbar,
              let geometry = scrollGeometry() else {
            return
        }

        let targetRow = intClamped(scrollbar.offset)
        let targetOffsetY = clampContentOffsetY(CGFloat(geometry.contentOffsetY(forRow: targetRow)))
        guard abs(scrollView.contentOffset.y - targetOffsetY) > 0.5 else {
            lastSentRow = geometry.row(forContentOffsetY: Double(targetOffsetY))
            return
        }

        isSynchronizingFromTerminal = true
        scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
        isSynchronizingFromTerminal = false
        lastSentRow = geometry.row(forContentOffsetY: Double(targetOffsetY))
    }

    private func positionTerminalViewport() {
        let viewportFrame = CGRect(
            x: 0,
            y: scrollView.contentOffset.y,
            width: scrollView.bounds.width,
            height: scrollView.bounds.height
        )
        if terminalView.frame != viewportFrame {
            terminalView.frame = viewportFrame
        }
    }

    private func scrollGeometry() -> TerminalScrollGeometry? {
        guard let scrollbar = terminalView.scrollbar else { return nil }
        let cellHeight = Double(terminalView.cellSize.height)
        guard cellHeight > 0 else { return nil }
        return TerminalScrollGeometry(
            totalRows: intClamped(scrollbar.total),
            visibleRows: intClamped(scrollbar.len),
            cellHeight: cellHeight
        )
    }

    private var isUserScrolling: Bool {
        scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    private func clampContentOffsetY(_ offsetY: CGFloat) -> CGFloat {
        min(max(offsetY, 0), max(scrollView.contentSize.height - scrollView.bounds.height, 0))
    }

    private func intClamped(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private func detachTerminalForReuse() {
        removeObservers()
        isDetachedForReuse = true
        scrollView.shouldBeginHostPan = nil
        terminalView.removeFromSuperview()
        terminalView.setNativeHostScrollContainerEnabled(false)
    }

    private func disableNativeHostScrollContainerIfOwned() {
        guard !isDetachedForReuse, terminalView.superview === scrollView else { return }
        terminalView.setNativeHostScrollContainerEnabled(false)
    }

    private func removeObservers() {
        if let scrollbarObserver {
            NotificationCenter.default.removeObserver(scrollbarObserver)
            self.scrollbarObserver = nil
        }
        if let cellSizeObserver {
            NotificationCenter.default.removeObserver(cellSizeObserver)
            self.cellSizeObserver = nil
        }
    }
}

extension TerminalNativeScrollContainerView: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        terminalView.prepareForNativeHostScroll()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionTerminalViewport()
        guard !isSynchronizingFromTerminal else { return }
        guard terminalView.currentScrollOwner() == .hostScrollback else { return }
        guard let geometry = scrollGeometry() else { return }

        let row = geometry.row(forContentOffsetY: Double(scrollView.contentOffset.y))
        guard row != lastSentRow else { return }
        lastSentRow = row
        terminalView.surfaceOwner.perform(action: "scroll_to_row:\(row)")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            synchronizeScrollPositionFromTerminalIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        synchronizeScrollPositionFromTerminalIfNeeded()
    }
}

#endif
