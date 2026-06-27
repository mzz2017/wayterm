//
//  GhosttyTerminalView+iOS.swift
//  VVTerm
//
//  iOS UIView implementation for Ghostty terminal rendering
//

#if os(iOS)
import UIKit
import Metal
import OSLog
import SwiftUI
import IOSurface
import CoreImage
import GameController

/// UIView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering (Ghostty handles this internally)
/// - Touch and keyboard input
/// - Surface lifecycle requests
@MainActor
class GhosttyTerminalView: UIView {
    private static let textInputContextID = "app.vivy.VVTerm.GhosttyTerminalView"
    private static let imeProxyOffscreenFrame = CGRect(x: -10_000, y: -10_000, width: 1, height: 1)
    // MARK: - Properties

    private var ghosttyApp: ghostty_app_t?
    private weak var ghosttyAppWrapper: Ghostty.App?
    internal var surface: Ghostty.Surface?
    private let surfaceRegistration = GhosttySurfaceRegistration()
    private let worktreePath: String
    private let paneId: String?
    private let initialCommand: String?
    let useCustomIO: Bool
    private let presentationEnvironment: TerminalIOSPresentationEnvironment

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

    private var lastReportedGrid: (cols: Int, rows: Int) = (0, 0)
    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "GhosttyTerminal")

    private var isSelecting = false
    var isNativeHostScrollContainerEnabled = false
    private let scrollRuntime = TerminalIOSScrollRuntime()
    private let zoomRuntime = TerminalIOSZoomRuntime()
    var nativeSelectionSnapshot = TerminalNativeTextSnapshot.empty
    var nativeSelectedRange: NSRange?
    weak var nativeTextInputDelegate: UITextInputDelegate?
    lazy var nativeSelectionTokenizer = UITextInputStringTokenizer(textInput: self)
    var nativeSelectionAffinity: UITextStorageDirection = .forward
    var nativeSelectionInteractionActive = false
    var prefersNativeSelectionFirstResponder = false
    var shouldRestoreIMEProxyFocusAfterNativeSelection = false
    private var nativeTextInteraction: UITextInteraction?
    var nativeFindInteraction: UIFindInteraction?
    let findRuntime = TerminalIOSFindRuntime()
    let nativeFindDocumentIdentifier = "terminal"
    private let nativeFindOverlay = TerminalNativeFindOverlayView()
    var nativeFindDecorations: [TerminalNativeFindDecoration] = [] {
        didSet {
            updateNativeFindOverlay()
        }
    }
    let touchSelectionState = TerminalIOSTouchSelectionState()
    private let touchSelectionOverlay = TerminalTouchSelectionOverlayView()
    private let touchSelectionLoupe = TerminalTouchSelectionLoupeView()
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

    private var editMenuInteraction: UIEditMenuInteraction?

    private let lifecycleObservers = TerminalLifecycleObserverBag()
    var hasHardwareKeyboardAttached = false

    // MARK: - Text Input (for spacebar cursor control)
    var textInputModel = TerminalTextInputModel()
    let hardwarePressState = TerminalIOSHardwarePressState()
    private var suppressIMEProxyCallbacks = false
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

    private let renderingSetup = GhosttyRenderingSetup()
    let surfaceDisplayRuntime = TerminalIOSSurfaceDisplayRuntime()
    let surfaceLifecycleRuntime = TerminalIOSSurfaceLifecycleRuntime()
    let inputRuntime = TerminalIOSInputRuntime()
    private let selectionRuntime = TerminalIOSSelectionRuntime()

    func requestRender() {
        if isShuttingDown { return }
        if isPaused { return }
        guard surface?.unsafeCValue != nil else { return }
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
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
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

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this in dismantleUIView to ensure proper cleanup.
    func cleanup() {
        isShuttingDown = true
        isPaused = true
        surface = surfaceLifecycleRuntime.cleanup(
            surface: surface,
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
        surfaceLifecycleRuntime.pauseRendering(surface: surface)
    }

    /// Resume rendering/input after a pause.
    func resumeRendering() {
        guard !isShuttingDown else { return }
        isPaused = false
        surfaceLifecycleRuntime.resumeRendering(surface: surface) { [weak self] in
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

    private func setupSurface() {
        guard let app = ghosttyApp else {
            Self.logger.error("Cannot create surface: ghostty_app_t is nil")
            return
        }

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

        // CRITICAL: Configure the IOSurfaceLayer that Ghostty just added as a sublayer.
        // Ghostty's Metal renderer on iOS adds IOSurfaceLayer as a sublayer but doesn't
        // set its frame/contentsScale - we must do it here immediately after creation.
        // Without this, setSurfaceCallback will discard all frames due to size mismatch.
        configureIOSurfaceLayers(size: bounds.size)

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(cSurface: cSurface, callbackContext: callbackContext)

        surfaceRegistration.register(cSurface, appWrapper: ghosttyAppWrapper, terminalView: self)

        Self.logger.info("Ghostty surface created, sublayers: \(self.layer.sublayers?.count ?? 0)")
    }

    // MARK: - Size Change Handling (matches official Ghostty iOS pattern)

    /// Notify Ghostty of size changes. This method follows the official Ghostty iOS implementation.
    /// It sets content scale BEFORE size, using the contentScaleFactor.
    /// NOTE: On iOS, we must also configure the IOSurfaceLayer's frame/contentsScale in layoutSubviews
    /// and didMoveToWindow because Ghostty adds it as a sublayer that doesn't auto-resize.
    /// Without proper sublayer configuration, Ghostty's setSurfaceCallback will discard all frames.
    func sizeDidChange(_ size: CGSize) {
        if isShuttingDown { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard size.width > 0 && size.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: size)

        let scale = self.contentScaleFactor
        if surfaceDisplayRuntime.resizeIfNeeded(surface: surface, pointSize: size, scale: scale) {
            reportGridResizeIfNeeded()
        }

        if !isPaused {
            surfaceDisplayRuntime.redraw(surface: surface)
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

        guard let surface = surface?.unsafeCValue else { return }
        ghosttyAppWrapper?.updateSurfaceConfig(surface, presentationOverrides: presentationOverrides)
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

    // MARK: - Text Input Helpers

    func textInputGridMetrics() -> (cols: Int, rows: Int, cellSize: CGSize, length: Int) {
        let cols = max(lastReportedGrid.cols, 1)
        let rows = max(lastReportedGrid.rows, 1)
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        if cellSize.width > 0 {
            cellWidth = cellSize.width
        } else if bounds.width > 0 {
            cellWidth = bounds.width / CGFloat(cols)
        } else {
            cellWidth = 1
        }
        if cellSize.height > 0 {
            cellHeight = cellSize.height
        } else if bounds.height > 0 {
            cellHeight = bounds.height / CGFloat(rows)
        } else {
            cellHeight = 1
        }
        let size = CGSize(width: max(cellWidth, 1), height: max(cellHeight, 1))
        let length = max(cols * rows, 1)
        return (cols, rows, size, length)
    }

    private func textInputDocumentLength() -> Int {
        textInputModel.documentLength
    }

    private func clampTextInputIndex(_ index: Int) -> Int {
        min(max(index, 0), textInputDocumentLength())
    }

    var imeProxyCanBecomeFirstResponder: Bool {
        isTextInputSessionEligible && !isFindNavigatorActive
    }

    var imeProxyCanResignFirstResponder: Bool {
        inputRuntime.canResignIMEProxy(isTextInputSessionEligible: isTextInputSessionEligible)
    }

    var currentTextInputContextIdentifier: String? {
        guard isTextInputSessionEligible, !isFindNavigatorActive else { return nil }
        return Self.textInputContextID
    }

    var resolvedKeyboardAppearance: UIKeyboardAppearance {
        if #available(iOS 13.0, *) {
            return traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        return .default
    }

    func imeProxySnapshot() -> IMEProxySnapshot {
        IMEProxySnapshot(
            text: imeProxyTextView.text ?? "",
            selectedRange: imeProxyTextView.selectedRange,
            markedRange: imeProxyMarkedRange()
        )
    }

    private func imeProxyMarkedRange() -> NSRange? {
        guard let range = imeProxyTextView.markedTextRange else { return nil }
        let start = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        let end = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.end)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func withSuppressedIMEProxyCallbacks<T>(_ body: () -> T) -> T {
        let previous = suppressIMEProxyCallbacks
        suppressIMEProxyCallbacks = true
        defer { suppressIMEProxyCallbacks = previous }
        return body()
    }

    private func resetIMEProxyState() {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.text = ""
            imeProxyTextView.selectedRange = NSRange(location: 0, length: 0)
            imeProxyTextView.unmarkText()
        }
    }

    func syncTextInputModelFromIMEProxy() {
        guard !suppressIMEProxyCallbacks else { return }
        let snapshot = imeProxySnapshot()
        let effects = textInputModel.handleExternalState(
            text: snapshot.text,
            selectedRange: .init(location: snapshot.selectedRange.location, length: snapshot.selectedRange.length),
            markedRange: snapshot.markedRange.map { .init(location: $0.location, length: $0.length) }
        )
        runTerminalTextInputEffects(effects)
        if snapshot.markedRange == nil {
            syncIMEPreedit(nil)
        }
    }

    var hasLocalTextInputSession: Bool {
        textInputModel.documentLength > 0 || textInputModel.hasActiveIMEComposition
    }

    private func setIMEProxySelection(_ range: NSRange) {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.selectedRange = range
        }
        syncTextInputModelFromIMEProxy()
    }

    func moveIMEProxyCursorLeft() {
        let selection = imeProxyTextView.selectedRange
        let nsText = (imeProxyTextView.text ?? "") as NSString
        let newLocation: Int
        if selection.length > 0 {
            newLocation = selection.location
        } else if selection.location > 0 {
            let previousRange = nsText.rangeOfComposedCharacterSequence(at: max(selection.location - 1, 0))
            newLocation = previousRange.location
        } else {
            newLocation = 0
        }
        setIMEProxySelection(NSRange(location: newLocation, length: 0))
    }

    func moveIMEProxyCursorRight() {
        let selection = imeProxyTextView.selectedRange
        let nsText = (imeProxyTextView.text ?? "") as NSString
        let newLocation: Int
        if selection.length > 0 {
            newLocation = selection.location + selection.length
        } else if selection.location < nsText.length {
            let nextRange = nsText.rangeOfComposedCharacterSequence(at: selection.location)
            newLocation = nextRange.location + nextRange.length
        } else {
            newLocation = nsText.length
        }
        setIMEProxySelection(NSRange(location: newLocation, length: 0))
    }

    func moveIMEProxyCursorToStart() {
        setIMEProxySelection(NSRange(location: 0, length: 0))
    }

    func moveIMEProxyCursorToEnd() {
        let length = (imeProxyTextView.text ?? "").utf16.count
        setIMEProxySelection(NSRange(location: length, length: 0))
    }

    func imeProxyDidDeleteBackward(before: IMEProxySnapshot?) {
        guard !suppressIMEProxyCallbacks else { return }
        let after = imeProxySnapshot()
        if before == after,
           let before,
           before.text.isEmpty,
           before.markedRange == nil,
           before.selectedRange.length == 0,
           before.selectedRange.location == 0 {
            runTerminalTextInputEffects([.sendSpecialKey(.backspace)])
            return
        }
        syncTextInputModelFromIMEProxy()
    }

    func imeProxyFocusDidChange(isFocused: Bool) {
        surfaceLifecycleRuntime.setFocus(isFocused, surface: surface)
        if isFocused {
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
        } else {
            imeProxyTextView.endDictationSession(commit: true)
            invalidateLocalTextInputSession()
            stopKeyRepeat()
        }
    }

    func imeProxyCaretRect(for position: UITextPosition) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: position)
        return textInputCaretRect(for: index)
    }

    func imeProxyFirstRect(for range: UITextRange) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        return textInputCaretRect(for: index)
    }

    func invalidateLocalTextInputSession() {
        resetIMEProxyState()
        let effects = textInputModel.invalidateSession()
        runTerminalTextInputEffects(effects)
        syncIMEPreedit(nil)
    }

    func runTerminalTextInputEffects(_ effects: [TerminalTextInputModel.Effect]) {
        inputRuntime.handleTerminalTextInputEffects(effects, context: terminalTextInputEffectExecutionContext())
    }

    func textInputCaretRect(for index: Int) -> CGRect {
        guard let surface = surface?.unsafeCValue else {
            let metrics = textInputGridMetrics()
            return CGRect(x: 0, y: 0, width: metrics.cellSize.width, height: metrics.cellSize.height)
        }

        let imePoint = inputRuntime.imePoint(surface: surface)

        let cellWidth = max(cellSize.width, max(imePoint.width, 1))
        let cellHeight = max(cellSize.height, max(imePoint.height, 1))
        let currentCharacterIndex = textInputModel.committedCursorCharacterIndex
        let targetCharacterIndex = textInputModel.committedCharacterIndex(forDocumentOffset: clampTextInputIndex(index))
        let delta = targetCharacterIndex - currentCharacterIndex

        return CGRect(
            x: imePoint.minX + CGFloat(delta) * cellWidth,
            y: imePoint.minY,
            width: max(imePoint.width, cellWidth),
            height: max(imePoint.height, cellHeight)
        )
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

    func notifyFindNavigatorVisibilityChange() {
        onFindNavigatorVisibilityChange?(isFindNavigatorVisible)
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
        guard let surface = surface?.unsafeCValue else { return }
        let scheme: ghostty_color_scheme_e = traitCollection.userInterfaceStyle == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        surfaceDisplayRuntime.setColorScheme(scheme, surface: surface)
    }

    private func setupHardwareKeyboardObservation() {
        lifecycleObservers.observeHardwareKeyboardChanges { [weak self] in
            self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
        }
        updateHardwareKeyboardState(reloadInputViewsIfNeeded: false)
    }

    private func updateHardwareKeyboardState(reloadInputViewsIfNeeded: Bool) {
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

    private func ghosttyPoint(_ location: CGPoint) -> CGPoint {
        // UIKit coordinates are top-left origin; Ghostty iOS expects the same.
        location
    }

    // MARK: - Scroll Gesture

    func setNativeHostScrollContainerEnabled(_ enabled: Bool) {
        isNativeHostScrollContainerEnabled = enabled
        if enabled {
            scrollRuntime.stopMomentumScrolling()
        }
    }

    func prepareForNativeHostScroll() {
        scrollRuntime.prepareForNativeHostScroll()
    }

    func currentScrollOwner() -> TerminalScrollOwner {
        TerminalScrollRoutingPolicy.owner(for: TerminalScrollContext(
            remoteScrollOwnerActive: surface?.mouseCaptured ?? false,
            remoteAlternateScreenActive: surface?.inAlternateScreen ?? false,
            hasHostScrollableRows: hasHostScrollableRows,
            isSelecting: isTerminalSelectionActive,
            isPinching: zoomRuntime.isPinchingTerminalZoom
        ))
    }

    private var hasHostScrollableRows: Bool {
        guard let scrollbar else { return false }
        return scrollbar.total > scrollbar.len
    }

    @objc private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        guard surface != nil else { return }
        if isNativeHostScrollContainerEnabled,
           currentScrollOwner() == .hostScrollback {
            return
        }
        if isSelecting { return }
        if zoomRuntime.isPinchingTerminalZoom { return }
        if touchSelectionState.hasSelection {
            if recognizer.state == .began,
               !isPointOnTouchSelectionHandle(recognizer.location(in: self)) {
                clearTouchSelection()
            }
            return
        }

        scrollRuntime.handlePanGesture(
            recognizer,
            in: self,
            mapLocation: { [weak self] location in
                self?.ghosttyPoint(location) ?? location
            },
            hasSurface: { [weak self] in
                self?.surface != nil
            },
            sendMousePosition: { [weak self] position in
                self?.surface?.sendMousePos(.init(x: position.x, y: position.y, mods: []))
            },
            sendScrollEvent: { [weak self] event in
                self?.surface?.sendMouseScroll(event)
            },
            requestRender: { [weak self] in
                self?.requestRender()
            }
        )
    }

    @objc private func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
        zoomRuntime.handlePinchGesture(
            recognizer,
            canHandlePinchZoom: canHandlePinchZoom,
            currentFontSize: { [weak self] in
                self?.surfacePresentationOverrides.resolvedFontSize() ?? TerminalDefaults.storedFontSize()
            },
            performZoomAction: onZoomAction,
            stopMomentumScrolling: { [weak self] in
                self?.scrollRuntime.stopMomentumScrolling()
            },
            requestIndicatorLayout: { [weak self] in
                self?.setNeedsLayout()
                self?.layoutIfNeeded()
                if let self {
                    self.zoomRuntime.bringIndicatorToFront(in: self)
                }
            }
        )
    }

    var canHandlePinchZoom: Bool {
        if usesNativeTouchSelection, nativeSelectionInteractionActive || nativeSelectedRange != nil {
            return false
        }
        if usesAppOwnedTouchSelection, touchSelectionState.hasSelection {
            return false
        }
        return true
    }

    private var isTerminalSelectionActive: Bool {
        isSelecting
            || touchSelectionState.hasSelection
            || (usesNativeTouchSelection && (nativeSelectionInteractionActive || nativeSelectedRange != nil))
    }

    private func setupNativeTextSelectionInteractions() {
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.delegate = self
        interaction.textInput = self
        addInteraction(interaction)
        nativeTextInteraction = interaction
        for gesture in interaction.gesturesForFailureRequirements {
            scrollRecognizer.require(toFail: gesture)
        }
    }

    private func setupNativeFindInteraction() {
        guard #available(iOS 16.0, *), nativeFindInteraction == nil else { return }
        let interaction = UIFindInteraction(sessionDelegate: self)
        interaction.optionsMenuProvider = { _ in nil }
        addInteraction(interaction)
        nativeFindInteraction = interaction
    }

    private func notifyNativeSelectionLayoutChange() {
        guard nativeSelectionInteractionActive || nativeSelectedRange != nil else { return }
        nativeTextInputDelegate?.textWillChange(self)
        nativeTextInputDelegate?.textDidChange(self)
        nativeTextInputDelegate?.selectionWillChange(self)
        nativeTextInputDelegate?.selectionDidChange(self)
    }

    func refreshNativeSelectionSnapshot(resetSelection: Bool = false) {
        guard usesNativeTouchSelection else { return }

        nativeSelectionSnapshot = buildNativeSelectionSnapshot()
        updateNativeFindOverlay()
        if resetSelection {
            setNativeSelectedRange(nil)
            return
        }

        guard let nativeSelectedRange else { return }
        let clamped = nativeSelectionSnapshot.clampedRange(nativeSelectedRange)
        if clamped != nativeSelectedRange {
            setNativeSelectedRange(clamped)
        } else {
            notifyNativeSelectionLayoutChange()
        }
    }

    private func buildNativeSelectionSnapshot() -> TerminalNativeTextSnapshot {
        selectionRuntime.nativeTextSnapshot(
            surface: surface?.unsafeCValue,
            metrics: selectionGridMetrics()
        )
    }

    func setNativeSelectedRange(_ range: NSRange?) {
        let clampedRange = range.map { nativeSelectionSnapshot.clampedRange($0) }
        if nativeSelectedRange == clampedRange {
            notifyNativeSelectionLayoutChange()
            return
        }

        nativeTextInputDelegate?.selectionWillChange(self)
        nativeSelectedRange = clampedRange
        if clampedRange == nil, !nativeSelectionInteractionActive {
            prefersNativeSelectionFirstResponder = false
        }
        nativeTextInputDelegate?.selectionDidChange(self)
    }

    private func isPointOnNativeSelectionHandleHitArea(_ point: CGPoint) -> Bool {
        guard usesNativeTouchSelection,
              let nativeSelectedRange,
              nativeSelectedRange.length > 0 else {
            return false
        }
        let clamped = nativeSelectionSnapshot.clampedRange(nativeSelectedRange)
        guard clamped.length > 0 else { return false }

        let startRect = nativeSelectionSnapshot.caretRect(for: clamped.location)
        let endRect = nativeSelectionSnapshot.caretRect(for: clamped.location + clamped.length)
        let hitSlop = max(28, nativeSelectionSnapshot.cellSize.height * 1.5)
        return startRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
            || endRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
    }

    private func selectedNativeSelectionText() -> String? {
        guard let nativeSelectedRange, nativeSelectedRange.length > 0 else { return nil }
        return nativeSelectionSnapshot.text(in: nativeSelectedRange)
    }

    private func updateNativeFindOverlay() {
        guard usesNativeTouchSelection else { return }
        let highlights = nativeFindDecorations.flatMap { decoration in
            nativeSelectionSnapshot.selectionRects(for: decoration.range).map {
                TerminalNativeFindOverlayView.Highlight(rect: $0.rect, style: decoration.style)
            }
        }
        nativeFindOverlay.highlights = highlights
    }

    @available(iOS 16.0, *)
    private func beginFindNavigatorPresentation(restoreTerminalFocus: Bool) {
        findRuntime.beginNavigatorLifecycle(restoreTerminalFocus: restoreTerminalFocus)
        notifyFindNavigatorVisibilityChange()
        stopKeyRepeat()

        if !super.isFirstResponder {
            _ = super.becomeFirstResponder()
        }

        surfaceLifecycleRuntime.setFocus(false, surface: surface)
    }

    func endFindNavigatorLifecycle() -> Bool {
        let shouldRestoreTerminalFocus = findRuntime.endNavigatorLifecycle()
        if !shouldRestoreTerminalFocus, super.isFirstResponder {
            _ = super.resignFirstResponder()
        }
        return shouldRestoreTerminalFocus
    }

    @available(iOS 16.0, *)
    private func presentFindNavigator(prefillingSelectedText: Bool = false) {
        guard let nativeFindInteraction else { return }
        beginFindNavigatorPresentation(restoreTerminalFocus: imeProxyTextView.isFirstResponder)
        refreshNativeSelectionSnapshot()
        if prefillingSelectedText, let selectionText = normalizedSelectionMenuText() {
            nativeFindInteraction.searchText = selectionText
            findRuntime.applyExternalQuery(selectionText) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
            performGhosttyFindQuery(selectionText)
        }
        nativeFindInteraction.presentFindNavigator(showingReplace: false)
    }

    func showFindNavigator(prefillingSelectedText: Bool = false) {
        guard usesNativeTouchSelection else { return }
        if #available(iOS 16.0, *) {
            presentFindNavigator(prefillingSelectedText: prefillingSelectedText)
        }
    }

    func dismissFindNavigator() {
        guard #available(iOS 16.0, *), nativeFindInteraction?.isFindNavigatorVisible == true else { return }
        nativeFindInteraction?.dismissFindNavigator()
    }

    @MainActor
    @discardableResult
    func performGhosttyFindQuery(
        _ query: String,
        keepNavigatorVisibleOnSearchEnd: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        findRuntime.resetReportedResults()
        let action = "search:\(query)"
        if keepNavigatorVisibleOnSearchEnd {
            findRuntime.suppressNextGhosttySearchEnd()
        }
        guard surface.perform(action: action) else {
            if keepNavigatorVisibleOnSearchEnd {
                findRuntime.cancelSuppressedGhosttySearchEnd()
            }
            return false
        }
        if query.isEmpty {
            if #available(iOS 16.0, *) {
                findRuntime.resetNativeSession { [weak self] in
                    self?.nativeFindInteraction?.updateResultCount()
                }
            }
        }
        return true
    }

    @MainActor
    func navigateGhosttyFind(_ direction: UITextStorageDirection) {
        guard let surface else { return }
        let action = direction == .backward ? "navigate_search:previous" : "navigate_search:next"
        _ = surface.perform(action: action)
    }

    @MainActor
    func endGhosttyFindSearchForNavigatorDismissal() {
        guard let surface else { return }
        findRuntime.resetReportedResults()
        findRuntime.suppressNextGhosttySearchEnd()
        if !surface.perform(action: "end_search") {
            findRuntime.cancelSuppressedGhosttySearchEnd()
        }
    }

    @MainActor
    func invalidateGhosttyFindWithoutClosingNavigator() {
        performGhosttyFindQuery("", keepNavigatorVisibleOnSearchEnd: true)
    }

    func handleGhosttySearchStarted(needle: String) {
        guard usesNativeTouchSelection else { return }
        findRuntime.resetReportedResults()
        if #available(iOS 16.0, *) {
            nativeFindInteraction?.searchText = needle
            findRuntime.applyExternalQuery(needle) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
            if nativeFindInteraction?.isFindNavigatorVisible != true {
                beginFindNavigatorPresentation(restoreTerminalFocus: imeProxyTextView.isFirstResponder)
                nativeFindInteraction?.presentFindNavigator(showingReplace: false)
            }
        }
    }

    func handleGhosttySearchEnded() {
        guard usesNativeTouchSelection else { return }
        findRuntime.resetReportedResults()
        if #available(iOS 16.0, *) {
            findRuntime.resetNativeSession { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
            if findRuntime.consumeSuppressedGhosttySearchEnd() {
                return
            } else if nativeFindInteraction?.isFindNavigatorVisible == true {
                nativeFindInteraction?.dismissFindNavigator()
            } else if findRuntime.isNavigatorLifecycleActive {
                _ = endFindNavigatorLifecycle()
                notifyFindNavigatorVisibilityChange()
            }
        }
    }

    func handleGhosttySearchTotalChange(_ total: Int?) {
        guard usesNativeTouchSelection else { return }
        if #available(iOS 16.0, *) {
            findRuntime.updateReportedTotal(total) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
        }
    }

    func handleGhosttySearchSelectedChange(_ selected: Int?) {
        guard usesNativeTouchSelection else { return }
        if #available(iOS 16.0, *) {
            findRuntime.updateReportedSelectedIndex(selected) { [weak self] in
                self?.nativeFindInteraction?.updateResultCount()
            }
        }
    }

    var usesNativeTouchSelection: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var usesAppOwnedTouchSelection: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !usesNativeTouchSelection
    }

    private func selectionGridMetrics() -> TerminalSelectionGridMetrics? {
        guard let terminalSize = terminalSize() else { return nil }
        let cols = max(Int(terminalSize.columns), 1)
        let rows = max(Int(terminalSize.rows), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : max(bounds.width / CGFloat(cols), 1)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : max(bounds.height / CGFloat(rows), 1)
        return TerminalSelectionGridMetrics(
            cols: cols,
            rows: rows,
            cellSize: CGSize(width: resolvedCellWidth, height: resolvedCellHeight)
        )
    }

    private func touchSelectionLayout() -> TerminalTouchSelectionLayout? {
        guard let metrics = selectionGridMetrics() else { return nil }
        return TerminalTouchSelectionLayout(metrics: metrics, bounds: bounds)
    }

    private func updateTouchSelectionOverlay() {
        guard usesAppOwnedTouchSelection,
              let touchSelection = touchSelectionState.selection,
              let layout = touchSelectionLayout() else {
            touchSelectionOverlay.isHidden = true
            touchSelectionOverlay.clear()
            return
        }

        let normalized = touchSelection.normalized
        let rects = layout.selectionRects(for: normalized)
        let startFrame = layout.cellFrame(for: normalized.start)
        let endFrame = layout.cellFrame(for: normalized.end)
        touchSelectionOverlay.isHidden = false
        touchSelectionOverlay.update(
            rects: rects,
            startAnchor: CGPoint(x: startFrame.minX, y: startFrame.minY),
            endAnchor: CGPoint(x: endFrame.maxX, y: endFrame.maxY)
        )
    }

    func isPointOnTouchSelectionHandle(_ point: CGPoint) -> Bool {
        guard usesAppOwnedTouchSelection, touchSelectionState.hasSelection else { return false }

        let startHandlePoint = touchSelectionOverlay.convert(point, from: self)
        return touchSelectionOverlay.startHandle.frame.insetBy(dx: -22, dy: -22).contains(startHandlePoint) ||
            touchSelectionOverlay.endHandle.frame.insetBy(dx: -22, dy: -22).contains(startHandlePoint)
    }

    private func dismissEditMenuIfNeeded() {
        editMenuInteraction?.dismissMenu()
    }

    private func clearTouchSelection() {
        touchSelectionState.clear()
        updateTouchSelectionOverlay()
        touchSelectionLoupe.hideLoupe()
        isSelecting = false
    }

    private func updateTouchSelectionLoupe(at location: CGPoint) {
        guard usesAppOwnedTouchSelection else { return }

        let previousVisibility = touchSelectionLoupe.isHidden
        touchSelectionLoupe.isHidden = true
        touchSelectionLoupe.update(
            from: self,
            focusPoint: location,
            in: bounds,
            safeAreaInsets: safeAreaInsets
        )
        if previousVisibility {
            bringSubviewToFront(touchSelectionOverlay)
            bringSubviewToFront(touchSelectionLoupe)
        }
    }

    private func quickLookWordSelection(at location: CGPoint) -> TerminalGridSelection? {
        guard let layout = touchSelectionLayout(),
              let surface,
              let cSurface = surface.unsafeCValue else { return nil }

        let pos = ghosttyPoint(location)
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        return GhosttyTerminalTextReader.quickLookWordSelection(
            surface: cSurface,
            layout: layout
        )
    }

    private func startTouchSelection(at location: CGPoint) {
        let wordSelection = quickLookWordSelection(at: location)
        let point = touchSelectionLayout()?.gridPoint(for: location)
        guard touchSelectionState.begin(wordSelection: wordSelection, point: point) else {
            return
        }
        updateTouchSelectionOverlay()
        isSelecting = true
    }

    private func updateTouchSelection(at location: CGPoint) {
        guard let point = touchSelectionLayout()?.gridPoint(for: location) else { return }
        if touchSelectionState.update(to: point) {
            updateTouchSelectionOverlay()
            isSelecting = true
        }
    }

    private func updateTouchSelectionHandle(_ kind: TerminalTouchSelectionHandleKind, at location: CGPoint) {
        guard let point = touchSelectionLayout()?.gridPoint(for: location) else { return }
        guard touchSelectionState.updateHandle(kind, to: point) else { return }
        updateTouchSelectionOverlay()
    }

    private func finishTouchSelection() {
        isSelecting = false
        touchSelectionLoupe.hideLoupe()
        guard let touchSelection = touchSelectionState.selection,
              let menuPoint = touchSelectionLayout()?.menuPoint(for: touchSelection) else { return }
        showEditMenu(at: menuPoint)
    }

    func currentSelectionText() -> String? {
        if let nativeSelectionText = selectedNativeSelectionText() {
            return nativeSelectionText
        }
        if let touchSelectionText = touchSelectionText() {
            return touchSelectionText
        }
        return ghosttySelectionText()
    }

    private func touchSelectionText() -> String? {
        guard let touchSelection = touchSelectionState.selection,
              let surface = surface?.unsafeCValue else { return nil }

        let normalized = touchSelection.normalized
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(normalized.start.column),
                y: UInt32(normalized.start.row)
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(normalized.end.column),
                y: UInt32(normalized.end.row)
            ),
            rectangle: false
        )
        return GhosttyTerminalTextReader.readText(surface: surface, selection: selection)
    }

    private func ghosttySelectionText() -> String? {
        guard let surface = surface?.unsafeCValue else { return nil }
        return GhosttyTerminalTextReader.readSelection(surface: surface)
    }

    private func copyTextToClipboard(_ text: String) {
        let cleaned = TerminalTextCleaner.cleanText(text, settings: .current())
        Clipboard.copy(cleaned)
    }

    private func normalizedSelectionMenuText() -> String? {
        guard let text = currentSelectionText()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private func selectionMenuSourceRect() -> CGRect {
        if usesNativeTouchSelection,
           let selectedTextRange {
            let rect = firstRect(for: selectedTextRange)
            if !rect.isNull, !rect.isEmpty {
                return rect
            }
        }
        return CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
    }

    private func presentSelectionMenuController(_ controller: UIViewController) {
        presentationEnvironment.presentController(controller, self, selectionMenuSourceRect())
    }

    private func presentShareSheet(for text: String) {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        presentSelectionMenuController(controller)
    }

    private func presentDictionaryLookup(for text: String) {
        guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text) else { return }
        let controller = UIReferenceLibraryViewController(term: text)
        presentSelectionMenuController(controller)
    }

    private func searchWeb(for text: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components?.url else { return }
        presentationEnvironment.openURL(url)
    }

    @available(iOS 16.0, *)
    func nativeSelectionMenuElements() -> [UIMenuElement] {
        let selectionText = normalizedSelectionMenuText()
        var actions: [UIMenuElement] = []

        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        if nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil {
            actions.append(UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.selectAll(nil)
            })
        }

        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Find"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.presentFindNavigator(prefillingSelectedText: true)
            })
        }

        return actions
    }

    private func selectAllVisibleText() {
        if usesNativeTouchSelection {
            refreshNativeSelectionSnapshot()
            guard nativeSelectionSnapshot.length > 0 else { return }
            setNativeSelectedRange(NSRange(location: 0, length: nativeSelectionSnapshot.length))
            return
        }

        guard usesAppOwnedTouchSelection,
              let metrics = selectionGridMetrics() else { return }
        touchSelectionState.setSelection(TerminalGridSelection(
            start: TerminalGridPoint(row: 0, column: 0),
            end: TerminalGridPoint(row: metrics.rows - 1, column: metrics.cols - 1)
        ))
        updateTouchSelectionOverlay()
        finishTouchSelection()
    }

    // MARK: - Selection Gestures

    /// Double-tap to select word
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        clearTouchSelection()
        requestKeyboardFocus(for: .selectionGesture)

        // Double-click to select word (no modifiers)
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        requestRender()

        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }

    /// Triple-tap to select line
    @objc private func handleTripleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        clearTouchSelection()
        requestKeyboardFocus(for: .selectionGesture)

        // Triple-click to select line
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        for _ in 0..<3 {
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        }
        requestRender()

        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }

    /// Long press + drag for custom selection
    @objc private func handleSelectionPress(_ recognizer: UILongPressGestureRecognizer) {
        if usesAppOwnedTouchSelection {
            let location = recognizer.location(in: self)

            switch recognizer.state {
            case .began:
                dismissEditMenuIfNeeded()
                startTouchSelection(at: location)
                requestKeyboardFocus(for: .selectionGesture)
                updateTouchSelectionLoupe(at: location)
            case .changed:
                updateTouchSelection(at: location)
                updateTouchSelectionLoupe(at: location)
            case .ended:
                updateTouchSelection(at: location)
                finishTouchSelection()
            case .cancelled, .failed:
                clearTouchSelection()
            default:
                break
            }
            return
        }

        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        switch recognizer.state {
        case .began:
            isSelecting = true
            requestKeyboardFocus(for: .selectionGesture)
            // Start selection with click (no shift for initial position)
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            requestRender()
        case .changed:
            // Drag to extend selection
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            requestRender()
        case .ended, .cancelled, .failed:
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
            isSelecting = false
            requestRender()
            showEditMenu(at: location)
        default:
            break
        }
    }

    @objc private func handleSelectionHandlePan(_ recognizer: UIPanGestureRecognizer) {
        guard usesAppOwnedTouchSelection, touchSelectionState.hasSelection else { return }

        let kind: TerminalTouchSelectionHandleKind
        if recognizer.view === touchSelectionOverlay.startHandle {
            kind = .start
        } else {
            kind = .end
        }

        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            dismissEditMenuIfNeeded()
            isSelecting = true
            updateTouchSelectionHandle(kind, at: location)
            updateTouchSelectionLoupe(at: location)
        case .changed:
            updateTouchSelectionHandle(kind, at: location)
            updateTouchSelectionLoupe(at: location)
        case .ended:
            updateTouchSelectionHandle(kind, at: location)
            isSelecting = false
            finishTouchSelection()
        case .cancelled, .failed:
            isSelecting = false
            touchSelectionLoupe.hideLoupe()
        default:
            break
        }
    }

    private func showEditMenu(at location: CGPoint) {
        let hasGhosttySelection = selectionRuntime.hasGhosttySelection(surface: surface?.unsafeCValue)
        guard touchSelectionState.hasSelection || hasGhosttySelection else {
            return
        }
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        editMenuInteraction?.presentEditMenu(with: config)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            if let nativeSelectedRange, nativeSelectedRange.length > 0 {
                return true
            }
            if touchSelectionState.hasSelection {
                return true
            }
            return selectionRuntime.hasGhosttySelection(surface: surface?.unsafeCValue)
        case #selector(selectAll(_:)):
            if usesNativeTouchSelection {
                return nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil
            }
            return usesAppOwnedTouchSelection && selectionGridMetrics() != nil
        case #selector(find(_:)):
            return usesNativeTouchSelection
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            if #available(iOS 16.0, *), usesNativeTouchSelection {
                return nativeFindInteraction?.isFindNavigatorVisible == true
            }
            return false
        case #selector(useSelectionForFind(_:)):
            if usesNativeTouchSelection {
                return normalizedSelectionMenuText() != nil
            }
            return false
        case #selector(paste(_:)):
            return true
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc override func copy(_ sender: Any?) {
        guard let selectionText = currentSelectionText(), !selectionText.isEmpty else { return }
        copyTextToClipboard(selectionText)
    }

    @objc override func selectAll(_ sender: Any?) {
        selectAllVisibleText()
    }

    @objc override func paste(_ sender: Any?) {
        performPasteAction()
    }

    @objc override func find(_ sender: Any?) {
        showFindNavigator()
    }

    @objc override func useSelectionForFind(_ sender: Any?) {
        showFindNavigator(prefillingSelectedText: true)
    }

    @objc override func findNext(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findNext()
    }

    @objc override func findPrevious(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findPrevious()
    }

    func clearSelectionAfterPaste() {
        if usesNativeTouchSelection, nativeSelectedRange != nil {
            setNativeSelectedRange(nil)
            prefersNativeSelectionFirstResponder = false
        }
        if usesAppOwnedTouchSelection, touchSelectionState.hasSelection {
            clearTouchSelection()
        }
    }

    // MARK: - Text Input from Software Keyboard

    /// Send text to the terminal (called from keyboard toolbar or software keyboard)
    func sendText(_ text: String) {
        guard canRouteTerminalInput else { return }
        surface?.sendText(text)
        requestRender()
    }

    func pasteTextFromClipboard() {
        guard canRouteTerminalInput else { return }
        _ = surface?.perform(action: "paste_from_clipboard")
        requestRender()
    }

    private func sendRawTerminalText(_ text: String, invalidateLocalSession: Bool) {
        guard canRouteTerminalInput else { return }
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }

        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        if let writeCallback {
            writeCallback(data)
        } else {
            surface?.sendText(text)
        }
        requestRender()
    }

    private func terminalTextInputExecutionContext() -> TerminalIOSInputRuntime.TerminalTextInputExecutionContext {
        TerminalIOSInputRuntime.TerminalTextInputExecutionContext(
            sendRawText: { [weak self] text, invalidateLocalSession in
                self?.sendRawTerminalText(text, invalidateLocalSession: invalidateLocalSession)
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint, invalidateLocalSession in
                self?.sendModifiedKey(
                    key,
                    mods: mods,
                    text: text,
                    unshiftedCodepoint: unshiftedCodepoint,
                    invalidateLocalSession: invalidateLocalSession
                )
            }
        )
    }

    private func terminalTextInputEffectExecutionContext() -> TerminalIOSInputRuntime.TerminalTextInputEffectExecutionContext {
        TerminalIOSInputRuntime.TerminalTextInputEffectExecutionContext(
            textWillChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.textWillChange(self)
            },
            selectionWillChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.selectionWillChange(self)
            },
            textDidChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.textDidChange(self)
            },
            selectionDidChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.selectionDidChange(self)
            },
            syncPreedit: { [weak self] text in
                self?.syncIMEPreedit(text)
            },
            terminalTextInput: terminalTextInputExecutionContext(),
            sendGhosttyKeyPress: { [weak self] key in
                self?.sendKeyPress(key)
            }
        )
    }

    func handleIMEProxyInsertText(_ text: String, fromIMEComposition: Bool = false) -> Bool {
        guard canRouteTerminalInput else { return true }
        if isNativeSelectionTextInputContext {
            clearNativeSelectionStateForTerminalInput()
        }

        return inputRuntime.handleIMEInsertText(
            text,
            fromIMEComposition: fromIMEComposition,
            hasPendingSystemTextInputHardwareKey: !fromIMEComposition && pendingSystemTextInputHardwareKeyCount > 0,
            context: imeInsertExecutionContext()
        )
    }

    private func consumeIMEProxyModifierState() -> TerminalIOSInputRuntime.ModifierState {
        let mods = keyboardToolbar?.consumeModifiers() ?? (ctrl: false, alt: false, command: false, shift: false)
        return TerminalIOSInputRuntime.ModifierState(
            ctrl: mods.ctrl,
            alt: mods.alt,
            command: mods.command,
            shift: mods.shift
        )
    }

    private func imeInsertExecutionContext() -> TerminalIOSInputRuntime.IMEInsertExecutionContext {
        TerminalIOSInputRuntime.IMEInsertExecutionContext(
            consumeModifiers: { [weak self] in
                self?.consumeIMEProxyModifierState() ?? .none
            },
            interpretPendingHardwareKey: { [weak self] text in
                guard let self,
                      let key = self.consumePendingSystemTextInputHardwareKey(),
                      self.sendInterpretedHardwareKeyText(text, for: key)
                else {
                    return false
                }
                self.invalidateLocalTextInputSession()
                return true
            },
            routeToolbarKey: { [weak self] key in
                self?.routeToolbarKey(key)
            },
            interceptRichPaste: { [weak self] in
                self?.interceptRichPasteIfNeeded() ?? false
            },
            invalidateLocalTextInputSession: { [weak self] in
                self?.invalidateLocalTextInputSession()
            },
            commitTextToIMEProxy: { [weak self] text in
                // Plain text goes into the persistent local document; the text
                // input model reconciles it with the terminal by sending the delta.
                self?.imeProxyTextView.insertCommittedText(text)
            },
            commitMarkedTextIfNeeded: { [weak self] in
                self?.commitIMEProxyMarkedTextIfNeeded()
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint in
                self?.sendModifiedKey(key, mods: mods, text: text, unshiftedCodepoint: unshiftedCodepoint)
            },
            sendAnsiData: { [weak self] data in
                self?.sendAnsiSequence(data)
            },
            sendText: { [weak self] text in
                self?.sendText(text)
            }
        )
    }

    private func commitIMEProxyMarkedTextIfNeeded() {
        guard imeProxyMarkedRange() != nil else { return }
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.unmarkText()
        }
        syncTextInputModelFromIMEProxy()
    }

    func sendKeyPress(_ key: Ghostty.Input.Key) {
        guard canRouteTerminalInput else { return }
        guard let surface = surface else { return }
        surface.sendKeyEvent(.init(key: key, action: .press))
        surface.sendKeyEvent(.init(key: key, action: .release))
        requestRender()
    }

    private func sendAnsiSequence(_ data: Data) {
        guard canRouteTerminalInput else { return }
        invalidateLocalTextInputSession()
        let text = String(decoding: data, as: UTF8.self)
        sendText(text)
    }

    private var currentIMEPrimaryLanguage: String? {
        imeProxyTextView.textInputMode?.primaryLanguage ?? textInputMode?.primaryLanguage
    }

    private func syncIMEPreedit(_ text: String?) {
        if inputRuntime.syncVisiblePreedit(
            text,
            inputModePrimaryLanguage: currentIMEPrimaryLanguage,
            surface: surface?.unsafeCValue
        ) {
            requestRender()
        }
    }

    func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0,
        invalidateLocalSession: Bool = true
    ) {
        guard canRouteTerminalInput else { return }
        guard let surface = surface else { return }
        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        let press = Ghostty.Input.KeyEvent(
            key: key,
            action: .press,
            text: text,
            composing: false,
            mods: mods,
            consumedMods: [],
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface.sendKeyEvent(press)
        let release = Ghostty.Input.KeyEvent(
            key: key,
            action: .release,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: [],
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface.sendKeyEvent(release)
        requestRender()
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard surface != nil else { return }
        inputRuntime.handleSpecialKey(key, context: terminalInputExecutionContext())
    }

    /// Send control key combination (e.g., Ctrl+C)
    func sendControlKey(_ char: Character) {
        guard surface != nil else { return }
        inputRuntime.handleControlKey(char, context: terminalInputExecutionContext())
    }

    private func terminalInputExecutionContext() -> TerminalIOSInputRuntime.TerminalInputExecutionContext {
        TerminalIOSInputRuntime.TerminalInputExecutionContext(
            invalidateLocalTextInputSession: { [weak self] in
                self?.invalidateLocalTextInputSession()
            },
            sendText: { [weak self] text in
                self?.sendText(text)
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint in
                self?.sendModifiedKey(key, mods: mods, text: text, unshiftedCodepoint: unshiftedCodepoint)
            }
        )
    }

}

#endif
