//
//  GhosttyTerminalView+iOS.swift
//  VVTerm
//
//  iOS UIView implementation for Ghostty terminal rendering
//

#if os(iOS)
import UIKit
import OSLog
import SwiftUI
import GameController

/// UIView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering (Ghostty handles this internally)
/// - Touch and keyboard input
/// - Surface lifecycle requests
@MainActor
class GhosttyTerminalView: UIView {
    static let textInputContextID = "app.vivy.VVTerm.GhosttyTerminalView"
    private static let imeProxyOffscreenFrame = CGRect(x: -10_000, y: -10_000, width: 1, height: 1)
    // MARK: - Properties

    let surfaceOwner: TerminalIOSSurfaceOwner
    var surface: Ghostty.Surface? {
        get { surfaceOwner.surface }
        set { surfaceOwner.surface = newValue }
    }
    let surfaceRegistration = GhosttySurfaceRegistration()
    let worktreePath: String
    let paneId: String?
    let initialCommand: String?
    let useCustomIO: Bool
    let presentationEnvironment: TerminalIOSPresentationEnvironment

    /// Callback invoked when the terminal process exits
    var onProcessExit: (() -> Void)?

    /// Callback invoked when the terminal title changes
    var onTitleChange: ((String) -> Void)?

    /// Callback invoked when the terminal reports working directory changes (OSC 7)
    var onPwdChange: ((String) -> Void)?

    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    var onReady: (() -> Void)?

    /// Callback invoked when the terminal grid changes (cols, rows).
    /// In custom I/O mode (SSH), the embedder should send a window-change.
    var onResize: ((Int, Int) -> Void)?

    /// Callback invoked when a pinch gesture requests terminal pane zoom.
    var onZoomAction: ((TerminalZoomAction) -> TerminalZoomResult?)?

    /// Per-surface presentation overrides used to preserve pane zoom across global config reloads.
    private(set) var surfacePresentationOverrides: TerminalPresentationOverrides = .empty

    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?

    /// Callback invoked when the voice input button is tapped
    var onVoiceButtonTapped: (() -> Void)? {
        didSet {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
    }

    @discardableResult
    func triggerVoiceInput() -> Bool {
        guard let onVoiceButtonTapped else { return false }
        onVoiceButtonTapped()
        return true
    }

    /// Optional app-level paste interceptor used for rich clipboard routing.
    var richPasteInterceptor: ((GhosttyTerminalView) -> Bool)?
    private var didSignalReady = false

    /// Prevent rendering when the view is offscreen or being torn down.
    var isShuttingDown = false
    var isPaused = false
    private var customIORedrawScheduled = false
    let keyRepeatRuntime = TerminalIOSKeyRepeatRuntime()

    var lastReportedGrid: (cols: Int, rows: Int) = (0, 0)
    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "GhosttyTerminal")

    var isSelecting = false
    var isNativeHostScrollContainerEnabled = false
    let scrollRuntime = TerminalIOSScrollRuntime()
    let zoomRuntime = TerminalIOSZoomRuntime()
    var nativeSelectionSnapshot = TerminalNativeTextSnapshot.empty
    var nativeSelectedRange: NSRange?
    weak var nativeTextInputDelegate: UITextInputDelegate?
    lazy var nativeSelectionTokenizer = UITextInputStringTokenizer(textInput: self)
    var nativeSelectionAffinity: UITextStorageDirection = .forward
    var nativeSelectionInteractionActive = false
    var prefersNativeSelectionFirstResponder = false
    var shouldRestoreIMEProxyFocusAfterNativeSelection = false
    var nativeTextInteraction: UITextInteraction?
    var nativeFindInteraction: UIFindInteraction?
    let findRuntime = TerminalIOSFindRuntime()
    let nativeFindDocumentIdentifier = "terminal"
    let nativeFindOverlay = TerminalNativeFindOverlayView()
    var nativeFindDecorations: [TerminalNativeFindDecoration] = [] {
        didSet {
            updateNativeFindOverlay()
        }
    }
    let touchSelectionState = TerminalIOSTouchSelectionState()
    let touchSelectionOverlay = TerminalTouchSelectionOverlayView()
    let touchSelectionLoupe = TerminalTouchSelectionLoupeView()
    lazy var selectionRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSelectionPress(_:))
        )
        recognizer.minimumPressDuration = 0.2
        recognizer.allowableMovement = 8
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        recognizer.numberOfTapsRequired = 2
        return recognizer
    }()

    private lazy var tripleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTripleTap(_:))
        )
        recognizer.numberOfTapsRequired = 3
        return recognizer
    }()

    lazy var scrollRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGesture(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        recognizer.requiresExclusiveTouchType = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        if #available(iOS 13.4, *) {
            recognizer.allowedScrollTypesMask = .all
        }
        return recognizer
    }()
    lazy var pinchRecognizer: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(
            target: self,
            action: #selector(handlePinchGesture(_:))
        )
        recognizer.requiresExclusiveTouchType = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        return recognizer
    }()
    private lazy var selectionStartHandleRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()
    private lazy var selectionEndHandleRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    var editMenuInteraction: UIEditMenuInteraction?

    let lifecycleObservers = TerminalLifecycleObserverBag()
    var hasHardwareKeyboardAttached = false

    // MARK: - Text Input (for spacebar cursor control)
    var textInputModel = TerminalTextInputModel()
    let hardwarePressState = TerminalIOSHardwarePressState()
    var suppressIMEProxyCallbacks = false
    lazy var imeProxyTextView: TerminalIMEProxyTextView = {
        let textView = TerminalIMEProxyTextView(frame: bounds)
        textView.terminalOwner = self
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isUserInteractionEnabled = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        if #available(iOS 17.0, *) {
            textView.inlinePredictionType = .no
        }
        return textView
    }()
    struct HardwarePressResult {
        var forwardedToSystem: Set<UIPress> = []
        var didHandleGhosttyInput = false
    }

    // MARK: - Rendering Components

    let renderingSetup = GhosttyRenderingSetup()
    let surfaceDisplayRuntime = TerminalIOSSurfaceDisplayRuntime()
    let surfaceLifecycleRuntime = TerminalIOSSurfaceLifecycleRuntime()
    let inputRuntime = TerminalIOSInputRuntime()
    let selectionRuntime = TerminalIOSSelectionRuntime()

    func requestRender() {
        if isShuttingDown { return }
        if isPaused { return }
        guard surfaceOwner.hasLiveSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        if usesNativeTouchSelection, nativeSelectionInteractionActive || nativeSelectedRange != nil {
            refreshNativeSelectionSnapshot()
        }
        markIOSurfaceLayersForDisplay()
    }

    func markCustomIORedrawScheduled(_ scheduled: Bool) {
        customIORedrawScheduled = scheduled
    }

    var isCustomIORedrawScheduled: Bool {
        customIORedrawScheduled
    }

    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The Ghostty.App wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane
    ///   - command: Optional command to run instead of default shell
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(
        frame: CGRect,
        worktreePath: String,
        ghosttyApp: ghostty_app_t,
        appWrapper: Ghostty.App? = nil,
        paneId: String? = nil,
        command: String? = nil,
        useCustomIO: Bool = false,
        presentationEnvironment: TerminalIOSPresentationEnvironment? = nil
    ) {
        self.worktreePath = worktreePath
        self.surfaceOwner = TerminalIOSSurfaceOwner(ghosttyApp: ghosttyApp, appWrapper: appWrapper)
        self.paneId = paneId
        self.initialCommand = command
        self.useCustomIO = useCustomIO
        self.presentationEnvironment = presentationEnvironment ?? .live

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : CGRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)

        // Set content scale factor for retina rendering (important before surface creation)
        self.contentScaleFactor = UIScreen.main.scale

        setupSurface()
        addSubview(imeProxyTextView)
        zoomRuntime.installIndicator(in: self)
        if usesNativeTouchSelection {
            nativeFindOverlay.frame = bounds
            addSubview(nativeFindOverlay)
        }
        if usesAppOwnedTouchSelection {
            touchSelectionOverlay.frame = bounds
            touchSelectionOverlay.isHidden = true
            addSubview(touchSelectionOverlay)
            touchSelectionLoupe.isHidden = true
            addSubview(touchSelectionLoupe)
            touchSelectionOverlay.startHandle.addGestureRecognizer(selectionStartHandleRecognizer)
            touchSelectionOverlay.endHandle.addGestureRecognizer(selectionEndHandleRecognizer)
        }

        // Setup gesture recognizers with delegate for simultaneous recognition
        scrollRecognizer.delegate = self
        pinchRecognizer.delegate = self
        if usesAppOwnedTouchSelection {
            selectionRecognizer.delegate = self
            doubleTapRecognizer.delegate = self
            tripleTapRecognizer.delegate = self
            selectionStartHandleRecognizer.delegate = self
            selectionEndHandleRecognizer.delegate = self
        }

        if usesAppOwnedTouchSelection {
            // Triple tap should require double tap to fail first
            doubleTapRecognizer.require(toFail: tripleTapRecognizer)
        }

        addGestureRecognizer(scrollRecognizer)
        addGestureRecognizer(pinchRecognizer)
        if usesAppOwnedTouchSelection {
            addGestureRecognizer(selectionRecognizer)
            addGestureRecognizer(doubleTapRecognizer)
            addGestureRecognizer(tripleTapRecognizer)
        }
        isUserInteractionEnabled = true

        if usesNativeTouchSelection {
            setupNativeTextSelectionInteractions()
            setupNativeFindInteraction()
        } else {
            // Setup edit menu interaction for copy/paste
            let interaction = UIEditMenuInteraction(delegate: self)
            addInteraction(interaction)
            editMenuInteraction = interaction
        }

        setupConfigReloadObservation()
        setupInputModeObservation()
        registerColorSchemeObserver()
        setupHardwareKeyboardObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        surfaceRegistration.unregisterLaterFromDeinit()
    }

    // MARK: - Layer Type
    // On iOS, Ghostty adds its own IOSurfaceLayer as a sublayer of the view's
    // existing CALayer. Keep the default layer type to avoid CAMetalLayer
    // interfering with sublayer rendering/compositing.

    // MARK: - Setup

    /// Create and configure the Ghostty surface
    private func setupConfigReloadObservation() {
        lifecycleObservers.observeConfigReload { [weak self] in
            self?.requestRender()
        }
    }

    private func setupInputModeObservation() {
        lifecycleObservers.observeInputModeChanges { [weak self] in
            self?.handleCurrentInputModeDidChange()
        }
    }

    private func handleCurrentInputModeDidChange() {
        guard !isShuttingDown else { return }
        TerminalIMEProxyTextView.dictationLogger.log("inputModeDidChange primary=\(self.currentIMEPrimaryLanguage ?? "nil", privacy: .public) proxyFirstResponder=\(self.imeProxyTextView.isFirstResponder) session=\(self.imeProxyTextView.isDictationSessionActive)")
        if isDictationInputModeActive {
            // Entering dictation. Invalidating the session or reloading input views here
            // would terminate dictation immediately after it starts.
            if imeProxyTextView.isFirstResponder {
                imeProxyTextView.beginDictationSession()
            }
            return
        }
        if imeProxyTextView.isDictationSessionActive {
            // Leaving dictation: commit what was dictated to the terminal.
            imeProxyTextView.endDictationSession(commit: true)
            return
        }
        invalidateLocalTextInputSession()
        if hasHardwareKeyboardAttached {
            focusForHardwareKeyboardIfNeeded()
        }
        guard imeProxyTextView.isFirstResponder, isTextInputSessionEligible else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.imeProxyTextView.reloadInputViews()
        }
    }

    private var isDictationInputModeActive: Bool {
        TerminalVisiblePreeditPolicy.isDictationInputMode(currentIMEPrimaryLanguage)
    }

    // MARK: - Size Change Handling (matches official Ghostty iOS pattern)

    /// Notify Ghostty of size changes. This method follows the official Ghostty iOS implementation.
    /// It sets content scale BEFORE size, using the contentScaleFactor.
    /// NOTE: On iOS, we must also configure the IOSurfaceLayer's frame/contentsScale in layoutSubviews
    /// and didMoveToWindow because Ghostty adds it as a sublayer that doesn't auto-resize.
    /// Without proper sublayer configuration, Ghostty's setSurfaceCallback will discard all frames.
    func sizeDidChange(_ size: CGSize) {
        if isShuttingDown { return }
        guard surfaceOwner.hasLiveSurface else { return }
        guard size.width > 0 && size.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: size)

        let scale = self.contentScaleFactor
        if surfaceOwner.resizeIfNeeded(pointSize: size, scale: scale, using: surfaceDisplayRuntime) {
            reportGridResizeIfNeeded()
        }

        if !isPaused {
            surfaceOwner.redraw(using: surfaceDisplayRuntime)
            if usesNativeTouchSelection {
                refreshNativeSelectionSnapshot()
            }
            markIOSurfaceLayersForDisplay()
        }

        if !didSignalReady {
            didSignalReady = true
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
        }
    }

    func applyPresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides) {
        surfacePresentationOverrides = presentationOverrides

        guard surfaceOwner.updateSurfaceConfig(presentationOverrides) else { return }
        surfaceDisplayRuntime.resetSizeTracking()
        sizeDidChange(bounds.size)
        requestRender()
    }

    private func reportGridResizeIfNeeded() {
        guard let size = terminalSize() else { return }
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 0, rows > 0 else { return }
        guard cols != lastReportedGrid.cols || rows != lastReportedGrid.rows else { return }
        lastReportedGrid = (cols, rows)
        onResize?(cols, rows)
    }

    // MARK: - UIView Overrides

    override var canBecomeFirstResponder: Bool {
        return true
    }

    var isTextInputSessionEligible: Bool {
        guard !isShuttingDown else { return false }
        guard window != nil, !isHidden, alpha > 0.01 else { return false }
        if let activationState = window?.windowScene?.activationState {
            return activationState == .foregroundActive
        }
        return presentationEnvironment.isApplicationActive()
    }

    var acceptsTerminalInput = true
    var keyboardFocusPolicy = TerminalKeyboardFocusPolicy()
    private var suppressDirectTouchKeyboardFocusUntil = Date.distantPast
    var onKeyboardBrowseModeChange: (@MainActor (Bool) -> Void)?
    var onFindNavigatorVisibilityChange: (@MainActor (Bool) -> Void)?

    var shouldRestoreKeyboardFocusOnReconnect: Bool {
        keyboardFocusPolicy.shouldRestoreOnReconnect
    }

    var allowsAutomaticKeyboardFocus: Bool {
        keyboardFocusPolicy.allowsAutomaticFocus && !isFindNavigatorActive
    }

    var isKeyboardInBrowseMode: Bool {
        keyboardFocusPolicy.isBrowsing
    }

    var isFindNavigatorVisible: Bool {
        isFindNavigatorActive
    }

    var isFindNavigatorActive: Bool {
        guard #available(iOS 16.0, *) else { return false }
        return findRuntime.isNavigatorLifecycleActive
            || nativeFindInteraction?.isFindNavigatorVisible == true
    }

    var canRouteTerminalInput: Bool {
        acceptsTerminalInput && !isFindNavigatorActive
    }

    var canRouteProxyDeleteBackward: Bool {
        canRouteTerminalInput
    }

    func markKeyboardFocusForReconnect() {
        keyboardFocusPolicy.markForReconnect()
    }

    func clearKeyboardFocusForReconnect() {
        keyboardFocusPolicy.clearReconnect()
    }

    @discardableResult
    func requestKeyboardFocus(for reason: TerminalKeyboardFocusReason) -> Bool {
        guard !isFindNavigatorActive else { return false }
        guard keyboardFocusPolicy.requestFocus(for: reason) else { return false }
        clearNativeSelectionStateForTerminalInput()
        notifyKeyboardBrowseModeChange()
        _ = becomeFirstResponder()
        return true
    }

    @discardableResult
    func exitNativeSelectionTextInputContextForTerminalInput() -> Bool {
        guard isNativeSelectionTextInputContext else { return true }
        guard !isFindNavigatorActive else { return false }

        nativeSelectionInteractionActive = false
        return requestKeyboardFocus(for: .explicitUserRequest)
    }

    func clearNativeSelectionStateForTerminalInput() {
        guard usesNativeTouchSelection else { return }
        nativeSelectionInteractionActive = false
        prefersNativeSelectionFirstResponder = false
        shouldRestoreIMEProxyFocusAfterNativeSelection = false
        if nativeSelectedRange != nil {
            setNativeSelectedRange(nil)
        }
    }

    func shouldRedirectNativeSelectionPressesToTerminalInput(_ presses: Set<UIPress>) -> Bool {
        guard isNativeSelectionTextInputContext else { return false }
        return presses.contains { press in
            guard let key = press.key else { return false }
            return !key.modifierFlags.contains(.command)
        }
    }

    @discardableResult
    func requestKeyboardFocus() -> Bool {
        requestKeyboardFocus(for: .explicitUserRequest)
    }

    func dismissKeyboardForUser(suppressDirectTouchRefocus: Bool = false) {
        if hasHardwareKeyboardAttached {
            focusForHardwareKeyboardIfNeeded()
            return
        }
        keyboardFocusPolicy.dismissForUser()
        notifyKeyboardBrowseModeChange()
        if suppressDirectTouchRefocus {
            // Tapping the dismiss button can leak one direct-touch event through to the
            // terminal view underneath. Suppress immediate touch-driven refocus briefly
            // so the software keyboard stays dismissed on handheld devices.
            suppressDirectTouchKeyboardFocusUntil = Date().addingTimeInterval(0.35)
        }
        _ = resignFirstResponder()
    }

    func dismissKeyboardFromToolbar() {
        dismissKeyboardForUser(suppressDirectTouchRefocus: true)
    }

    func shouldAutoFocusKeyboard(for touches: Set<UITouch>) -> Bool {
        guard !isFindNavigatorActive else { return false }
        guard keyboardFocusPolicy.allowsAutomaticFocus else { return false }
        guard touches.contains(where: { $0.type == .direct }) else { return true }
        return Date() >= suppressDirectTouchKeyboardFocusUntil
    }

    private func notifyKeyboardBrowseModeChange() {
        onKeyboardBrowseModeChange?(keyboardFocusPolicy.isBrowsing)
        if imeProxyTextView.isFirstResponder {
            imeProxyTextView.reloadInputViews()
        }
        if super.isFirstResponder {
            reloadInputViews()
        }
    }

    override var textInputContextIdentifier: String? {
        currentTextInputContextIdentifier
    }

    override var isFirstResponder: Bool {
        super.isFirstResponder || imeProxyTextView.isFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        guard isTextInputSessionEligible else { return false }
        if usesNativeTouchSelection,
           (prefersNativeSelectionFirstResponder || nativeSelectionInteractionActive || nativeSelectedRange != nil) {
            let result = super.becomeFirstResponder()
            surfaceLifecycleRuntime.setFocus(result || super.isFirstResponder, surface: surface)
            return result
        }
        return imeProxyTextView.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        guard imeProxyTextView.isFirstResponder || super.isFirstResponder else { return true }
        if imeProxyTextView.isFirstResponder,
           isTextInputSessionEligible,
           !inputRuntime.canResignIMEProxy(isTextInputSessionEligible: true) {
            imeProxyFocusDidChange(isFocused: true)
            return false
        }
        let proxyResult: Bool
        if imeProxyTextView.isFirstResponder {
            proxyResult = inputRuntime.performProgrammaticIMEProxyResign {
                imeProxyTextView.resignFirstResponder()
            }
        } else {
            proxyResult = true
        }
        let ownResult = super.isFirstResponder ? super.resignFirstResponder() : true
        if (proxyResult && ownResult) || !isTextInputSessionEligible {
            surfaceLifecycleRuntime.setFocus(false, surface: surface)
            stopKeyRepeat()
            hardwarePressState.clearPendingSystemTextInputHardwareKeys()
        }
        return (proxyResult && ownResult) || !isTextInputSessionEligible
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imeProxyTextView.frame = bounds
        nativeFindOverlay.frame = bounds
        touchSelectionOverlay.frame = bounds
        bringSubviewToFront(nativeFindOverlay)
        bringSubviewToFront(touchSelectionOverlay)
        bringSubviewToFront(touchSelectionLoupe)
        zoomRuntime.bringIndicatorToFront(in: self)

        guard !isShuttingDown else { return }

        // Tell Ghostty the new size after the view has laid out.
        sizeDidChange(bounds.size)

    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        let isVisible = (window != nil)
        isPaused = !isVisible
        surfaceLifecycleRuntime.setOcclusion(isVisible, surface: surface)

        if isVisible {
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
            sizeDidChange(frame.size)
            // Note: becomeFirstResponder is now handled by SSHTerminalWrapper.updateUIView
            // based on isActive flag to avoid keyboard showing when terminal is hidden
            requestRender()
        }
    }

    // Use trait change registration API (iOS 17+) with fallback
    private func registerColorSchemeObserver() {
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (view: GhosttyTerminalView, _: UITraitCollection) in
                self?.updateColorScheme()
            }
        }
    }

    private func updateColorScheme() {
        let scheme: ghostty_color_scheme_e = traitCollection.userInterfaceStyle == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        surfaceOwner.setColorScheme(scheme, using: surfaceDisplayRuntime)
    }

    private func setupHardwareKeyboardObservation() {
        lifecycleObservers.observeHardwareKeyboardChanges { [weak self] in
            self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
        }
        updateHardwareKeyboardState(reloadInputViewsIfNeeded: false)
    }

    func updateHardwareKeyboardState(reloadInputViewsIfNeeded: Bool) {
        let hasHardwareKeyboard = GCKeyboard.coalesced != nil
        let didChange = hasHardwareKeyboard != hasHardwareKeyboardAttached
        hasHardwareKeyboardAttached = hasHardwareKeyboard
        if hasHardwareKeyboard {
            focusForHardwareKeyboardIfNeeded()
        } else if didChange {
            if imeProxyTextView.isFirstResponder, isTextInputSessionEligible, !isFindNavigatorActive {
                _ = requestKeyboardFocus(for: .explicitUserRequest)
            } else {
                notifyKeyboardBrowseModeChange()
            }
        }
        if reloadInputViewsIfNeeded, imeProxyTextView.isFirstResponder, isTextInputSessionEligible {
            imeProxyTextView.reloadInputViews()
        }
    }

    func markHardwareKeyboardDetectedFromKeyPress() {
        guard !hasHardwareKeyboardAttached else { return }
        hasHardwareKeyboardAttached = true
        focusForHardwareKeyboardIfNeeded()
        if imeProxyTextView.isFirstResponder, isTextInputSessionEligible {
            imeProxyTextView.reloadInputViews()
        }
    }

    private func focusForHardwareKeyboardIfNeeded() {
        guard hasHardwareKeyboardAttached, isTextInputSessionEligible, !isFindNavigatorActive else { return }
        guard keyboardFocusPolicy.isBrowsing || !imeProxyTextView.isFirstResponder else {
            return
        }
        _ = requestKeyboardFocus(for: .hardwareKeyboard)
    }

    // MARK: - Touch Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let location = touches.first?.location(in: self)
        if usesNativeTouchSelection, nativeSelectionInteractionActive {
            return
        }
        if usesNativeTouchSelection, nativeSelectedRange != nil || prefersNativeSelectionFirstResponder {
            if let location, isPointOnNativeSelectionHandleHitArea(location) {
                return
            }
            clearNativeSelectionStateForTerminalInput()
            guard shouldAutoFocusKeyboard(for: touches) else { return }
            requestKeyboardFocus(for: .directTouch)
            return
        }
        if usesAppOwnedTouchSelection,
           touchSelectionState.hasSelection,
           let location,
           !isPointOnTouchSelectionHandle(location) {
            clearTouchSelection()
        }
        if let location, isPointOnTouchSelectionHandle(location) {
            return
        }
        // Tap just focuses keyboard - no mouse events (avoids accidental selection)
        guard shouldAutoFocusKeyboard(for: touches) else { return }
        requestKeyboardFocus(for: .directTouch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        // Pan gesture handles scrolling, long press handles selection
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
    }

    func ghosttyPoint(_ location: CGPoint) -> CGPoint {
        // UIKit coordinates are top-left origin; Ghostty iOS expects the same.
        location
    }

    var isTerminalSelectionActive: Bool {
        isSelecting
            || touchSelectionState.hasSelection
            || (usesNativeTouchSelection && (nativeSelectionInteractionActive || nativeSelectedRange != nil))
    }

}

#endif
