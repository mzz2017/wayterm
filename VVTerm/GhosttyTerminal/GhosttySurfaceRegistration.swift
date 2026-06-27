import Foundation

nonisolated final class GhosttySurfaceRegistration {
    private weak var appWrapper: Ghostty.App?
    private var reference: Ghostty.SurfaceReference?

    @MainActor
    func register(_ surface: ghostty_surface_t, appWrapper: Ghostty.App?, terminalView: GhosttyTerminalView) {
        unregister()
        guard let appWrapper else { return }
        self.appWrapper = appWrapper
        reference = appWrapper.registerSurface(surface, terminalView: terminalView)
    }

    @MainActor
    func unregister() {
        if let appWrapper, let reference {
            appWrapper.unregisterSurface(reference)
        }
        appWrapper = nil
        reference = nil
    }

    nonisolated func unregisterLaterFromDeinit() {
        let appWrapper = appWrapper
        let reference = reference
        self.appWrapper = nil
        self.reference = nil

        guard let appWrapper, let reference else { return }
        Task { @MainActor in
            appWrapper.unregisterSurface(reference)
        }
    }
}
