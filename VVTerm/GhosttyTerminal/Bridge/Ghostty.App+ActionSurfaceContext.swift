import Foundation

extension Ghostty.App {
    struct ActionSurfaceContext {
        let terminalView: GhosttyTerminalView?
        let titleTargetDescription: String
        let activeSurfaceCount: Int
    }

    static func dispatchActionSurfaceContext(
        appContext: GhosttyAppCallbackContext?,
        surfaceContext: GhosttySurfaceCallbackContext?,
        titleTargetDescription: String,
        _ body: @escaping @MainActor (ActionSurfaceContext) -> Void
    ) {
        DispatchQueue.main.async {
            body(actionSurfaceContext(
                appContext: appContext,
                surfaceContext: surfaceContext,
                titleTargetDescription: titleTargetDescription
            ))
        }
    }

    @MainActor
    private static func actionSurfaceContext(
        appContext: GhosttyAppCallbackContext?,
        surfaceContext: GhosttySurfaceCallbackContext?,
        titleTargetDescription: String
    ) -> ActionSurfaceContext {
        return ActionSurfaceContext(
            terminalView: surfaceContext?.resolveTerminalView(),
            titleTargetDescription: titleTargetDescription,
            activeSurfaceCount: appContext?.resolveApp()?.activeSurfaceCount() ?? 0
        )
    }
}
