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
/// - Surface lifecycle management
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
    private let useCustomIO: Bool
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

    @discardableResult
    func sendReturnKey() -> Bool {
        guard canRouteTerminalInput else { return false }
        sendToolbarKey(.enter)
        return true
    }

    /// Optional app-level paste interceptor used for rich clipboard routing.
    var richPasteInterceptor: ((GhosttyTerminalView) -> Bool)?
    private var didSignalReady = false

    /// Prevent rendering when the view is offscreen or being torn down.
    private var isShuttingDown = false
    private var isPaused = false
    private var customIORedrawScheduled = false
    private var keyRepeatTimer: DispatchSourceTimer?
    private var repeatingHardwareKey: UIKey?
    private var repeatingFallbackKey: Ghostty.Input.Key?
    private var repeatingFallbackModifiers: UIKeyModifierFlags = []
    private var repeatingKeyCode: UInt16?

    private var lastReportedGrid: (cols: Int, rows: Int) = (0, 0)
    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "GhosttyTerminal")

    private var isSelecting = false
    private var isScrolling = false
    private var isPinchingTerminalZoom = false
    private var isNativeHostScrollContainerEnabled = false
    private var pinchReferenceScale: CGFloat = 1
    private let zoomIndicatorView = TerminalZoomIndicatorView()
    private var zoomIndicatorHideWorkItem: DispatchWorkItem?
    private var nativeSelectionSnapshot = TerminalNativeTextSnapshot.empty
    private var nativeSelectedRange: NSRange?
    private weak var nativeTextInputDelegate: UITextInputDelegate?
    private lazy var nativeSelectionTokenizer = UITextInputStringTokenizer(textInput: self)
    private var nativeSelectionAffinity: UITextStorageDirection = .forward
    private var nativeSelectionInteractionActive = false
    private var prefersNativeSelectionFirstResponder = false
    private var shouldRestoreIMEProxyFocusAfterNativeSelection = false
    private var nativeTextInteraction: UITextInteraction?
    private var nativeFindInteraction: UIFindInteraction?
    @available(iOS 16.0, *)
    private var nativeFindSession: GhosttyNativeFindSession?
    private var ghosttyFindReportedTotal: Int?
    private var ghosttyFindReportedSelectedIndex: Int?
    private let nativeFindDocumentIdentifier = "terminal"
    private let nativeFindOverlay = TerminalNativeFindOverlayView()
    private var nativeFindDecorations: [TerminalNativeFindDecoration] = [] {
        didSet {
            updateNativeFindOverlay()
        }
    }
    private var touchSelectionAnchor: TerminalGridPoint?
    private var touchSelectionSeed: TerminalGridSelection?
    private var touchSelection: TerminalGridSelection? {
        didSet {
            updateTouchSelectionOverlay()
        }
    }
    private let touchSelectionOverlay = TerminalTouchSelectionOverlayView()
    private let touchSelectionLoupe = TerminalTouchSelectionLoupeView()
    private lazy var selectionRecognizer: UILongPressGestureRecognizer = {
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

    private lazy var scrollRecognizer: UIPanGestureRecognizer = {
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
    private lazy var pinchRecognizer: UIPinchGestureRecognizer = {
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
    private var hasHardwareKeyboardAttached = false
    private var allowIMEProxyProgrammaticResign = false
    private var suppressUnexpectedIMEProxyResignUntil = 0.0

    // MARK: - Text Input (for spacebar cursor control)
    private var textInputModel = TerminalTextInputModel()
    var pendingSystemTextInputHardwareKeys: [UIKey] = []
    private var suppressIMEProxyCallbacks = false
    private var renderedIMEPreeditText: String?
    private lazy var imeProxyTextView: TerminalIMEProxyTextView = {
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
    private var hardwarePressesSentToGhostty: Set<UInt16> = []
    private var fallbackHardwarePressKeys: [UInt16: Ghostty.Input.Key] = [:]
    private var fallbackHardwarePressModifiers: [UInt16: UIKeyModifierFlags] = [:]
    private var systemTextInputPresses: Set<UInt16> = []

    struct HardwarePressResult {
        var forwardedToSystem: Set<UIPress> = []
        var didHandleGhosttyInput = false
    }

    // MARK: - Rendering Components

    private let renderingSetup = GhosttyRenderingSetup()
    private let surfaceDisplayRuntime = TerminalIOSSurfaceDisplayRuntime()

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

    private func scheduleCustomIORedraw() {
        guard useCustomIO else { return }
        guard !customIORedrawScheduled else { return }
        customIORedrawScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.customIORedrawScheduled = false
            guard !self.isShuttingDown, !self.isPaused else { return }
            guard let surface = self.surface?.unsafeCValue else { return }
            guard self.bounds.width > 0 && self.bounds.height > 0 else { return }

            self.updateContentScaleIfNeeded()
            self.configureIOSurfaceLayers(size: self.bounds.size)
            self.surfaceDisplayRuntime.redraw(surface: surface)
            self.markIOSurfaceLayersForDisplay()
        }
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
        zoomIndicatorView.isHidden = true
        zoomIndicatorView.alpha = 0
        zoomIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomIndicatorView)
        NSLayoutConstraint.activate([
            zoomIndicatorView.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomIndicatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomIndicatorView.widthAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumWidth),
            zoomIndicatorView.heightAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumHeight)
        ])
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
        stopMomentumScrolling()
        zoomIndicatorHideWorkItem?.cancel()
        zoomIndicatorHideWorkItem = nil

        lifecycleObservers.invalidateAll()

        // Clear all callbacks first to prevent any further interactions
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

        surface?.invalidateCallbackContext()

        // Stop rendering/input callbacks and mark the surface as not visible.
        if let cSurface = surface?.unsafeCValue {
            ghostty_surface_set_focus(cSurface, false)
            ghostty_surface_set_occlusion(cSurface, false)
        }

        surfaceRegistration.unregister()

        // Detach immediately, then release native resources off the UI thread.
        surface?.free()
        surface = nil
    }

    /// Pause rendering and input without destroying the surface.
    func pauseRendering() {
        guard !isShuttingDown else { return }
        isPaused = true

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, false)
            ghostty_surface_set_occlusion(surface, false)
        }
    }

    /// Resume rendering/input after a pause.
    func resumeRendering() {
        guard !isShuttingDown else { return }
        isPaused = false

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, true)
        }

        sizeDidChange(bounds.size)
        requestRender()
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

    private func textInputGridMetrics() -> (cols: Int, rows: Int, cellSize: CGSize, length: Int) {
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
        if allowIMEProxyProgrammaticResign || !isTextInputSessionEligible {
            return true
        }
        return !shouldSuppressUnexpectedIMEProxyResign
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
        applyTerminalTextInputEffects(effects)
        if snapshot.markedRange == nil {
            syncIMEPreedit(nil)
        }
    }

    private var hasLocalTextInputSession: Bool {
        textInputModel.documentLength > 0 || textInputModel.hasActiveIMEComposition
    }

    private func setIMEProxySelection(_ range: NSRange) {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.selectedRange = range
        }
        syncTextInputModelFromIMEProxy()
    }

    private func moveIMEProxyCursorLeft() {
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

    private func moveIMEProxyCursorRight() {
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

    private func moveIMEProxyCursorToStart() {
        setIMEProxySelection(NSRange(location: 0, length: 0))
    }

    private func moveIMEProxyCursorToEnd() {
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
            applyTerminalTextInputEffects([.sendSpecialKey(.backspace)])
            return
        }
        syncTextInputModelFromIMEProxy()
    }

    func imeProxyFocusDidChange(isFocused: Bool) {
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, isFocused)
        }
        if isFocused {
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
        } else {
            imeProxyTextView.endDictationSession(commit: true)
            invalidateLocalTextInputSession()
            stopKeyRepeat()
        }
    }

    private func suppressUnexpectedIMEProxyResign() {
        suppressUnexpectedIMEProxyResignUntil = Date.timeIntervalSinceReferenceDate + 0.35
    }

    private var shouldSuppressUnexpectedIMEProxyResign: Bool {
        Date.timeIntervalSinceReferenceDate < suppressUnexpectedIMEProxyResignUntil
    }

    func imeProxyCaretRect(for position: UITextPosition) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: position)
        return textInputCaretRect(for: index)
    }

    func imeProxyFirstRect(for range: UITextRange) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        return textInputCaretRect(for: index)
    }

    private func invalidateLocalTextInputSession() {
        resetIMEProxyState()
        let effects = textInputModel.invalidateSession()
        applyTerminalTextInputEffects(effects)
        syncIMEPreedit(nil)
    }

    private func applyTerminalTextInputEffects(_ effects: [TerminalTextInputModel.Effect]) {
        for effect in effects {
            switch effect {
            case .willTextChange:
                nativeTextInputDelegate?.textWillChange(self)
            case .willSelectionChange:
                nativeTextInputDelegate?.selectionWillChange(self)
            case .didTextChange:
                nativeTextInputDelegate?.textDidChange(self)
            case .didSelectionChange:
                nativeTextInputDelegate?.selectionDidChange(self)
            case let .syncPreedit(text):
                syncIMEPreedit(text)
            case let .sendText(text):
                sendTerminalInputText(text)
            case let .sendBackspaces(count):
                for _ in 0..<count {
                    sendKeyPress(.backspace)
                }
            case let .moveCursor(delta):
                let key: Ghostty.Input.Key = delta < 0 ? .arrowLeft : .arrowRight
                for _ in 0..<abs(delta) {
                    sendKeyPress(key)
                }
            case let .sendSpecialKey(key):
                switch key {
                case .enter:
                    sendKeyPress(.enter)
                case .tab:
                    sendKeyPress(.tab)
                case .backspace:
                    sendKeyPress(.backspace)
                }
            }
        }
    }

    private func textInputCaretRect(for index: Int) -> CGRect {
        guard let surface = surface?.unsafeCValue else {
            let metrics = textInputGridMetrics()
            return CGRect(x: 0, y: 0, width: metrics.cellSize.width, height: metrics.cellSize.height)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let cellWidth = max(cellSize.width, CGFloat(max(width, 1)))
        let cellHeight = max(cellSize.height, CGFloat(max(height, 1)))
        let currentCharacterIndex = textInputModel.committedCursorCharacterIndex
        let targetCharacterIndex = textInputModel.committedCharacterIndex(forDocumentOffset: clampTextInputIndex(index))
        let delta = targetCharacterIndex - currentCharacterIndex

        return CGRect(
            x: CGFloat(x) + CGFloat(delta) * cellWidth,
            y: CGFloat(y),
            width: max(CGFloat(width), cellWidth),
            height: max(CGFloat(height), cellHeight)
        )
    }

    // MARK: - UIView Overrides

    override var canBecomeFirstResponder: Bool {
        return true
    }

    private var isTextInputSessionEligible: Bool {
        guard !isShuttingDown else { return false }
        guard window != nil, !isHidden, alpha > 0.01 else { return false }
        if let activationState = window?.windowScene?.activationState {
            return activationState == .foregroundActive
        }
        return presentationEnvironment.isApplicationActive()
    }

    var acceptsTerminalInput = true
    private var keyboardFocusPolicy = TerminalKeyboardFocusPolicy()
    private var suppressDirectTouchKeyboardFocusUntil = Date.distantPast
    var onKeyboardBrowseModeChange: ((Bool) -> Void)?
    var onFindNavigatorVisibilityChange: ((Bool) -> Void)?
    private var findNavigatorLifecycle = TerminalFindNavigatorLifecycle()

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

    private var isFindNavigatorActive: Bool {
        guard #available(iOS 16.0, *) else { return false }
        return findNavigatorLifecycle.isActive
            || nativeFindInteraction?.isFindNavigatorVisible == true
    }

    private var canRouteTerminalInput: Bool {
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
    private func exitNativeSelectionTextInputContextForTerminalInput() -> Bool {
        guard isNativeSelectionTextInputContext else { return true }
        guard !isFindNavigatorActive else { return false }

        nativeSelectionInteractionActive = false
        return requestKeyboardFocus(for: .explicitUserRequest)
    }

    private func clearNativeSelectionStateForTerminalInput() {
        guard usesNativeTouchSelection else { return }
        nativeSelectionInteractionActive = false
        prefersNativeSelectionFirstResponder = false
        shouldRestoreIMEProxyFocusAfterNativeSelection = false
        if nativeSelectedRange != nil {
            setNativeSelectedRange(nil)
        }
    }

    private func shouldRedirectNativeSelectionPressesToTerminalInput(_ presses: Set<UIPress>) -> Bool {
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

    private func notifyFindNavigatorVisibilityChange() {
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
            if let surface = surface?.unsafeCValue {
                ghostty_surface_set_focus(surface, result || super.isFirstResponder)
            }
            return result
        }
        return imeProxyTextView.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        guard imeProxyTextView.isFirstResponder || super.isFirstResponder else { return true }
        if imeProxyTextView.isFirstResponder,
           isTextInputSessionEligible,
           shouldSuppressUnexpectedIMEProxyResign {
            imeProxyFocusDidChange(isFocused: true)
            return false
        }
        let proxyResult: Bool
        if imeProxyTextView.isFirstResponder {
            let previous = allowIMEProxyProgrammaticResign
            allowIMEProxyProgrammaticResign = true
            defer { allowIMEProxyProgrammaticResign = previous }
            proxyResult = imeProxyTextView.resignFirstResponder()
        } else {
            proxyResult = true
        }
        let ownResult = super.isFirstResponder ? super.resignFirstResponder() : true
        if (proxyResult && ownResult) || !isTextInputSessionEligible {
            if let surface = surface?.unsafeCValue {
                ghostty_surface_set_focus(surface, false)
            }
            stopKeyRepeat()
            pendingSystemTextInputHardwareKeys.removeAll()
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
        bringSubviewToFront(zoomIndicatorView)

        guard !isShuttingDown else { return }

        // Tell Ghostty the new size after the view has laid out.
        sizeDidChange(bounds.size)

    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        let isVisible = (window != nil)
        isPaused = !isVisible
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, isVisible)
        }

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
        ghostty_surface_set_color_scheme(surface, scheme)
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

    private func markHardwareKeyboardDetectedFromKeyPress() {
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
           touchSelection != nil,
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

    /// Display link for momentum animation
    private var momentumDisplayLink: CADisplayLink?
    private var momentumScrollState = TerminalMomentumScrollState()

    func setNativeHostScrollContainerEnabled(_ enabled: Bool) {
        isNativeHostScrollContainerEnabled = enabled
        if enabled {
            stopMomentumScrolling()
        }
    }

    func prepareForNativeHostScroll() {
        isScrolling = false
        stopMomentumScrolling()
    }

    func currentScrollOwner() -> TerminalScrollOwner {
        TerminalScrollRoutingPolicy.owner(for: TerminalScrollContext(
            remoteScrollOwnerActive: surface?.mouseCaptured ?? false,
            remoteAlternateScreenActive: surface?.inAlternateScreen ?? false,
            hasHostScrollableRows: hasHostScrollableRows,
            isSelecting: isTerminalSelectionActive,
            isPinching: isPinchingTerminalZoom
        ))
    }

    private var hasHostScrollableRows: Bool {
        guard let scrollbar else { return false }
        return scrollbar.total > scrollbar.len
    }

    @objc private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        guard let surface = surface else { return }
        if isNativeHostScrollContainerEnabled,
           currentScrollOwner() == .hostScrollback {
            return
        }
        if isSelecting { return }
        if isPinchingTerminalZoom { return }
        if touchSelection != nil {
            if recognizer.state == .began,
               !isPointOnTouchSelectionHandle(recognizer.location(in: self)) {
                clearTouchSelection()
            }
            return
        }

        let translation = recognizer.translation(in: self)
        let location = recognizer.location(in: self)

        switch recognizer.state {
        case .began:
            isScrolling = true
            stopMomentumScrolling()
        case .changed:
            // Update mouse position so TUI apps receive wheel events with coordinates.
            let pos = ghosttyPoint(location)
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            // Send scroll delta directly with increased multiplier for snappy feel
            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: Double(translation.x) * TerminalScrollGesturePresentation.scrollMultiplier,
                y: Double(translation.y) * TerminalScrollGesturePresentation.scrollMultiplier,
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .none)
            )
            surface.sendMouseScroll(scrollEvent)
            requestRender()

            // Reset translation so we get delta on next call
            recognizer.setTranslation(.zero, in: self)
        case .ended:
            isScrolling = false
            // Get velocity for momentum scrolling
            let velocity = recognizer.velocity(in: self)
            startMomentumScrolling(velocity: velocity)
        case .cancelled, .failed:
            isScrolling = false
            stopMomentumScrolling()
        default:
            break
        }
    }

    private func startMomentumScrolling(velocity: CGPoint) {
        guard momentumScrollState.start(gestureVelocity: velocity) else {
            sendMomentumEnd()
            return
        }

        momentumDisplayLink = CADisplayLink(target: self, selector: #selector(momentumScrollTick))
        momentumDisplayLink?.add(to: .main, forMode: .common)
    }

    @objc private func momentumScrollTick() {
        guard let surface = surface else {
            stopMomentumScrolling()
            return
        }

        guard let scrollEvent = momentumScrollState.nextFrameEvent() else {
            stopMomentumScrolling()
            sendMomentumEnd()
            return
        }

        surface.sendMouseScroll(scrollEvent)
        requestRender()
    }

    private func stopMomentumScrolling() {
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        momentumScrollState.reset()
    }

    private func sendMomentumEnd() {
        guard let surface = surface else { return }
        let endEvent = Ghostty.Input.MouseScrollEvent(
            x: 0,
            y: 0,
            mods: Ghostty.Input.ScrollMods(precision: true, momentum: .ended)
        )
        surface.sendMouseScroll(endEvent)
        momentumScrollState.reset()
    }

    @objc private func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
        guard canHandlePinchZoom else {
            isPinchingTerminalZoom = false
            return
        }

        switch recognizer.state {
        case .began:
            isPinchingTerminalZoom = true
            pinchReferenceScale = recognizer.scale
            stopMomentumScrolling()
            showZoomIndicator()
        case .changed:
            guard isPinchingTerminalZoom else { return }
            let relativeScale = recognizer.scale / pinchReferenceScale
            if relativeScale >= CGFloat(TerminalZoomPresentation.pinchZoomInThreshold) {
                if let result = onZoomAction?(.zoomIn) {
                    showZoomIndicator(fontSize: result.effectiveFontSize)
                }
                pinchReferenceScale = recognizer.scale
            } else if relativeScale <= CGFloat(TerminalZoomPresentation.pinchZoomOutThreshold) {
                if let result = onZoomAction?(.zoomOut) {
                    showZoomIndicator(fontSize: result.effectiveFontSize)
                }
                pinchReferenceScale = recognizer.scale
            }
        case .ended, .cancelled, .failed:
            isPinchingTerminalZoom = false
            pinchReferenceScale = 1
            scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorGestureEndHideDelay)
        default:
            break
        }
    }

    private func showZoomIndicator() {
        showZoomIndicator(fontSize: surfacePresentationOverrides.resolvedFontSize())
    }

    private func showZoomIndicator(fontSize: Double) {
        zoomIndicatorView.update(fontSize: fontSize)
        updateZoomIndicatorLayout()
        bringSubviewToFront(zoomIndicatorView)

        zoomIndicatorHideWorkItem?.cancel()
        zoomIndicatorView.isHidden = false
        UIView.animate(withDuration: TerminalZoomPresentation.indicatorFadeInDuration) {
            self.zoomIndicatorView.alpha = 1
        }
        scheduleZoomIndicatorHide(after: TerminalZoomPresentation.indicatorHideDelay)
    }

    private func scheduleZoomIndicatorHide(after delay: TimeInterval) {
        zoomIndicatorHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: TerminalZoomPresentation.indicatorFadeOutDuration, animations: {
                self.zoomIndicatorView.alpha = 0
            }, completion: { _ in
                self.zoomIndicatorView.isHidden = true
            })
        }
        zoomIndicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func updateZoomIndicatorLayout() {
        setNeedsLayout()
        layoutIfNeeded()
        zoomIndicatorView.layoutIfNeeded()
    }

    private var canHandlePinchZoom: Bool {
        if usesNativeTouchSelection, nativeSelectionInteractionActive || nativeSelectedRange != nil {
            return false
        }
        if usesAppOwnedTouchSelection, touchSelection != nil {
            return false
        }
        return true
    }

    private var isTerminalSelectionActive: Bool {
        isSelecting
            || touchSelection != nil
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

    private func refreshNativeSelectionSnapshot(resetSelection: Bool = false) {
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
        guard let surface = surface?.unsafeCValue,
              let metrics = selectionGridMetrics() else {
            return .empty
        }

        let rows = (0..<metrics.rows).map { readNativeSelectionLine(surface: surface, row: $0, columns: metrics.cols) }
        return TerminalNativeTextSnapshot(lines: rows, cellSize: metrics.cellSize, columns: metrics.cols)
    }

    private func readNativeSelectionLine(surface: ghostty_surface_t, row: Int, columns: Int) -> String {
        GhosttyTerminalTextReader.readViewportLine(
            surface: surface,
            row: row,
            columns: columns
        )
    }

    private func setNativeSelectedRange(_ range: NSRange?) {
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
        findNavigatorLifecycle.begin(restoreTerminalFocus: restoreTerminalFocus)
        notifyFindNavigatorVisibilityChange()
        stopKeyRepeat()

        if !super.isFirstResponder {
            _ = super.becomeFirstResponder()
        }

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, false)
        }
    }

    private func endFindNavigatorLifecycle() -> Bool {
        let shouldRestoreTerminalFocus = findNavigatorLifecycle.end()
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
            nativeFindSession?.applyExternalQuery(selectionText)
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
    private func performGhosttyFindQuery(
        _ query: String,
        keepNavigatorVisibleOnSearchEnd: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        let action = "search:\(query)"
        if keepNavigatorVisibleOnSearchEnd {
            findNavigatorLifecycle.suppressNextGhosttySearchEnd()
        }
        guard surface.perform(action: action) else {
            if keepNavigatorVisibleOnSearchEnd {
                findNavigatorLifecycle.cancelSuppressedGhosttySearchEnd()
            }
            return false
        }
        if query.isEmpty {
            nativeFindSession?.resetReportedResults()
            nativeFindInteraction?.updateResultCount()
        }
        return true
    }

    @MainActor
    private func navigateGhosttyFind(_ direction: UITextStorageDirection) {
        guard let surface else { return }
        let action = direction == .backward ? "navigate_search:previous" : "navigate_search:next"
        _ = surface.perform(action: action)
    }

    @MainActor
    private func endGhosttyFindSearchForNavigatorDismissal() {
        guard let surface else { return }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        findNavigatorLifecycle.suppressNextGhosttySearchEnd()
        if !surface.perform(action: "end_search") {
            findNavigatorLifecycle.cancelSuppressedGhosttySearchEnd()
        }
    }

    @MainActor
    private func invalidateGhosttyFindWithoutClosingNavigator() {
        performGhosttyFindQuery("", keepNavigatorVisibleOnSearchEnd: true)
    }

    @MainActor
    private func applyStoredGhosttyFindResultsToNativeSession() {
        guard #available(iOS 16.0, *), let nativeFindSession else { return }
        if nativeFindSession.updateReportedResults(
            total: ghosttyFindReportedTotal,
            highlightedIndex: ghosttyFindReportedSelectedIndex
        ) {
            nativeFindInteraction?.updateResultCount()
        }
    }

    func handleGhosttySearchStarted(needle: String) {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        if #available(iOS 16.0, *) {
            nativeFindInteraction?.searchText = needle
            nativeFindSession?.applyExternalQuery(needle)
            applyStoredGhosttyFindResultsToNativeSession()
            if nativeFindInteraction?.isFindNavigatorVisible != true {
                beginFindNavigatorPresentation(restoreTerminalFocus: imeProxyTextView.isFirstResponder)
                nativeFindInteraction?.presentFindNavigator(showingReplace: false)
            }
        }
    }

    func handleGhosttySearchEnded() {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        if #available(iOS 16.0, *) {
            nativeFindSession?.resetReportedResults()
            nativeFindInteraction?.updateResultCount()
            if findNavigatorLifecycle.consumeSuppressedGhosttySearchEnd() {
                return
            } else if nativeFindInteraction?.isFindNavigatorVisible == true {
                nativeFindInteraction?.dismissFindNavigator()
            } else if findNavigatorLifecycle.isActive {
                _ = endFindNavigatorLifecycle()
                notifyFindNavigatorVisibilityChange()
            }
        }
    }

    func handleGhosttySearchTotalChange(_ total: Int?) {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedTotal = total
        if #available(iOS 16.0, *) {
            applyStoredGhosttyFindResultsToNativeSession()
        }
    }

    func handleGhosttySearchSelectedChange(_ selected: Int?) {
        guard usesNativeTouchSelection else { return }
        ghosttyFindReportedSelectedIndex = selected
        if #available(iOS 16.0, *) {
            applyStoredGhosttyFindResultsToNativeSession()
        }
    }

    private var usesNativeTouchSelection: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var usesAppOwnedTouchSelection: Bool {
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
              let touchSelection,
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

    private func isPointOnTouchSelectionHandle(_ point: CGPoint) -> Bool {
        guard usesAppOwnedTouchSelection, touchSelection != nil else { return false }

        let startHandlePoint = touchSelectionOverlay.convert(point, from: self)
        return touchSelectionOverlay.startHandle.frame.insetBy(dx: -22, dy: -22).contains(startHandlePoint) ||
            touchSelectionOverlay.endHandle.frame.insetBy(dx: -22, dy: -22).contains(startHandlePoint)
    }

    private func dismissEditMenuIfNeeded() {
        editMenuInteraction?.dismissMenu()
    }

    private func clearTouchSelection() {
        touchSelectionAnchor = nil
        touchSelectionSeed = nil
        touchSelection = nil
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
        if let wordSelection = quickLookWordSelection(at: location) {
            let normalized = wordSelection.normalized
            touchSelectionAnchor = nil
            touchSelectionSeed = normalized
            touchSelection = normalized
            isSelecting = true
            return
        }

        guard let point = touchSelectionLayout()?.gridPoint(for: location) else { return }
        touchSelectionAnchor = point
        touchSelectionSeed = nil
        touchSelection = TerminalGridSelection(start: point, end: point)
        isSelecting = true
    }

    private func updateTouchSelection(at location: CGPoint) {
        guard let point = touchSelectionLayout()?.gridPoint(for: location) else { return }

        if touchSelectionAnchor == nil, let seed = touchSelectionSeed?.normalized {
            if point < seed.start {
                touchSelectionAnchor = seed.end
            } else if point > seed.end {
                touchSelectionAnchor = seed.start
            } else {
                touchSelection = seed
                return
            }
        }

        guard let anchor = touchSelectionAnchor else { return }
        touchSelection = TerminalGridSelection(start: anchor, end: point).normalized
    }

    private func updateTouchSelectionHandle(_ kind: TerminalTouchSelectionHandleKind, at location: CGPoint) {
        guard var selection = touchSelection?.normalized,
              let point = touchSelectionLayout()?.gridPoint(for: location) else { return }

        switch kind {
        case .start:
            selection.start = point
        case .end:
            selection.end = point
        }

        touchSelection = selection.normalized
    }

    private func finishTouchSelection() {
        isSelecting = false
        touchSelectionLoupe.hideLoupe()
        guard let touchSelection,
              let menuPoint = touchSelectionLayout()?.menuPoint(for: touchSelection) else { return }
        showEditMenu(at: menuPoint)
    }

    private func currentSelectionText() -> String? {
        if let nativeSelectionText = selectedNativeSelectionText() {
            return nativeSelectionText
        }
        if let touchSelectionText = touchSelectionText() {
            return touchSelectionText
        }
        return ghosttySelectionText()
    }

    private func touchSelectionText() -> String? {
        guard let touchSelection,
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
    private func nativeSelectionMenuElements() -> [UIMenuElement] {
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
        touchSelection = TerminalGridSelection(
            start: TerminalGridPoint(row: 0, column: 0),
            end: TerminalGridPoint(row: metrics.rows - 1, column: metrics.cols - 1)
        )
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
        guard usesAppOwnedTouchSelection, touchSelection != nil else { return }

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
        let hasGhosttySelection: Bool
        if let surface = surface?.unsafeCValue {
            hasGhosttySelection = ghostty_surface_has_selection(surface)
        } else {
            hasGhosttySelection = false
        }
        guard touchSelection != nil || hasGhosttySelection else {
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
            if touchSelection != nil {
                return true
            }
            guard let cSurface = surface?.unsafeCValue else { return false }
            return ghostty_surface_has_selection(cSurface)
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

    private func clearSelectionAfterPaste() {
        if usesNativeTouchSelection, nativeSelectedRange != nil {
            setNativeSelectedRange(nil)
            prefersNativeSelectionFirstResponder = false
        }
        if usesAppOwnedTouchSelection, touchSelection != nil {
            clearTouchSelection()
        }
    }

    // MARK: - Software Keyboard (UIKeyInput)

    // MARK: - Keyboard Input (Hardware Keyboard)

    override var keyCommands: [UIKeyCommand]? {
        // Keep keyCommands nil; handle command shortcuts in pressesBegan.
        return nil
    }

    func handleIMEProxyNavigationCommand(_ command: UIKeyCommand) {
        guard canRouteTerminalInput else { return }
        guard let input = command.input,
              let key = terminalKey(forKeyCommandInput: input) else { return }
        if case .escape = key {
            suppressUnexpectedIMEProxyResign()
        }
        let mods = Ghostty.Input.Mods(uiKeyModifiers: command.modifierFlags)
        sendToolbarKey(key, accumulatedMods: mods)
    }

    private func handlePasteShortcut(_ key: UIKey) -> Bool {
        let input = key.charactersIgnoringModifiers.lowercased()
        guard input == "v" else { return false }

        if key.modifierFlags.contains(.command) {
            performPasteAction(requestRenderAfterward: true)
            return true
        }

        if key.modifierFlags.contains(.control), interceptRichPasteIfNeeded() {
            return true
        }

        return false
    }

    @discardableResult
    private func interceptRichPasteIfNeeded() -> Bool {
        richPasteInterceptor?(self) == true
    }

    private func performPasteAction(requestRenderAfterward: Bool = false) {
        invalidateLocalTextInputSession()
        if interceptRichPasteIfNeeded() {
            clearSelectionAfterPaste()
            if requestRenderAfterward {
                requestRender()
            }
            return
        }

        pasteTextFromClipboard()
        clearSelectionAfterPaste()
        if requestRenderAfterward {
            requestRender()
        }
    }

    private func handleCommandShortcut(_ key: UIKey) -> Bool {
        guard key.modifierFlags.contains(.command) else { return false }
        let input = key.charactersIgnoringModifiers.lowercased()
        switch input {
        case "c":
            if canPerformAction(#selector(copy(_:)), withSender: nil) {
                copy(nil)
            }
            return true
        case "f":
            if canPerformAction(#selector(find(_:)), withSender: nil) {
                find(nil)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func shouldRepeatHardwareKey(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardDeleteOrBackspace,
             .keyboardDeleteForward,
             .keyboardUpArrow,
             .keyboardDownArrow,
             .keyboardLeftArrow,
             .keyboardRightArrow,
             .keyboardHome,
             .keyboardEnd,
             .keyboardPageUp,
             .keyboardPageDown:
            return true
        default:
            return false
        }
    }

    private func fallbackHardwareKey(for key: UIKey) -> Ghostty.Input.Key? {
        switch key.keyCode {
        case .keyboardLeftShift:
            return .shiftLeft
        case .keyboardRightShift:
            return .shiftRight
        case .keyboardCapsLock:
            return .capsLock
        case .keyboardReturnOrEnter:
            return .enter
        case .keyboardDeleteOrBackspace:
            return .backspace
        case .keyboardDeleteForward:
            return .delete
        case .keyboardTab:
            return .tab
        case .keyboardEscape:
            return .escape
        case .keyboardUpArrow:
            return .arrowUp
        case .keyboardDownArrow:
            return .arrowDown
        case .keyboardLeftArrow:
            return .arrowLeft
        case .keyboardRightArrow:
            return .arrowRight
        case .keyboardHome:
            return .home
        case .keyboardEnd:
            return .end
        case .keyboardPageUp:
            return .pageUp
        case .keyboardPageDown:
            return .pageDown
        default:
            break
        }

        let candidates = [key.charactersIgnoringModifiers, key.characters]
        for candidate in candidates where !candidate.isEmpty {
            switch candidate {
            case "UIKeyInputEscape":
                return .escape
            case "UIKeyInputUpArrow":
                return .arrowUp
            case "UIKeyInputDownArrow":
                return .arrowDown
            case "UIKeyInputLeftArrow":
                return .arrowLeft
            case "UIKeyInputRightArrow":
                return .arrowRight
            case "UIKeyInputHome":
                return .home
            case "UIKeyInputEnd":
                return .end
            case "UIKeyInputPageUp":
                return .pageUp
            case "UIKeyInputPageDown":
                return .pageDown
            case UIKeyCommand.inputEscape:
                return .escape
            case UIKeyCommand.inputUpArrow:
                return .arrowUp
            case UIKeyCommand.inputDownArrow:
                return .arrowDown
            case UIKeyCommand.inputLeftArrow:
                return .arrowLeft
            case UIKeyCommand.inputRightArrow:
                return .arrowRight
            case UIKeyCommand.inputHome:
                return .home
            case UIKeyCommand.inputEnd:
                return .end
            case UIKeyCommand.inputPageUp:
                return .pageUp
            case UIKeyCommand.inputPageDown:
                return .pageDown
            default:
                continue
            }
        }

        return nil
    }

    private func terminalKey(forKeyCommandInput input: String) -> TerminalKey? {
        switch input {
        case UIKeyCommand.inputEscape:
            return .escape
        case UIKeyCommand.inputUpArrow:
            return .arrowUp
        case UIKeyCommand.inputDownArrow:
            return .arrowDown
        case UIKeyCommand.inputLeftArrow:
            return .arrowLeft
        case UIKeyCommand.inputRightArrow:
            return .arrowRight
        case UIKeyCommand.inputHome:
            return .home
        case UIKeyCommand.inputEnd:
            return .end
        case UIKeyCommand.inputPageUp:
            return .pageUp
        case UIKeyCommand.inputPageDown:
            return .pageDown
        default:
            return nil
        }
    }

    private func startKeyRepeat(for key: UIKey) {
        guard shouldRepeatHardwareKey(key) else { return }
        let blockedModifiers: UIKeyModifierFlags = [.command, .control, .alternate]
        guard key.modifierFlags.intersection(blockedModifiers).isEmpty else { return }
        stopKeyRepeat()
        repeatingHardwareKey = key
        repeatingFallbackKey = fallbackHardwareKey(for: key)
        repeatingFallbackModifiers = key.modifierFlags
        repeatingKeyCode = UInt16(key.keyCode.rawValue)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  let cSurface = self.surface?.unsafeCValue else { return }
            guard self.canRouteTerminalInput else {
                self.stopKeyRepeat()
                return
            }
            if let repeatKey = self.repeatingHardwareKey,
               self.sendDirectHardwareKeyEvent(
                   repeatKey,
                   action: GHOSTTY_ACTION_REPEAT,
                   surface: cSurface
               ) {
                self.requestRender()
                return
            }
            if let fallbackKey = self.repeatingFallbackKey,
               let surface = self.surface {
                surface.sendKeyEvent(
                    self.fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .repeat,
                        modifiers: self.repeatingFallbackModifiers
                    )
                )
            }
            self.requestRender()
        }
        keyRepeatTimer = timer
        timer.resume()
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.cancel()
        keyRepeatTimer = nil
        repeatingHardwareKey = nil
        repeatingFallbackKey = nil
        repeatingFallbackModifiers = []
        repeatingKeyCode = nil
    }

    private func ghosttyInputAction(_ action: ghostty_input_action_e) -> Ghostty.Input.Action {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            return .press
        case GHOSTTY_ACTION_RELEASE:
            return .release
        case GHOSTTY_ACTION_REPEAT:
            return .repeat
        default:
            return .press
        }
    }

    private func fallbackHardwareEvent(
        key: Ghostty.Input.Key,
        action: Ghostty.Input.Action,
        modifiers: UIKeyModifierFlags
    ) -> Ghostty.Input.KeyEvent {
        let mods = Ghostty.Input.Mods(uiKeyModifiers: modifiers)
        let consumedMods = Ghostty.Input.Mods(
            uiKeyModifiers: modifiers.subtracting([.control, .command])
        )
        return .init(
            key: key,
            action: action,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: consumedMods,
            unshiftedCodepoint: 0
        )
    }

    private func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e,
        surface cSurface: ghostty_surface_t
    ) -> Bool {
        guard let event = Ghostty.Input.KeyEvent(uiKey: key, action: ghosttyInputAction(action))
        else {
            return false
        }
        return event.withCValue { cEvent in
            ghostty_surface_key(cSurface, cEvent)
        }
    }

    private func shouldRoutePressToSystemTextInput(_ key: UIKey) -> Bool {
        let keyProducesText = !(key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty)
        return TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
            hasControlModifier: key.modifierFlags.contains(.control),
            hasAlternateModifier: key.modifierFlags.contains(.alternate),
            hasCommandModifier: key.modifierFlags.contains(.command),
            hasActiveIMEComposition: textInputModel.hasActiveIMEComposition,
            isSystemTextInputToggleKey: key.keyCode == .keyboardCapsLock,
            hasTerminalFallbackKey: fallbackHardwareKey(for: key) != nil,
            keyProducesText: keyProducesText
        )
    }

    func processHardwarePressesBegan(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard let surface = surface, let cSurface = surface.unsafeCValue else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
        guard canRouteTerminalInput else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }

        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            markHardwareKeyboardDetectedFromKeyPress()
            if handlePasteShortcut(key) {
                result.didHandleGhosttyInput = true
                continue
            }
            if handleCommandShortcut(key) { continue }
            if key.modifierFlags.contains(.command) {
                result.forwardedToSystem.insert(press)
                continue
            }
            if isNativeSelectionTextInputContext {
                clearNativeSelectionStateForTerminalInput()
            }
            if textInputModel.hasActiveIMEComposition, key.keyCode == .keyboardEscape {
                invalidateLocalTextInputSession()
                result.didHandleGhosttyInput = true
                continue
            }
            if shouldRoutePressToSystemTextInput(key) {
                let keyCode = UInt16(key.keyCode.rawValue)
                let keyProducesText = !(key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty)
                systemTextInputPresses.insert(keyCode)
                if TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                    keyProducesText: keyProducesText,
                    hasControlModifier: key.modifierFlags.contains(.control),
                    hasAlternateModifier: key.modifierFlags.contains(.alternate),
                    hasCommandModifier: key.modifierFlags.contains(.command),
                    hasActiveIMEComposition: textInputModel.hasActiveIMEComposition,
                    isSystemTextInputToggleKey: key.keyCode == .keyboardCapsLock
                ) {
                    pendingSystemTextInputHardwareKeys.append(key)
                }
                result.forwardedToSystem.insert(press)
                continue
            }

            let keyCode = UInt16(key.keyCode.rawValue)
            if hasLocalTextInputSession {
                invalidateLocalTextInputSession()
            }
            if sendDirectHardwareKeyEvent(key, action: GHOSTTY_ACTION_PRESS, surface: cSurface) {
                hardwarePressesSentToGhostty.insert(keyCode)
                fallbackHardwarePressKeys.removeValue(forKey: keyCode)
                fallbackHardwarePressModifiers.removeValue(forKey: keyCode)
                startKeyRepeat(for: key)
                result.didHandleGhosttyInput = true
            } else if let fallbackKey = fallbackHardwareKey(for: key) {
                surface.sendKeyEvent(
                    fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .press,
                        modifiers: key.modifierFlags
                    )
                )
                hardwarePressesSentToGhostty.insert(keyCode)
                fallbackHardwarePressKeys[keyCode] = fallbackKey
                fallbackHardwarePressModifiers[keyCode] = key.modifierFlags
                startKeyRepeat(for: key)
                result.didHandleGhosttyInput = true
            }
        }

        return result
    }

    func processHardwarePressesEnded(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard let surface = surface, let cSurface = surface.unsafeCValue else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
        guard canRouteTerminalInput || !hardwarePressesSentToGhostty.isEmpty else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }

        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            let keyCode = UInt16(key.keyCode.rawValue)
            guard hardwarePressesSentToGhostty.contains(keyCode) else {
                fallbackHardwarePressKeys.removeValue(forKey: keyCode)
                fallbackHardwarePressModifiers.removeValue(forKey: keyCode)
                systemTextInputPresses.remove(keyCode)
                result.forwardedToSystem.insert(press)
                continue
            }
            hardwarePressesSentToGhostty.remove(keyCode)
            if repeatingKeyCode == keyCode {
                stopKeyRepeat()
            }
            let fallbackKey = fallbackHardwarePressKeys.removeValue(forKey: keyCode)
            let fallbackModifiers =
                fallbackHardwarePressModifiers.removeValue(forKey: keyCode) ?? key.modifierFlags

            if sendDirectHardwareKeyEvent(key, action: GHOSTTY_ACTION_RELEASE, surface: cSurface) {
                result.didHandleGhosttyInput = true
            } else if let fallbackKey {
                surface.sendKeyEvent(
                    fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .release,
                        modifiers: fallbackModifiers
                    )
                )
                result.didHandleGhosttyInput = true
            }
        }

        return result
    }

    func processHardwarePressesCancelled(_ presses: Set<UIPress>) {
        for press in presses {
            guard let key = press.key else { continue }
            let keyCode = UInt16(key.keyCode.rawValue)
            hardwarePressesSentToGhostty.remove(keyCode)
            fallbackHardwarePressKeys.removeValue(forKey: keyCode)
            fallbackHardwarePressModifiers.removeValue(forKey: keyCode)
            systemTextInputPresses.remove(keyCode)
        }
        stopKeyRepeat()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if shouldRedirectNativeSelectionPressesToTerminalInput(presses) {
            guard exitNativeSelectionTextInputContextForTerminalInput() else {
                super.pressesBegan(presses, with: event)
                return
            }
            imeProxyTextView.pressesBegan(presses, with: event)
            return
        }

        let pendingCount = pendingSystemTextInputHardwareKeys.count
        let result = processHardwarePressesBegan(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesBegan(result.forwardedToSystem, with: event)
            removeUnconsumedPendingSystemTextInputHardwareKeys(after: pendingCount)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let result = processHardwarePressesEnded(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesEnded(result.forwardedToSystem, with: event)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        processHardwarePressesCancelled(presses)
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

    private func sendTerminalInputText(_ text: String) {
        guard canRouteTerminalInput else { return }
        let normalized = text.precomposedStringWithCanonicalMapping
        guard normalized.count == 1, let character = normalized.first else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false)
            return
        }
        guard let mapping = ghosttyKeyMapping(for: character) else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false)
            return
        }

        var mods: Ghostty.Input.Mods = []
        if mapping.requiresShift {
            mods.insert(.shift)
        }
        sendModifiedKey(
            mapping.key,
            mods: mods,
            text: mapping.text,
            unshiftedCodepoint: mapping.codepoint,
            invalidateLocalSession: false
        )
    }

    private func sendRawTerminalInputText(_ text: String, invalidateLocalSession: Bool = true) {
        guard canRouteTerminalInput else { return }
        let terminalText = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        let data = Data(terminalText.utf8)
        guard !data.isEmpty else { return }

        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        if let writeCallback {
            writeCallback(data)
        } else {
            surface?.sendText(terminalText)
        }
        requestRender()
    }

    func handleIMEProxyInsertText(_ text: String, fromIMEComposition: Bool = false) -> Bool {
        guard canRouteTerminalInput else { return true }
        if isNativeSelectionTextInputContext {
            clearNativeSelectionStateForTerminalInput()
        }

        let normalized = text.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return true }
        if let key = terminalKey(forKeyCommandInput: normalized) {
            if case .escape = key {
                suppressUnexpectedIMEProxyResign()
            }
            sendToolbarKey(key)
            return true
        }
        if normalized.hasPrefix("UIKeyInput") {
            return true
        }

        if !fromIMEComposition,
           let key = consumePendingSystemTextInputHardwareKey(),
           sendInterpretedHardwareKeyText(normalized, for: key) {
            invalidateLocalTextInputSession()
            return true
        }

        let mods = keyboardToolbar?.consumeModifiers() ?? (ctrl: false, alt: false, command: false, shift: false)
        if mods.ctrl, normalized.compare("v", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
           interceptRichPasteIfNeeded() {
            invalidateLocalTextInputSession()
            return true
        }
        if normalized == "\n" || normalized == "\r" {
            commitIMEProxyMarkedTextIfNeeded()
            sendToolbarGhosttyKey(.enter, mods: imeProxyGhosttyModifiers(from: mods))
            return true
        }
        if normalized == "\t" {
            commitIMEProxyMarkedTextIfNeeded()
            sendToolbarGhosttyKey(.tab, mods: imeProxyGhosttyModifiers(from: mods))
            return true
        }

        guard mods.ctrl || mods.alt || mods.command else {
            // Plain text goes into the persistent local document; the text input
            // model reconciles it with the terminal by sending the delta.
            imeProxyTextView.insertCommittedText(normalized)
            return true
        }
        guard let firstChar = normalized.first else { return true }

        if let mapping = ghosttyKeyMapping(for: firstChar) {
            var ghostMods: Ghostty.Input.Mods = []
            if mods.ctrl { ghostMods.insert(.ctrl) }
            if mods.alt { ghostMods.insert(.alt) }
            if mods.command { ghostMods.insert(.super) }
            if mods.shift || mapping.requiresShift { ghostMods.insert(.shift) }
            let keyText = mods.ctrl || mods.alt || mods.command ? nil : mapping.text
            sendModifiedKey(mapping.key, mods: ghostMods, text: keyText, unshiftedCodepoint: mapping.codepoint)
        } else {
            if mods.command {
                return true
            }
            var data = Data()
            if mods.alt {
                data.append(0x1B)
            }
            if mods.ctrl, let controlChar = TerminalControlKey.controlCharacter(for: firstChar) {
                data.append(contentsOf: String(controlChar).utf8)
            } else {
                data.append(contentsOf: String(firstChar).utf8)
            }
            sendAnsiSequence(data)
        }

        if normalized.count > 1 {
            sendText(String(normalized.dropFirst()))
        }
        return true
    }

    private func imeProxyGhosttyModifiers(from mods: (ctrl: Bool, alt: Bool, command: Bool, shift: Bool)) -> Ghostty.Input.Mods {
        var ghostMods: Ghostty.Input.Mods = []
        if mods.ctrl { ghostMods.insert(.ctrl) }
        if mods.alt { ghostMods.insert(.alt) }
        if mods.command { ghostMods.insert(.super) }
        if mods.shift { ghostMods.insert(.shift) }
        return ghostMods
    }

    private func commitIMEProxyMarkedTextIfNeeded() {
        guard imeProxyMarkedRange() != nil else { return }
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.unmarkText()
        }
        syncTextInputModelFromIMEProxy()
    }

    private func sendKeyPress(_ key: Ghostty.Input.Key) {
        guard canRouteTerminalInput else { return }
        guard let surface = surface else { return }
        surface.sendKeyEvent(.init(key: key, action: .press))
        surface.sendKeyEvent(.init(key: key, action: .release))
        requestRender()
    }

    private func sendControlByte(_ value: UInt8) {
        guard canRouteTerminalInput else { return }
        invalidateLocalTextInputSession()
        let scalar = UnicodeScalar(value)
        sendText(String(Character(scalar)))
    }

    private func sendAnsiSequence(_ data: Data) {
        guard canRouteTerminalInput else { return }
        invalidateLocalTextInputSession()
        let text = String(decoding: data, as: UTF8.self)
        sendText(text)
    }

    private func shouldDisplayVisiblePreedit(for text: String) -> Bool {
        TerminalVisiblePreeditPolicy.shouldDisplay(
            text,
            inputModePrimaryLanguage: currentIMEPrimaryLanguage
        )
    }

    private var currentIMEPrimaryLanguage: String? {
        imeProxyTextView.textInputMode?.primaryLanguage ?? textInputMode?.primaryLanguage
    }

    private func syncIMEPreedit(_ text: String?) {
        let visibleText: String?
        if let text, !text.isEmpty {
            let normalized = text.precomposedStringWithCanonicalMapping
            visibleText = shouldDisplayVisiblePreedit(for: normalized) ? normalized : nil
        } else {
            visibleText = nil
        }

        guard visibleText != renderedIMEPreeditText else { return }
        renderedIMEPreeditText = visibleText

        guard let cSurface = surface?.unsafeCValue else { return }

        if let visibleText, !visibleText.isEmpty {
            let len = visibleText.utf8CString.count
            guard len > 0 else {
                ghostty_surface_preedit(cSurface, nil, 0)
                requestRender()
                return
            }
            visibleText.withCString { ptr in
                ghostty_surface_preedit(cSurface, ptr, UInt(len - 1))
            }
        } else {
            ghostty_surface_preedit(cSurface, nil, 0)
        }

        requestRender()
    }

    private func sendModifiedKey(
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

    private func sendControlShortcut(_ char: Character) {
        let lower = String(char).lowercased()
        if let key = Ghostty.Input.Key(rawValue: lower) {
            let codepoint = lower.unicodeScalars.first?.value ?? 0
            sendModifiedKey(key, mods: [.ctrl], text: lower, unshiftedCodepoint: codepoint)
            return
        }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            sendText(String(controlChar))
        }
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard surface != nil else { return }
        let shouldInvalidateSession: Bool = switch key {
        case .arrowLeft, .arrowRight, .home, .end, .escape:
            false
        default:
            true
        }
        if shouldInvalidateSession {
            invalidateLocalTextInputSession()
        }

        switch key {
        case .enter:
            sendControlByte(0x0D)
            return
        case .backspace:
            // DEL (0x7F) is the typical backspace for terminals.
            sendControlByte(0x7F)
            return
        default:
            break
        }

        let escapeSequence = TerminalSpecialKeySequence.escapeSequence(for: key)
        sendText(escapeSequence)
    }

    /// Send control key combination (e.g., Ctrl+C)
    func sendControlKey(_ char: Character) {
        guard surface != nil else { return }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            sendText(String(controlChar))
        }
    }

    // MARK: - Process Lifecycle

    /// Check if the terminal process has exited
    var processExited: Bool {
        guard let surface = surface?.unsafeCValue else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Check if closing this terminal needs confirmation
    var needsConfirmQuit: Bool {
        guard let surface = surface else { return false }
        return surface.needsConfirmQuit
    }

    /// Get current terminal grid size
    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        guard let surface = surface else { return nil }
        return surface.terminalSize()
    }

    /// Force the terminal surface to refresh/redraw
    func forceRefresh() {
        if isShuttingDown { return }
        if isPaused { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: bounds.size)

        let scale = self.contentScaleFactor
        guard surfaceDisplayRuntime.forceResize(surface: surface, pointSize: bounds.size, scale: scale) else { return }
        if window != nil {
            surfaceDisplayRuntime.setOcclusion(true, surface: surface)
        }

        surfaceDisplayRuntime.redraw(surface: surface)
        markIOSurfaceLayersForDisplay()
        requestRender()
    }

    /// Reset Ghostty's terminal state before binding a fresh remote shell to a reused surface.
    func resetTerminalForReconnect() {
        guard !isShuttingDown else { return }
        _ = surface?.perform(action: "reset")
        forceRefresh()
    }

    private func configureIOSurfaceLayers() {
        configureIOSurfaceLayers(size: nil)
    }

    private func configureIOSurfaceLayers(size: CGSize?) {
        let scale = self.contentScaleFactor
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

    private func markIOSurfaceLayersForDisplay() {
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

    private func updateContentScaleIfNeeded() {
        let targetScale = window?.screen.scale ?? UIScreen.main.scale
        if contentScaleFactor != targetScale {
            contentScaleFactor = targetScale
        }
    }

    // MARK: - External backend I/O (for SSH clients)

    /// Callback invoked when user types in the terminal. The External backend's
    /// write callback (registered at surface creation) recovers this view via
    /// userdata and forwards to this closure.
    var writeCallback: ((Data) -> Void)?

    /// Feed data from the SSH channel into the terminal for rendering (External backend).
    func writeOutput(_ data: Data) {
        guard let surface = surface?.unsafeCValue else { return }

        surfaceDisplayRuntime.writeOutput(data, to: surface)
        scheduleCustomIORedraw()
        requestRender()
    }

    /// Notify the terminal that the SSH session ended (External backend).
    func externalExited(_ exitCode: UInt32 = 0) {
        guard let surface = surface?.unsafeCValue else { return }
        surfaceDisplayRuntime.externalExited(exitCode, surface: surface)
        scheduleCustomIORedraw()
        requestRender()
    }

}

// MARK: - Native Text Selection

extension GhosttyTerminalView: UITextInteractionDelegate {
    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        guard usesNativeTouchSelection else { return false }
        prefersNativeSelectionFirstResponder = true
        shouldRestoreIMEProxyFocusAfterNativeSelection = imeProxyTextView.isFirstResponder
        refreshNativeSelectionSnapshot()
        return nativeSelectionSnapshot.length > 0
    }

    func interactionWillBegin(_ interaction: UITextInteraction) {
        shouldRestoreIMEProxyFocusAfterNativeSelection = shouldRestoreIMEProxyFocusAfterNativeSelection
            || imeProxyTextView.isFirstResponder
        nativeSelectionInteractionActive = true
        if !imeProxyTextView.isFirstResponder {
            _ = becomeFirstResponder()
        }
        refreshNativeSelectionSnapshot()
    }

    func interactionDidEnd(_ interaction: UITextInteraction) {
        nativeSelectionInteractionActive = false
        if nativeSelectedRange == nil {
            prefersNativeSelectionFirstResponder = false
        }
        refreshNativeSelectionSnapshot()
        guard shouldRestoreIMEProxyFocusAfterNativeSelection else { return }
        shouldRestoreIMEProxyFocusAfterNativeSelection = false
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isShuttingDown,
                  self.isTextInputSessionEligible,
                  !self.isFindNavigatorActive else {
                return
            }
            _ = self.imeProxyTextView.becomeFirstResponder()
        }
    }
}

@available(iOS 16.0, *)
extension GhosttyTerminalView: UIFindInteractionDelegate {
    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        guard view === self, usesNativeTouchSelection else { return nil }
        refreshNativeSelectionSnapshot()
        if let nativeFindSession {
            return nativeFindSession
        }

        let session = GhosttyNativeFindSession(
            onSearch: { [weak self] query, _ in
                guard let self else { return }
                self.performGhosttyFindQuery(
                    query,
                    keepNavigatorVisibleOnSearchEnd: query.isEmpty && self.isFindNavigatorActive
                )
            },
            onNavigate: { [weak self] direction in
                self?.navigateGhosttyFind(direction)
            },
            onInvalidate: { [weak self] in
                self?.invalidateGhosttyFindWithoutClosingNavigator()
            }
        )
        nativeFindSession = session
        applyStoredGhosttyFindResultsToNativeSession()
        return session
    }

    func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
        if !findNavigatorLifecycle.isActive {
            findNavigatorLifecycle.begin(restoreTerminalFocus: imeProxyTextView.isFirstResponder)
        }
        refreshNativeSelectionSnapshot()
        applyStoredGhosttyFindResultsToNativeSession()
        notifyFindNavigatorVisibilityChange()
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        let shouldRestoreTerminalFocus = endFindNavigatorLifecycle()
        nativeFindDecorations.removeAll()
        nativeFindSession?.resetReportedResults()
        nativeFindSession = nil
        ghosttyFindReportedTotal = 0
        ghosttyFindReportedSelectedIndex = nil
        notifyFindNavigatorVisibilityChange()
        endGhosttyFindSearchForNavigatorDismissal()
        if shouldRestoreTerminalFocus {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFindNavigatorActive else { return }
                self.requestKeyboardFocus(for: .explicitUserRequest)
            }
        }
    }
}

@available(iOS 16.0, *)
extension GhosttyTerminalView: UITextSearching {
    typealias DocumentIdentifier = String

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: String?) -> ComparisonResult {
        guard let lhs = nativeSelectionSnapshot.nativeRange(from: foundRange),
              let rhs = nativeSelectionSnapshot.nativeRange(from: toRange) else {
            return .orderedSame
        }
        if lhs.location < rhs.location { return .orderedAscending }
        if lhs.location > rhs.location { return .orderedDescending }
        if lhs.length < rhs.length { return .orderedAscending }
        if lhs.length > rhs.length { return .orderedDescending }
        return .orderedSame
    }

    func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<String>) {
        refreshNativeSelectionSnapshot()
        nativeFindDecorations.removeAll()

        let ranges = nativeSelectionSnapshot.searchRanges(query: queryString, options: options)
        for range in ranges {
            guard let textRange = nativeSelectionSnapshot.nativeRange(range) else { continue }
            resultAggregator.foundRange(textRange, searchString: queryString, document: nativeFindDocumentIdentifier)
        }
        resultAggregator.finishedSearching()
    }

    func decorate(foundTextRange: UITextRange, document: String?, usingStyle style: UITextSearchFoundTextStyle) {
        guard let range = nativeSelectionSnapshot.nativeRange(from: foundTextRange) else { return }
        nativeFindDecorations.removeAll { NSEqualRanges($0.range, range) }
        nativeFindDecorations.append(TerminalNativeFindDecoration(range: range, style: style))
    }

    func clearAllDecoratedFoundText() {
        nativeFindDecorations.removeAll()
    }

    func willHighlight(foundTextRange: UITextRange, document: String?) {
        requestRender()
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument document: String?) {
        requestRender()
    }

    var selectedTextSearchDocument: String? {
        nativeFindDocumentIdentifier
    }

    func compare(document: String, toDocument other: String) -> ComparisonResult {
        document.compare(other)
    }
}

// MARK: - Gesture Recognizer Delegate

extension GhosttyTerminalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer == pinchRecognizer {
            return canHandlePinchZoom
        }
        if gestureRecognizer == scrollRecognizer {
            if isNativeHostScrollContainerEnabled,
               currentScrollOwner() == .hostScrollback {
                return false
            }
            if usesNativeTouchSelection, nativeSelectionInteractionActive || nativeSelectedRange != nil {
                return false
            }
            if touchSelection != nil,
               isPointOnTouchSelectionHandle(touch.location(in: self)) {
                return false
            }
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if usesNativeTouchSelection,
           nativeSelectionInteractionActive || nativeSelectedRange != nil,
           gestureRecognizer == scrollRecognizer || otherGestureRecognizer == scrollRecognizer {
            return false
        }
        if gestureRecognizer == pinchRecognizer || otherGestureRecognizer == pinchRecognizer {
            return false
        }
        // Allow pan and long press to recognize simultaneously
        // The handlers check isSelecting/isScrolling to avoid conflicts
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Long press should win over pan when held long enough
        if gestureRecognizer == scrollRecognizer && otherGestureRecognizer == selectionRecognizer {
            // Only require failure if long press is about to recognize
            return otherGestureRecognizer.state == .began
        }
        return false
    }
}

// MARK: - Edit Menu Interaction Delegate

extension GhosttyTerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var actions: [UIMenuElement] = []

        if let selectionText = currentSelectionText(), !selectionText.isEmpty {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        if usesAppOwnedTouchSelection {
            actions.append(UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.selectAll(nil)
            })
        }

        return UIMenu(children: actions)
    }
}

// MARK: - Keyboard Accessory View

extension GhosttyTerminalView {
    private static var keyboardToolbarKey: UInt8 = 0

    private var keyboardToolbar: TerminalInputAccessoryView? {
        get { objc_getAssociatedObject(self, &Self.keyboardToolbarKey) as? TerminalInputAccessoryView }
        set { objc_setAssociatedObject(self, &Self.keyboardToolbarKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var shouldHideKeyboardAccessoryBar: Bool {
        hasHardwareKeyboardAttached || keyboardFocusPolicy.isBrowsing
    }

    func resolvedInputAccessoryView() -> UIView? {
        guard !isFindNavigatorActive, !shouldHideKeyboardAccessoryBar else {
            return nil
        }
        if keyboardToolbar == nil {
            let toolbar = TerminalInputAccessoryView(onKey: { [weak self] key in
                self?.handleToolbarKey(key)
            }, onCustomAction: { [weak self] action in
                self?.handleToolbarCustomAction(action)
            }, onVoice: onVoiceButtonTapped, onDismissKeyboard: { [weak self] in
                self?.dismissKeyboardFromToolbar()
            })
            keyboardToolbar = toolbar
        } else {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
        return keyboardToolbar
    }

    override var inputAccessoryView: UIView? {
        resolvedInputAccessoryView()
    }

    private func handleToolbarKey(_ key: TerminalKey) {
        sendToolbarKey(key)
    }

    private func sendToolbarKey(_ key: TerminalKey, accumulatedMods: Ghostty.Input.Mods = []) {
        switch key {
        case .modified(let baseKey, let mods):
            sendToolbarKey(baseKey, accumulatedMods: accumulatedMods.union(mods))
        case .escape:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                invalidateLocalTextInputSession()
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false)
            } else {
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false)
            }
        case .tab:
            sendToolbarGhosttyKey(.tab, mods: accumulatedMods)
        case .enter:
            sendToolbarGhosttyKey(.enter, mods: accumulatedMods)
        case .backspace:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                imeProxyTextView.deleteBackward()
            } else {
                sendToolbarGhosttyKey(.backspace, mods: accumulatedMods)
            }
        case .delete:
            sendToolbarGhosttyKey(.delete, mods: accumulatedMods)
        case .insert:
            sendToolbarGhosttyKey(.insert, mods: accumulatedMods)
        case .arrowUp:
            sendToolbarGhosttyKey(.arrowUp, mods: accumulatedMods)
        case .arrowDown:
            sendToolbarGhosttyKey(.arrowDown, mods: accumulatedMods)
        case .arrowLeft:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorLeft()
            } else {
                sendToolbarGhosttyKey(.arrowLeft, mods: accumulatedMods)
            }
        case .arrowRight:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorRight()
            } else {
                sendToolbarGhosttyKey(.arrowRight, mods: accumulatedMods)
            }
        case .home:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorToStart()
            } else {
                sendToolbarGhosttyKey(.home, mods: accumulatedMods)
            }
        case .end:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorToEnd()
            } else {
                sendToolbarGhosttyKey(.end, mods: accumulatedMods)
            }
        case .pageUp:
            sendToolbarGhosttyKey(.pageUp, mods: accumulatedMods)
        case .pageDown:
            sendToolbarGhosttyKey(.pageDown, mods: accumulatedMods)
        case .f1:
            sendToolbarGhosttyKey(.f1, mods: accumulatedMods)
        case .f2:
            sendToolbarGhosttyKey(.f2, mods: accumulatedMods)
        case .f3:
            sendToolbarGhosttyKey(.f3, mods: accumulatedMods)
        case .f4:
            sendToolbarGhosttyKey(.f4, mods: accumulatedMods)
        case .f5:
            sendToolbarGhosttyKey(.f5, mods: accumulatedMods)
        case .f6:
            sendToolbarGhosttyKey(.f6, mods: accumulatedMods)
        case .f7:
            sendToolbarGhosttyKey(.f7, mods: accumulatedMods)
        case .f8:
            sendToolbarGhosttyKey(.f8, mods: accumulatedMods)
        case .f9:
            sendToolbarGhosttyKey(.f9, mods: accumulatedMods)
        case .f10:
            sendToolbarGhosttyKey(.f10, mods: accumulatedMods)
        case .f11:
            sendToolbarGhosttyKey(.f11, mods: accumulatedMods)
        case .f12:
            sendToolbarGhosttyKey(.f12, mods: accumulatedMods)
        case .ctrlC:
            sendToolbarControlShortcut(.c, letter: "c", mods: accumulatedMods)
        case .ctrlD:
            sendToolbarControlShortcut(.d, letter: "d", mods: accumulatedMods)
        case .ctrlZ:
            sendToolbarControlShortcut(.z, letter: "z", mods: accumulatedMods)
        case .ctrlL:
            sendToolbarControlShortcut(.l, letter: "l", mods: accumulatedMods)
        case .ctrlA:
            sendToolbarControlShortcut(.a, letter: "a", mods: accumulatedMods)
        case .ctrlE:
            sendToolbarControlShortcut(.e, letter: "e", mods: accumulatedMods)
        case .ctrlK:
            sendToolbarControlShortcut(.k, letter: "k", mods: accumulatedMods)
        case .ctrlU:
            sendToolbarControlShortcut(.u, letter: "u", mods: accumulatedMods)
        }
    }

    private func sendToolbarGhosttyKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32? = nil,
        invalidateLocalSession: Bool = true
    ) {
        let codepoint = unshiftedCodepoint ?? text?.unicodeScalars.first?.value ?? 0
        sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: codepoint,
            invalidateLocalSession: invalidateLocalSession
        )
    }

    private func sendToolbarControlShortcut(
        _ key: Ghostty.Input.Key,
        letter: String,
        mods: Ghostty.Input.Mods
    ) {
        var mergedMods = mods
        mergedMods.insert(.ctrl)
        let codepoint = letter.unicodeScalars.first?.value ?? 0
        sendToolbarGhosttyKey(key, mods: mergedMods, text: nil, unshiftedCodepoint: codepoint)
    }

    private func handleToolbarCustomAction(_ action: TerminalAccessoryCustomAction) {
        switch action.kind {
        case .command:
            sendText(action.commandContent)
            if action.commandSendMode == .insertAndEnter {
                sendKeyPress(.enter)
            }
        case .shortcut:
            guard let key = Ghostty.Input.Key(rawValue: action.shortcutKey.rawValue) else { return }
            let mods = action.shortcutModifiers.ghosttyModifiers
            let text: String?
            if action.shortcutModifiers.control || action.shortcutModifiers.alternate || action.shortcutModifiers.command {
                text = nil
            } else if action.shortcutModifiers.shift {
                text = action.shortcutKey.shiftedText ?? action.shortcutKey.unshiftedText
            } else {
                text = action.shortcutKey.unshiftedText
            }

            let codepoint = action.shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
            sendToolbarGhosttyKey(key, mods: mods, text: text, unshiftedCodepoint: codepoint)
        }
    }

    private func ghosttyKeyMapping(for character: Character) -> (key: Ghostty.Input.Key, text: String?, codepoint: UInt32, requiresShift: Bool)? {
        let string = String(character)

        for shortcutKey in TerminalAccessoryShortcutKey.allCases {
            if shortcutKey.unshiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.unshiftedText, codepoint, false)
            }

            if shortcutKey.shiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.shiftedText, codepoint, true)
            }
        }

        return nil
    }
}

// MARK: - Software Keyboard (UIKeyInput)

extension GhosttyTerminalView: UIKeyInput, UITextInputTraits {
    var hasText: Bool {
        if isNativeSelectionTextInputContext {
            return nativeSelectionSnapshot.length > 0 || (nativeSelectedRange?.length ?? 0) > 0
        }
        return true
    }

    func insertText(_ text: String) {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        let normalized = text.precomposedStringWithCanonicalMapping
        let wasComposing = textInputModel.hasActiveIMEComposition
        _ = handleIMEProxyInsertText(normalized, fromIMEComposition: wasComposing)
    }

    func deleteBackward() {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        applyTerminalTextInputEffects(textInputModel.handleDeleteBackward())
    }

    fileprivate func consumePendingSystemTextInputHardwareKey() -> UIKey? {
        guard !pendingSystemTextInputHardwareKeys.isEmpty else { return nil }
        return pendingSystemTextInputHardwareKeys.removeFirst()
    }

    func discardPendingSystemTextInputHardwareKey() {
        guard !pendingSystemTextInputHardwareKeys.isEmpty else { return }
        pendingSystemTextInputHardwareKeys.removeFirst()
    }

    func removeUnconsumedPendingSystemTextInputHardwareKeys(after pendingCount: Int) {
        guard pendingSystemTextInputHardwareKeys.count > pendingCount else { return }
        pendingSystemTextInputHardwareKeys.removeSubrange(pendingCount...)
    }

    @discardableResult
    fileprivate func sendInterpretedHardwareKeyText(_ text: String, for key: UIKey) -> Bool {
        guard canRouteTerminalInput, let surface else { return false }
        guard let sourceEvent = Ghostty.Input.KeyEvent(uiKey: key, action: .press) else {
            sendText(text)
            return true
        }
        let keyCode = UInt16(key.keyCode.rawValue)
        let interpretedEvent = Ghostty.Input.KeyEvent(
            key: sourceEvent.key,
            action: .press,
            text: text.isEmpty ? sourceEvent.text : text,
            composing: false,
            mods: sourceEvent.mods,
            consumedMods: sourceEvent.consumedMods,
            unshiftedCodepoint: sourceEvent.unshiftedCodepoint
        )
        surface.sendKeyEvent(interpretedEvent)
        hardwarePressesSentToGhostty.insert(keyCode)
        systemTextInputPresses.remove(keyCode)
        requestRender()
        return true
    }

    var keyboardType: UIKeyboardType {
        get { .default }
        set { }
    }

    var keyboardAppearance: UIKeyboardAppearance {
        get { resolvedKeyboardAppearance }
        set { }
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set { }
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set { }
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set { }
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set { }
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set { }
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set { }
    }

    @available(iOS 17.0, *)
    var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set { }
    }

    var enablesReturnKeyAutomatically: Bool {
        get { false }
        set { }
    }

    var returnKeyType: UIReturnKeyType {
        get { .default }
        set { }
    }
}

// MARK: - UITextInput (spacebar cursor control)

extension GhosttyTerminalView: UITextInput {
    private var isNativeSelectionTextInputContext: Bool {
        usesNativeTouchSelection
            && (nativeSelectionInteractionActive || nativeSelectedRange != nil || prefersNativeSelectionFirstResponder || isFindNavigatorActive)
    }

    private var activeTextInputDocumentLength: Int {
        isNativeSelectionTextInputContext ? nativeSelectionSnapshot.length : textInputModel.documentLength
    }

    private var activeTextInputColumns: Int {
        isNativeSelectionTextInputContext ? nativeSelectionSnapshot.columns : textInputGridMetrics().cols
    }

    private func activeClampedTextInputOffset(_ offset: Int) -> Int {
        min(max(offset, 0), activeTextInputDocumentLength)
    }

    private func terminalTextRange(_ range: TerminalTextInputModel.Range?) -> TerminalNativeTextRange? {
        guard let range else { return nil }
        let location = activeClampedTextInputOffset(range.location)
        let end = activeClampedTextInputOffset(range.location + range.length)
        return TerminalNativeTextRange(start: location, end: end)
    }

    private func terminalTextInputRange(from range: UITextRange?) -> TerminalTextInputModel.Range? {
        guard let range = range as? TerminalNativeTextRange else { return nil }
        let location = activeClampedTextInputOffset(range.nsRange.location)
        let end = activeClampedTextInputOffset(range.nsRange.location + range.nsRange.length)
        return .init(location: location, length: max(end - location, 0))
    }

    var selectedTextRange: UITextRange? {
        get {
            if isNativeSelectionTextInputContext {
                return nativeSelectionSnapshot.nativeRange(nativeSelectedRange)
            }
            return terminalTextRange(textInputModel.selectedRange)
        }
        set {
            if isNativeSelectionTextInputContext {
                setNativeSelectedRange(nativeSelectionSnapshot.nativeRange(from: newValue))
                return
            }
            guard let range = terminalTextInputRange(from: newValue) else { return }
            applyTerminalTextInputEffects(
                textInputModel.handleSetSelection(location: range.location, length: range.length)
            )
        }
    }

    var markedTextRange: UITextRange? {
        isNativeSelectionTextInputContext ? nil : terminalTextRange(textInputModel.markedRange)
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { }
    }

    var inputDelegate: UITextInputDelegate? {
        get { nativeTextInputDelegate }
        set { nativeTextInputDelegate = newValue }
    }

    var tokenizer: UITextInputTokenizer {
        nativeSelectionTokenizer
    }

    var beginningOfDocument: UITextPosition {
        TerminalNativeTextPosition(offset: 0)
    }

    var endOfDocument: UITextPosition {
        TerminalNativeTextPosition(offset: activeTextInputDocumentLength)
    }

    func text(in range: UITextRange) -> String? {
        if isNativeSelectionTextInputContext {
            guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return nil }
            return nativeSelectionSnapshot.text(in: range)
        }
        guard let range = terminalTextInputRange(from: range) else { return nil }
        return textInputModel.substring(rangeStart: range.location, rangeEnd: range.location + range.length)
    }

    func replace(_ range: UITextRange, withText text: String) {
        if isNativeSelectionTextInputContext {
            guard !text.isEmpty else { return }
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
            _ = handleIMEProxyInsertText(text, fromIMEComposition: false)
            return
        }
        let replacementRange = terminalTextInputRange(from: range)
        applyTerminalTextInputEffects(
            textInputModel.handleReplace(
                rangeStart: replacementRange?.location,
                rangeEnd: replacementRange.map { $0.location + $0.length },
                text: text
            )
        )
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        discardPendingSystemTextInputHardwareKey()
        applyTerminalTextInputEffects(
            textInputModel.handleSetMarkedText(
                markedText,
                selectedRangeLocation: selectedRange.location,
                selectedRangeLength: selectedRange.length
            )
        )
    }

    func unmarkText() {
        if isNativeSelectionTextInputContext {
            guard exitNativeSelectionTextInputContextForTerminalInput() else { return }
        }
        discardPendingSystemTextInputHardwareKey()
        applyTerminalTextInputEffects(textInputModel.handleUnmarkText())
    }

    var textInputView: UIView {
        self
    }

    var selectionAffinity: UITextStorageDirection {
        get { nativeSelectionAffinity }
        set { nativeSelectionAffinity = newValue }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalNativeTextPosition,
              let to = toPosition as? TerminalNativeTextPosition else { return nil }
        return TerminalNativeTextRange(start: from.offset, end: to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }
        return TerminalNativeTextPosition(offset: activeClampedTextInputOffset(position.offset + offset))
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }

        let delta: Int
        switch direction {
        case .left:
            delta = -offset
        case .right:
            delta = offset
        case .up:
            delta = -(offset * activeTextInputColumns)
        case .down:
            delta = offset * activeTextInputColumns
        @unknown default:
            delta = offset
        }

        return TerminalNativeTextPosition(offset: activeClampedTextInputOffset(position.offset + delta))
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let position = position as? TerminalNativeTextPosition,
              let other = other as? TerminalNativeTextPosition else { return .orderedSame }
        if position.offset < other.offset { return .orderedAscending }
        if position.offset > other.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to other: UITextPosition) -> Int {
        guard let from = from as? TerminalNativeTextPosition,
              let other = other as? TerminalNativeTextPosition else { return 0 }
        return other.offset - from.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = terminalTextInputRange(from: range) else { return nil }
        switch direction {
        case .left, .up:
            return TerminalNativeTextPosition(offset: range.location)
        case .right, .down:
            return TerminalNativeTextPosition(offset: range.location + range.length)
        @unknown default:
            return TerminalNativeTextPosition(offset: range.location + range.length)
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }
        switch direction {
        case .left, .up:
            let start = activeClampedTextInputOffset(position.offset - 1)
            return TerminalNativeTextRange(start: start, end: position.offset)
        case .right, .down:
            let end = activeClampedTextInputOffset(position.offset + 1)
            return TerminalNativeTextRange(start: position.offset, end: end)
        @unknown default:
            let end = activeClampedTextInputOffset(position.offset + 1)
            return TerminalNativeTextRange(start: position.offset, end: end)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
    }

    func firstRect(for range: UITextRange) -> CGRect {
        if isNativeSelectionTextInputContext {
            guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return .zero }
            return nativeSelectionSnapshot.firstRect(for: range)
        }
        guard let range = terminalTextInputRange(from: range) else { return .zero }
        return textInputCaretRect(for: range.location)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let position = position as? TerminalNativeTextPosition else { return .zero }
        if isNativeSelectionTextInputContext {
            return nativeSelectionSnapshot.caretRect(for: position.offset)
        }
        return textInputCaretRect(for: position.offset)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard isNativeSelectionTextInputContext else { return [] }
        guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return [] }
        return nativeSelectionSnapshot.selectionRects(for: range)
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard isNativeSelectionTextInputContext else {
            return TerminalNativeTextPosition(offset: textInputModel.cursorIndex)
        }
        return TerminalNativeTextPosition(offset: nativeSelectionSnapshot.offset(for: point))
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard isNativeSelectionTextInputContext else {
            return closestPosition(to: point)
        }
        guard let range = nativeSelectionSnapshot.nativeRange(from: range) else { return nil }
        let offset = nativeSelectionSnapshot.offset(for: point)
        let clamped = min(max(offset, range.location), range.location + range.length)
        return TerminalNativeTextPosition(offset: clamped)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard isNativeSelectionTextInputContext else {
            let offset = activeClampedTextInputOffset(textInputModel.cursorIndex)
            return TerminalNativeTextRange(start: offset, end: offset)
        }
        guard let range = nativeSelectionSnapshot.characterRange(at: point) else { return nil }
        return TerminalNativeTextRange(start: range.location, end: range.location + range.length)
    }

    func textStyling(at position: UITextPosition, in direction: UITextStorageDirection) -> [NSAttributedString.Key: Any]? {
        nil
    }

    @available(iOS 16.0, *)
    func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard usesNativeTouchSelection else { return nil }
        return UIMenu(children: nativeSelectionMenuElements())
    }

    func position(within range: UITextRange, atCharacterOffset offset: Int) -> UITextPosition? {
        guard let range = terminalTextInputRange(from: range) else { return nil }
        return TerminalNativeTextPosition(offset: activeClampedTextInputOffset(range.location + offset))
    }

    func characterOffset(of position: UITextPosition, within range: UITextRange) -> Int {
        guard let position = position as? TerminalNativeTextPosition,
              let range = terminalTextInputRange(from: range) else { return 0 }
        return position.offset - range.location
    }
}

#endif
