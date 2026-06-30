import Foundation

/// App-level userdata context for libghostty runtime callbacks.
///
/// Ghostty owns the raw userdata pointer only while `Ghostty.App` owns the
/// `ghostty_app_t` handle. The context lets cleanup invalidate callbacks before
/// freeing the handle without passing a raw App pointer through C.
nonisolated final class GhosttyAppCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var app: Ghostty.App?
    private var isValid = true

    @MainActor
    init(app: Ghostty.App? = nil) {
        self.app = app
    }

    @MainActor
    func bind(_ app: Ghostty.App) {
        lock.lock()
        self.app = app
        isValid = true
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        isValid = false
        app = nil
        lock.unlock()
    }

    func resolveApp() -> Ghostty.App? {
        lock.lock()
        defer { lock.unlock() }
        guard isValid else { return nil }
        return app
    }

    var opaquePointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func context(fromUserdata pointer: UnsafeMutableRawPointer?) -> GhosttyAppCallbackContext? {
        guard let pointer else { return nil }
        return Unmanaged<GhosttyAppCallbackContext>
            .fromOpaque(pointer)
            .takeUnretainedValue()
    }

    static func app(fromUserdata pointer: UnsafeMutableRawPointer?) -> Ghostty.App? {
        context(fromUserdata: pointer)?.resolveApp()
    }
}
