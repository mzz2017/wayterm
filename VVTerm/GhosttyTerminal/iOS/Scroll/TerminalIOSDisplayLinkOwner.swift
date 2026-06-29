#if os(iOS)
import UIKit

nonisolated final class TerminalIOSDisplayLinkOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var displayLink: CADisplayLink?

    deinit {
        invalidate()
    }

    func replace(with displayLink: CADisplayLink) {
        invalidate()

        lock.lock()
        self.displayLink = displayLink
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let displayLinkToInvalidate = displayLink
        displayLink = nil
        lock.unlock()

        displayLinkToInvalidate?.invalidate()
    }
}

#endif
