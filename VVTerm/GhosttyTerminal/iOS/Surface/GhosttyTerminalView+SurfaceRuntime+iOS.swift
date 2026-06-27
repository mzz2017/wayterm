#if os(iOS)
import OSLog
import UIKit

extension GhosttyTerminalView {
    // MARK: - Process Lifecycle

    /// Create and configure the Ghostty surface.
    func setupSurface() {
        let app = surfaceOwner.ghosttyApp

        let callbackContext = GhosttySurfaceCallbackContext(terminalView: self)
        guard let cSurface = renderingSetup.setupSurface(
            view: self,
            ghosttyApp: app,
            worktreePath: worktreePath,
            initialBounds: bounds,
            surfaceCallbackContext: callbackContext,
            paneId: paneId,
            command: initialCommand,
            useCustomIO: useCustomIO
        ) else {
            return
        }

        // Ghostty's iOS renderer adds IOSurface layers that need immediate sizing
        // before frame callbacks can be accepted.
        configureIOSurfaceLayers(size: bounds.size)

        surface = Ghostty.Surface(cSurface: cSurface, callbackContext: callbackContext)
        surfaceRegistration.register(cSurface, appWrapper: surfaceOwner.appWrapper, terminalView: self)

        Self.logger.info("Ghostty surface created, sublayers: \(self.layer.sublayers?.count ?? 0)")
    }

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this in dismantleUIView to ensure proper cleanup.
    func cleanup() {
        isShuttingDown = true
        isPaused = true
        surfaceOwner.cleanup(
            using: surfaceLifecycleRuntime,
            surfaceRegistration: surfaceRegistration,
            stopMomentumScrolling: { [scrollRuntime] in
                scrollRuntime.stopMomentumScrolling()
            },
            cancelPendingZoomIndicatorHide: { [zoomRuntime] in
                zoomRuntime.cancelPendingIndicatorHide()
            },
            invalidateLifecycleObservers: { [lifecycleObservers] in
                lifecycleObservers.invalidateAll()
            },
            clearCallbacks: { [weak self] in
                self?.clearLifecycleCallbacks()
            }
        )
    }

    /// Pause rendering and input without destroying the surface.
    func pauseRendering() {
        guard !isShuttingDown else { return }
        isPaused = true
        surfaceOwner.pauseRendering(using: surfaceLifecycleRuntime)
    }

    /// Resume rendering/input after a pause.
    func resumeRendering() {
        guard !isShuttingDown else { return }
        isPaused = false
        surfaceOwner.resumeRendering(using: surfaceLifecycleRuntime) { [weak self] in
            guard let self else { return }
            sizeDidChange(bounds.size)
            requestRender()
        }
    }

    private func clearLifecycleCallbacks() {
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onPwdChange = nil
        onProgressReport = nil
        onResize = nil
        onKeyboardBrowseModeChange = nil
        onFindNavigatorVisibilityChange = nil
        richPasteInterceptor = nil
        writeCallback = nil
    }

    /// Check if the terminal process has exited
    var processExited: Bool {
        surfaceOwner.processExited(using: surfaceLifecycleRuntime)
    }

    /// Check if closing this terminal needs confirmation
    var needsConfirmQuit: Bool {
        surfaceOwner.needsConfirmQuit
    }

    /// Get current terminal grid size
    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        surfaceOwner.terminalSize()
    }

    /// Force the terminal surface to refresh/redraw
    func forceRefresh() {
        if isShuttingDown { return }
        if isPaused { return }
        guard surfaceOwner.hasLiveSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: bounds.size)

        let scale = contentScaleFactor
        guard surfaceOwner.forceResize(pointSize: bounds.size, scale: scale, using: surfaceDisplayRuntime) else { return }
        if window != nil {
            surfaceOwner.setOcclusion(true, using: surfaceDisplayRuntime)
        }

        surfaceOwner.redraw(using: surfaceDisplayRuntime)
        markIOSurfaceLayersForDisplay()
        requestRender()
    }

    /// Reset Ghostty's terminal state before binding a fresh remote shell to a reused surface.
    func resetTerminalForReconnect() {
        guard !isShuttingDown else { return }
        surfaceOwner.perform(action: "reset")
        forceRefresh()
    }

    func configureIOSurfaceLayers() {
        configureIOSurfaceLayers(size: nil)
    }

    func configureIOSurfaceLayers(size: CGSize?) {
        let scale = contentScaleFactor
        guard let sublayers = layer.sublayers else { return }
        let targetBounds = size.map { CGRect(origin: .zero, size: $0) } ?? bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers {
            guard isGhosttySurfaceLayer(sublayer) else { continue }
            sublayer.frame = targetBounds
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    func markIOSurfaceLayersForDisplay() {
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { sublayer in
            guard isGhosttySurfaceLayer(sublayer) else { return }
            sublayer.setNeedsDisplay()
        }
    }

    private func isGhosttySurfaceLayer(_ layer: CALayer) -> Bool {
        !subviews.contains { subview in
            subview.layer === layer
        }
    }

    func updateContentScaleIfNeeded() {
        let targetScale = window?.screen.scale ?? UIScreen.main.scale
        if contentScaleFactor != targetScale {
            contentScaleFactor = targetScale
        }
    }

    // MARK: - External backend I/O (for SSH clients)

    /// Callback invoked when user types in the terminal. The External backend's
    /// write callback (registered at surface creation) recovers this view via
    /// userdata and forwards to this closure.
    var writeCallback: ((Data) -> Void)? {
        get { objc_getAssociatedObject(self, &Self.writeCallbackKey) as? (Data) -> Void }
        set { objc_setAssociatedObject(self, &Self.writeCallbackKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    private static var writeCallbackKey: UInt8 = 0

    func scheduleCustomIORedraw() {
        guard useCustomIO else { return }
        guard !isCustomIORedrawScheduled else { return }
        markCustomIORedrawScheduled(true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markCustomIORedrawScheduled(false)
            guard !self.isShuttingDown, !self.isPaused else { return }
            guard self.surfaceOwner.hasLiveSurface else { return }
            guard self.bounds.width > 0 && self.bounds.height > 0 else { return }

            self.updateContentScaleIfNeeded()
            self.configureIOSurfaceLayers(size: self.bounds.size)
            self.surfaceOwner.redraw(using: self.surfaceDisplayRuntime)
            self.markIOSurfaceLayersForDisplay()
        }
    }

    /// Feed data from the SSH channel into the terminal for rendering (External backend).
    func writeOutput(_ data: Data) {
        surfaceOwner.writeOutput(data, using: surfaceDisplayRuntime)
        scheduleCustomIORedraw()
        requestRender()
    }

    /// Notify the terminal that the SSH session ended (External backend).
    func externalExited(_ exitCode: UInt32 = 0) {
        surfaceOwner.externalExited(exitCode, using: surfaceDisplayRuntime)
        scheduleCustomIORedraw()
        requestRender()
    }
}
#endif
