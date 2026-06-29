import Foundation

nonisolated final class GhosttySurfaceRegistration: @unchecked Sendable {
    private static let deferredUnregisterTasks = GhosttySurfaceDeferredUnregisterTaskRegistry()

    private let lock = NSLock()
    private weak var appWrapper: Ghostty.App?
    private var reference: Ghostty.SurfaceReference?

    @MainActor
    func register(_ surface: ghostty_surface_t, appWrapper: Ghostty.App?, terminalView: GhosttyTerminalView) {
        unregister()
        guard let appWrapper else { return }
        let reference = appWrapper.registerSurface(surface, terminalView: terminalView)

        lock.lock()
        self.appWrapper = appWrapper
        self.reference = reference
        lock.unlock()
    }

    @MainActor
    func unregister() {
        let (appWrapper, reference) = takeReference()
        if let appWrapper, let reference {
            appWrapper.unregisterSurface(reference)
        }
    }

    @discardableResult
    nonisolated func unregisterLaterFromDeinit() -> UUID? {
        let (appWrapper, reference) = takeReference()

        guard let appWrapper, let reference else { return nil }
        return Self.deferredUnregisterTasks.track {
            appWrapper.unregisterSurface(reference)
        }
    }

    nonisolated static func waitForDeferredUnregisters() async {
        await deferredUnregisterTasks.waitForAll()
    }

    private func takeReference() -> (Ghostty.App?, Ghostty.SurfaceReference?) {
        lock.lock()
        let appWrapper = appWrapper
        let reference = reference
        self.appWrapper = nil
        self.reference = nil
        lock.unlock()

        return (appWrapper, reference)
    }
}

nonisolated final class GhosttySurfaceDeferredUnregisterTaskRegistry: @unchecked Sendable {
    private let registry = AsyncCallbackTaskRegistry()

    @discardableResult
    func track(_ operation: @escaping @MainActor @Sendable () -> Void) -> UUID {
        registry.trackMainActor {
            operation()
        }
    }

    func waitForAll() async {
        await registry.waitForAll()
    }
}
