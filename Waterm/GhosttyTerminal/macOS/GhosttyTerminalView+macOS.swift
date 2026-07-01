//
//  GhosttyTerminalView+macOS.swift
//  Waterm
//
//  macOS NSView implementation for Ghostty terminal rendering
//

#if os(macOS)
import AppKit
import Metal
import OSLog
import SwiftUI
import IOSurface
import QuartzCore

/// NSView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering
/// - Input forwarding (keyboard, mouse, scroll)
/// - Focus management
/// - Surface lifecycle management
@MainActor
class GhosttyTerminalView: NSView, NSUserInterfaceValidations {
    // MARK: - Properties

    let surfaceOwner: TerminalMacOSSurfaceOwner
    var surface: Ghostty.Surface? {
        get { surfaceOwner.surface }
        set { surfaceOwner.surface = newValue }
    }
    private let surfaceRegistration = GhosttySurfaceRegistration()
    private let worktreePath: String
    private let paneId: String?
    private let initialCommand: String?
    private let useCustomIO: Bool

    /// Callback invoked when the terminal process exits
    var onProcessExit: (() -> Void)?

    /// Callback invoked when the terminal title changes
    var onTitleChange: ((String) -> Void)?

    /// Callback invoked when the terminal reports working directory changes (OSC 7)
    var onPwdChange: ((String) -> Void)?

    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    var onReady: (() -> Void)?

    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?

    /// Callback when terminal size changes (cols, rows) - used for SSH PTY resize
    var onResize: ((Int, Int) -> Void)?

    /// Callback invoked when a magnification gesture requests terminal pane zoom.
    var onZoomAction: (@MainActor @Sendable (TerminalZoomAction) -> TerminalZoomResult?)?

    /// Per-surface presentation overrides used to preserve pane zoom across global config reloads.
    private(set) var surfacePresentationOverrides: TerminalPresentationOverrides = .empty

    /// Optional app-level paste interceptor used for rich clipboard routing.
    var richPasteInterceptor: ((GhosttyTerminalView) -> Bool)?

    private var didSignalReady = false

    /// Cell size in points for row-to-pixel conversion (used by scroll view)
    var cellSize: NSSize = .zero

    /// Current scrollbar state from Ghostty core (used by scroll view)
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "win.aizen.app", category: "GhosttyTerminal")

    // MARK: - Display Link Rendering (event-driven for SSH)

    private let displayLinkRuntime = TerminalMacOSDisplayLinkRuntime()
    private let surfaceLifecycleRuntime = TerminalMacOSSurfaceLifecycleRuntime()
    private var accumulatedMagnification: CGFloat = 0
    private let zoomIndicatorView = TerminalZoomIndicatorView()
    private var zoomIndicatorHideWorkItem: DispatchWorkItem?

    // MARK: - Handler Components

    private var imeHandler: GhosttyIMEHandler!
    private var inputHandler: GhosttyInputHandler!
    private let renderingSetup = GhosttyRenderingSetup()

    /// Observation for appearance changes
    private var appearanceObservation: NSKeyValueObservation?

    /// Observer for config reload notifications
    private var configReloadObserver: NSObjectProtocol?

    // MARK: - Rendering Control

    /// Flag to prevent operations during cleanup
    private var isShuttingDown = false

    /// iOS pauses rendering when views are offscreen. On macOS rendering is
    /// event-driven, so these are intentionally no-ops for API parity.
    func pauseRendering() {
    }

    func resumeRendering() {
    }

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this when closing a session to ensure proper cleanup.
    func cleanup() {
        isShuttingDown = true
        surfaceOwner.cleanup(
            using: surfaceLifecycleRuntime,
            surfaceRegistration: surfaceRegistration,
            stopDisplayLink: { [displayLinkRuntime] in
                displayLinkRuntime.stop()
            },
            cancelPendingZoomIndicatorHide: { [weak self] in
                self?.zoomIndicatorHideWorkItem?.cancel()
                self?.zoomIndicatorHideWorkItem = nil
            },
            removeConfigReloadObserver: { [weak self] in
                guard let self, let observer = self.configReloadObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                self.configReloadObserver = nil
            },
            clearCallbacks: { [weak self] in
                self?.clearCallbacks()
            }
        )
    }

    private func clearCallbacks() {
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onPwdChange = nil
        onProgressReport = nil
        onResize = nil
        richPasteInterceptor = nil
        writeCallback = nil
    }

    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The Ghostty.App wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane (used for tmux session persistence)
    ///   - command: Optional command to run instead of default shell
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(frame: NSRect, worktreePath: String, ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App? = nil, paneId: String? = nil, command: String? = nil, useCustomIO: Bool = false) {
        self.worktreePath = worktreePath
        self.surfaceOwner = TerminalMacOSSurfaceOwner(ghosttyApp: ghosttyApp, appWrapper: appWrapper)
        self.paneId = paneId
        self.initialCommand = command
        self.useCustomIO = useCustomIO

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : NSRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)

        // Initialize handlers before setup
        self.imeHandler = GhosttyIMEHandler(view: self, surfaceOwner: surfaceOwner)
        self.inputHandler = GhosttyInputHandler(view: self, surfaceOwner: surfaceOwner, imeHandler: self.imeHandler)

        setupLayer()
        setupSurface()
        setupTrackingArea()
        setupAppearanceObservation()
        setupFrameObservation()
        setupConfigReloadObservation()
        zoomIndicatorView.isHidden = true
        zoomIndicatorView.alphaValue = 0
        addSubview(zoomIndicatorView)
        if useCustomIO {
            displayLinkRuntime.setup { [weak self] in
                guard let self else { return }
                self.surfaceOwner.tickDisplayLink(self.displayLinkRuntime, isShuttingDown: self.isShuttingDown)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        displayLinkRuntime.stopFromDeinit()

        // Surface cleanup happens via Surface's deinit
        // Note: Cannot access @MainActor properties in deinit
        // Tracking areas are automatically cleaned up by NSView
        // Appearance observation is automatically invalidated

        surfaceRegistration.unregisterLaterFromDeinit()
    }

    // MARK: - Setup

    /// Configure the Metal-backed layer for terminal rendering
    private func setupLayer() {
        renderingSetup.setupLayer(for: self)
    }

    /// Create and configure the Ghostty surface
    private func setupSurface() {
        let app = surfaceOwner.ghosttyApp

        let callbackContext = GhosttySurfaceCallbackContext(terminalView: self)
        guard let cSurface = renderingSetup.setupSurface(
            view: self,
            ghosttyApp: app,
            worktreePath: worktreePath,
            initialBounds: bounds,
            window: window,
            surfaceCallbackContext: callbackContext,
            paneId: paneId,
            command: initialCommand,
            useCustomIO: useCustomIO
        ) else {
            return
        }

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(cSurface: cSurface, callbackContext: callbackContext)

        // Update handlers with surface
        imeHandler.surfaceDidChange()

        surfaceRegistration.register(cSurface, appWrapper: surfaceOwner.appWrapper, terminalView: self)
    }

    /// Setup mouse tracking area for the entire view
    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect,
            .activeAlways  // Track even when not focused
        ]

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    /// Setup observation for system appearance changes (light/dark mode)
    private func setupAppearanceObservation() {
        appearanceObservation = surfaceOwner.setupAppearanceObservation(for: self, renderingSetup: renderingSetup)
    }

    private func setupFrameObservation() {
        // We rely on layout() + updateLayout to resize the surface.
        self.postsFrameChangedNotifications = false
    }

    private func setupConfigReloadObservation() {
        configReloadObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.configDidReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceRefresh()
            }
        }
    }

    /// Request a render - starts display link if needed
    private func requestRender() {
        guard !isShuttingDown else { return }
        displayLinkRuntime.requestRender()
    }

    // MARK: - NSView Overrides

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            surfaceOwner.setFocus(true, using: surfaceLifecycleRuntime)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            surfaceOwner.setFocus(false, using: surfaceLifecycleRuntime)
        }
        return result
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }

        // Recreate with current bounds
        setupTrackingArea()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        surfaceOwner.updateBackingProperties(for: self, renderingSetup: renderingSetup, window: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Manage display link based on window attachment
        if window != nil {
            // Request render to start display link if needed
            DispatchQueue.main.async { [weak self] in
                self?.requestRender()
                self?.forceRefresh()
            }
        } else {
            displayLinkRuntime.stop()
        }
    }

    // Track last size sent to Ghostty to avoid redundant updates
    private var lastSurfaceSize: CGSize = .zero

    // Track last terminal size (cols, rows) to detect changes for SSH resize
    private var lastTerminalSize: (cols: Int, rows: Int) = (0, 0)

    // Override safe area insets to use full available space, including rounded corners
    // This matches Ghostty's SurfaceScrollView implementation
    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsetsZero
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Force layout to be called to fix up subviews
        // This matches Ghostty's SurfaceScrollView.setFrameSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let didUpdate = surfaceOwner.updateLayout(
            for: self,
            renderingSetup: renderingSetup,
            metalLayer: layer as? CAMetalLayer,
            lastSize: &lastSurfaceSize
        )
        if didUpdate && !didSignalReady {
            didSignalReady = true
            onReady?()
        }
        updateZoomIndicatorLayout()

        // Check for terminal size changes and notify via callback (for SSH PTY resize)
        if didUpdate, let size = terminalSize() {
            let cols = Int(size.columns)
            let rows = Int(size.rows)
            if cols != lastTerminalSize.cols || rows != lastTerminalSize.rows {
                lastTerminalSize = (cols, rows)
                onResize?(cols, rows)
            }
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        if handleRichPasteShortcut(event) {
            return
        }
        inputHandler.handleKeyDown(with: event) { [weak self] events in
            self?.interpretKeyEvents(events)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isFirstResponder = window?.firstResponder === self

        switch true {
        case MacTerminalShortcutRouting.shouldHandle(
            MacTerminalShortcut.paste,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isFirstResponder: isFirstResponder
        ):
            paste(nil)
            return true
        case MacTerminalShortcutRouting.shouldHandle(
            MacTerminalShortcut.copy,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isFirstResponder: isFirstResponder
        ):
            copy(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func handleRichPasteShortcut(_ event: NSEvent) -> Bool {
        guard isRichPasteShortcut(event) else { return false }
        return interceptRichPasteIfNeeded()
    }

    private func isRichPasteShortcut(_ event: NSEvent) -> Bool {
        MacTerminalShortcut.richPaste.matches(event)
    }

    @discardableResult
    private func interceptRichPasteIfNeeded() -> Bool {
        richPasteInterceptor?(self) == true
    }

    private func performPasteAction() {
        if interceptRichPasteIfNeeded() {
            return
        }
        pasteTextFromClipboard()
    }

    override func keyUp(with event: NSEvent) {
        inputHandler.handleKeyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputHandler.handleFlagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Override to suppress NSBeep when interpretKeyEvents encounters unhandled commands
        // Without this, keys like delete at beginning of line, cmd+c with no selection, etc. cause beeps
        // Terminal handles all input via Ghostty, so we silently ignore unhandled commands
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return surfaceOwner.hasSelection()
        case #selector(paste(_:)):
            return true
        default:
            return true
        }
    }

    @objc func copy(_ sender: Any?) {
        surfaceOwner.perform(action: "copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        performPasteAction()
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        inputHandler.handleMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        inputHandler.handleMouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputHandler.handleRightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        inputHandler.handleRightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        inputHandler.handleOtherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        inputHandler.handleOtherMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        inputHandler.handleMouseMoved(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        inputHandler.handleMouseEntered(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseExited(with event: NSEvent) {
        inputHandler.handleMouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        inputHandler.handleScrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        accumulatedMagnification += event.magnification

        if accumulatedMagnification >= CGFloat(TerminalZoomPresentation.magnificationStepThreshold) {
            if let result = onZoomAction?(.zoomIn) {
                showZoomIndicator(fontSize: result.effectiveFontSize)
            }
            accumulatedMagnification = 0
        } else if accumulatedMagnification <= -CGFloat(TerminalZoomPresentation.magnificationStepThreshold) {
            if let result = onZoomAction?(.zoomOut) {
                showZoomIndicator(fontSize: result.effectiveFontSize)
            }
            accumulatedMagnification = 0
        }

        if event.phase == .ended || event.phase == .cancelled {
            accumulatedMagnification = 0
            scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorGestureEndHideDelay)
        }
    }

    private func showZoomIndicator() {
        showZoomIndicator(fontSize: surfacePresentationOverrides.resolvedFontSize())
    }

    private func showZoomIndicator(fontSize: Double) {
        zoomIndicatorView.update(fontSize: fontSize)
        updateZoomIndicatorLayout()
        addSubview(zoomIndicatorView, positioned: .above, relativeTo: nil)

        zoomIndicatorHideWorkItem?.cancel()
        zoomIndicatorView.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TerminalZoomPresentation.indicatorFadeInDuration
            zoomIndicatorView.animator().alphaValue = 1
        }
        scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorHideDelay)
    }

    private func scheduleZoomIndicatorHide(after delay: TimeInterval) {
        zoomIndicatorHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = TerminalZoomPresentation.indicatorFadeOutDuration
                self.zoomIndicatorView.animator().alphaValue = 0
            }, completionHandler: {
                self.zoomIndicatorView.isHidden = true
            })
        }
        zoomIndicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func updateZoomIndicatorLayout() {
        let fittingSize = zoomIndicatorView.fittingSize
        let width = max(fittingSize.width, CGFloat(TerminalZoomPresentation.indicatorMinimumWidth))
        let height = max(fittingSize.height, CGFloat(TerminalZoomPresentation.indicatorMinimumHeight))
        zoomIndicatorView.frame = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Process Lifecycle

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
    /// Useful after tmux reattaches or when view becomes visible
    func forceRefresh() {
        // Force a size update to trigger tmux redraw
        let scaledSize = convertToBacking(bounds.size)
        guard surfaceOwner.forceRefresh(backingSize: scaledSize) else { return }

        // Force Metal layer to redraw
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.setNeedsDisplay()
        }
        layer?.setNeedsDisplay()
        needsDisplay = true
        needsLayout = true
        displayIfNeeded()
    }

    func applyPresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides) {
        surfacePresentationOverrides = presentationOverrides

        guard surfaceOwner.updateSurfaceConfig(presentationOverrides) else { return }
        forceRefresh()
    }

    /// Reset Ghostty's terminal state before binding a fresh remote shell to a reused surface.
    func resetTerminalForReconnect() {
        guard !isShuttingDown else { return }
        surfaceOwner.perform(action: "reset")
        forceRefresh()
    }

    // MARK: - External backend I/O (for SSH clients)

    /// Callback invoked when user types in the terminal (keyboard input to send to SSH).
    /// Set by the SSH wrapper; the External backend's write callback (registered at
    /// surface creation) recovers this view via userdata and forwards to it.
    var writeCallback: ((Data) -> Void)?

    /// Feed data from the SSH channel into the terminal for rendering (External backend).
    func writeOutput(_ data: Data) {
        // Feed data immediately - SSH read loop already batches appropriately
        surfaceOwner.writeOutput(data)

        // Request render via display link (event-driven, will auto-stop when idle)
        requestRender()
    }

    /// Notify the terminal that the SSH session ended (External backend), so it shows
    /// ghostty's real "session ended" UI instead of going silent.
    func externalExited(_ exitCode: UInt32 = 0) {
        surfaceOwner.externalExited(exitCode)
        requestRender()
    }

    /// Send text to the terminal (used by voice input)
    func sendText(_ text: String) {
        surfaceOwner.sendText(text)
        requestRender()
    }

    func pasteTextFromClipboard() {
        let surface = surfaceOwner.liveSurfaceHandle
        if let surface {
            GhosttyClipboardBridge.publishReadSnapshot(
                surface: surface,
                string: Clipboard.readString() ?? ""
            )
        }
        surfaceOwner.perform(action: "paste_from_clipboard")
        if let surface {
            GhosttyClipboardBridge.clearReadSnapshot(for: surface)
        }
        requestRender()
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        let escapeSequence = TerminalSpecialKeySequence.escapeSequence(for: key)
        surfaceOwner.sendText(escapeSequence)
        requestRender()
    }

    /// Send a control key combination (Ctrl+C, Ctrl+D, etc.)
    func sendControlKey(_ char: Character) {
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            surfaceOwner.sendText(String(controlChar))
            requestRender()
        }
    }
}

// MARK: - NSTextInputClient Implementation

/// NSTextInputClient protocol conformance for IME (Input Method Editor) support
extension GhosttyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        imeHandler.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        imeHandler.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    func unmarkText() {
        imeHandler.unmarkText()
    }

    func selectedRange() -> NSRange {
        return imeHandler.selectedRange()
    }

    func markedRange() -> NSRange {
        return imeHandler.markedRange()
    }

    func hasMarkedText() -> Bool {
        return imeHandler.hasMarkedText
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return imeHandler.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return imeHandler.validAttributesForMarkedText()
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return imeHandler.firstRect(
            forCharacterRange: range,
            actualRange: actualRange,
            viewFrame: frame,
            window: window
        )
    }

    func characterIndex(for point: NSPoint) -> Int {
        return imeHandler.characterIndex(for: point)
    }
}

#endif
