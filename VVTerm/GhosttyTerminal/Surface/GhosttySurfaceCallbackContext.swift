import Foundation

protocol GhosttySurfaceCallbackInvalidating: Sendable {
    nonisolated func invalidate()
}

nonisolated final class GhosttySurfaceCallbackContext: GhosttySurfaceCallbackInvalidating, @unchecked Sendable {
    private let lock = NSLock()
    private weak var terminalView: GhosttyTerminalView?
    private var isValid = true

    init(terminalView: GhosttyTerminalView) {
        self.terminalView = terminalView
    }

    nonisolated func invalidate() {
        lock.lock()
        isValid = false
        terminalView = nil
        lock.unlock()
    }

    func resolveTerminalView() -> GhosttyTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        guard isValid else { return nil }
        return terminalView
    }

    var opaquePointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func terminalView(fromUserdata pointer: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let pointer else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>
            .fromOpaque(pointer)
            .takeUnretainedValue()
            .resolveTerminalView()
    }

    static func terminalView(fromSurface surface: ghostty_surface_t?) -> GhosttyTerminalView? {
        guard let surface else { return nil }
        return terminalView(fromUserdata: ghostty_surface_userdata(surface))
    }
}
