import Foundation

nonisolated final class TerminalThemeNotificationObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func append(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        let tokensToRemove = tokens
        tokens.removeAll()
        lock.unlock()

        for token in tokensToRemove {
            notificationCenter.removeObserver(token)
        }
    }

    deinit {
        invalidateAll()
    }
}
