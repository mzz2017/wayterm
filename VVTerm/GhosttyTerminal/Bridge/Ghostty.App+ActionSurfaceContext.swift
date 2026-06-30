import Foundation

extension Ghostty.App {
    struct ActionSurfaceContext {
        let terminalView: GhosttyTerminalView?
        let titleTargetDescription: String
        let activeSurfaceCount: Int
    }

    static func dispatchActionSurfaceContext(
        app: ghostty_app_t,
        surface: ghostty_surface_t?,
        titleTargetDescription: String,
        _ body: @escaping @MainActor (ActionSurfaceContext) -> Void
    ) {
        DispatchQueue.main.async {
            body(actionSurfaceContext(app: app, surface: surface, titleTargetDescription: titleTargetDescription))
        }
    }

    @MainActor
    private static func actionSurfaceContext(
        app: ghostty_app_t,
        surface: ghostty_surface_t?,
        titleTargetDescription: String
    ) -> ActionSurfaceContext {
        guard let surface else {
            return ActionSurfaceContext(
                terminalView: nil,
                titleTargetDescription: titleTargetDescription,
                activeSurfaceCount: 0
            )
        }

        if let appUserdata = ghostty_app_userdata(app) {
            let appOwner = GhosttyAppCallbackContext.app(fromUserdata: appUserdata)
            let activeSurfaceCount = appOwner?.activeSurfaceCount() ?? 0
            if let registeredView = appOwner?.terminalView(for: surface) {
                return ActionSurfaceContext(
                    terminalView: registeredView,
                    titleTargetDescription: titleTargetDescription,
                    activeSurfaceCount: activeSurfaceCount
                )
            }

            guard let surfaceUserdata = ghostty_surface_userdata(surface) else {
                return ActionSurfaceContext(
                    terminalView: nil,
                    titleTargetDescription: titleTargetDescription,
                    activeSurfaceCount: activeSurfaceCount
                )
            }
            return ActionSurfaceContext(
                terminalView: GhosttySurfaceCallbackContext.terminalView(fromUserdata: surfaceUserdata),
                titleTargetDescription: titleTargetDescription,
                activeSurfaceCount: activeSurfaceCount
            )
        }

        guard let surfaceUserdata = ghostty_surface_userdata(surface) else {
            return ActionSurfaceContext(
                terminalView: nil,
                titleTargetDescription: titleTargetDescription,
                activeSurfaceCount: 0
            )
        }
        return ActionSurfaceContext(
            terminalView: GhosttySurfaceCallbackContext.terminalView(fromUserdata: surfaceUserdata),
            titleTargetDescription: titleTargetDescription,
            activeSurfaceCount: 0
        )
    }
}
