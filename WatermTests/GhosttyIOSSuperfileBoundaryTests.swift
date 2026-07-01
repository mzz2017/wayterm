import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty terminal superfile control.
// GhosttyTerminalView+iOS owns rendering, input routing, selection, find, and
// UIKit integration; large helper owners such as the IME proxy should live in
// separate files so future input changes do not expand the main view superfile.
// Update these tests only when the helper ownership intentionally moves again.
@Suite(.serialized)
struct GhosttyIOSSuperfileBoundaryTests {
    @Test
    func imeProxyTextViewLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let proxySource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/TerminalIMEProxyTextView+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("final class TerminalIMEProxyTextView"),
            "GhosttyTerminalView+iOS.swift should not own the IME proxy class."
        )

        // Then the IME proxy has a dedicated UIKit text-input owner file.
        #expect(proxySource.contains("final class TerminalIMEProxyTextView"))
        #expect(proxySource.contains("UITextInput"))
    }

    @Test
    func inputAccessoryViewLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let accessorySource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/TerminalInputAccessoryView+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("class TerminalInputAccessoryView"),
            "GhosttyTerminalView+iOS.swift should not own the keyboard accessory view class."
        )

        // Then the input accessory has a dedicated UIKit toolbar owner file.
        #expect(accessorySource.contains("class TerminalInputAccessoryView"))
        #expect(accessorySource.contains("UIInputView"))
        #expect(accessorySource.contains("RepeatableKeyButton"))
    }

    @Test
    func inputAccessoryViewMovesObserverAndRepeatTimerOwnershipOutOfUIState() throws {
        let root = try sourceRoot()
        let accessorySource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/TerminalInputAccessoryView+iOS.swift")
        )

        #expect(
            accessorySource.contains("NotificationObserverTokens"),
            "TerminalInputAccessoryView should use the shared observer-token owner for NotificationCenter tokens."
        )
        #expect(
            !accessorySource.contains("defaultsObserver: NSObjectProtocol"),
            "UserDefaults observer tokens should not be stored as main-actor UI state."
        )
        #expect(
            !accessorySource.contains("accessoryProfileObserver: NSObjectProtocol"),
            "Accessory profile observer tokens should not be stored as main-actor UI state."
        )
        #expect(
            accessorySource.contains("TerminalInputKeyRepeatOwner"),
            "Keyboard repeat timer ownership should live in a dedicated lifecycle owner."
        )
        #expect(
            !accessorySource.contains("keyRepeatTimer: DispatchSourceTimer"),
            "DispatchSourceTimer should not be stored directly on the UIInputView."
        )
        #expect(
            accessorySource.contains("MainActor.assumeIsolated"),
            "Main-queue NotificationCenter callbacks should explicitly hand intent back to the UI actor."
        )
    }

    @Test
    func keyboardAccessoryRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let accessoryRoutingSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+KeyboardAccessory+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("private func toolbarRoutingContext"),
            "GhosttyTerminalView+iOS.swift should not own keyboard toolbar routing contexts."
        )
        #expect(
            !mainSource.contains("override var inputAccessoryView"),
            "GhosttyTerminalView+iOS.swift should not own keyboard accessory presentation."
        )

        // Then keyboard accessory routing has a dedicated GhosttyTerminalView extension.
        #expect(accessoryRoutingSource.contains("func resolvedInputAccessoryView()"))
        #expect(accessoryRoutingSource.contains("func routeToolbarKey"))
        #expect(accessoryRoutingSource.contains("TerminalIOSInputRuntime.ToolbarRoutingContext"))
    }

    @Test
    func lifecycleObserverBagOwnsNotificationTokensOutsideMainActorState() throws {
        let root = try sourceRoot()
        let observerBagSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/TerminalLifecycleObserverBag+iOS.swift")
        )

        #expect(
            observerBagSource.contains("NotificationObserverTokens"),
            "TerminalLifecycleObserverBag should use the shared observer-token owner for NotificationCenter tokens."
        )
        #expect(
            !observerBagSource.contains("configReloadObserver: NSObjectProtocol"),
            "Config reload observer tokens should not be stored directly on the observer bag."
        )
        #expect(
            !observerBagSource.contains("inputModeObserver: NSObjectProtocol"),
            "Input mode observer tokens should not be stored directly on the observer bag."
        )
        #expect(
            !observerBagSource.contains("hardwareKeyboardObservers: [NSObjectProtocol]"),
            "Hardware keyboard observer tokens should not be stored directly on the observer bag."
        )
        #expect(
            observerBagSource.contains("MainActor.assumeIsolated"),
            "Main-queue NotificationCenter callbacks should explicitly hand intent back to the UI actor."
        )
        #expect(
            !observerBagSource.contains("Task { @MainActor"),
            "Observer callbacks should not create untracked main-actor tasks for synchronous main-queue delivery."
        )
    }

    @Test
    func textInputConformanceLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let textInputSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TextInput+iOS.swift")
        )

        #expect(
            !mainSource.contains("extension GhosttyTerminalView: UIKeyInput"),
            "GhosttyTerminalView+iOS.swift should not own software keyboard conformance."
        )
        #expect(
            !mainSource.contains("extension GhosttyTerminalView: UITextInput"),
            "GhosttyTerminalView+iOS.swift should not own native text input conformance."
        )

        #expect(textInputSource.contains("extension GhosttyTerminalView: UIKeyInput, UITextInputTraits"))
        #expect(textInputSource.contains("extension GhosttyTerminalView: UITextInput"))
        #expect(textInputSource.contains("func consumePendingSystemTextInputHardwareKey()"))
        #expect(textInputSource.contains("func sendInterpretedHardwareKeyText"))
    }

    @Test
    func imeProxyRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let imeProxySource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+IMEProxy+iOS.swift")
        )

        #expect(
            !mainSource.contains("func imeProxySnapshot"),
            "GhosttyTerminalView+iOS.swift should not own IME proxy state snapshots."
        )
        #expect(
            !mainSource.contains("func syncTextInputModelFromIMEProxy"),
            "GhosttyTerminalView+iOS.swift should not own IME proxy-to-model sync."
        )
        #expect(
            !mainSource.contains("func imeProxyFocusDidChange"),
            "GhosttyTerminalView+iOS.swift should not own IME proxy focus effects."
        )
        #expect(
            !mainSource.contains("func runTerminalTextInputEffects"),
            "GhosttyTerminalView+iOS.swift should not own terminal text-input effect routing."
        )

        #expect(imeProxySource.contains("func imeProxySnapshot"))
        #expect(imeProxySource.contains("func syncTextInputModelFromIMEProxy"))
        #expect(imeProxySource.contains("func imeProxyFocusDidChange"))
        #expect(imeProxySource.contains("inputRuntime.handleTerminalTextInputEffects"))
    }

    @Test
    func hardwareKeyboardRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let hardwareKeyboardSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+HardwareKeyboard+iOS.swift")
        )

        #expect(
            !mainSource.contains("override func pressesBegan"),
            "GhosttyTerminalView+iOS.swift should not own hardware keyboard press routing."
        )
        #expect(
            !mainSource.contains("override func pressesEnded"),
            "GhosttyTerminalView+iOS.swift should not own hardware keyboard release routing."
        )
        #expect(
            !mainSource.contains("private func fallbackHardwareKey"),
            "GhosttyTerminalView+iOS.swift should not own hardware key fallback mapping."
        )

        #expect(hardwareKeyboardSource.contains("override func pressesBegan"))
        #expect(hardwareKeyboardSource.contains("override func pressesEnded"))
        #expect(hardwareKeyboardSource.contains("func processHardwarePressesBegan"))
        #expect(hardwareKeyboardSource.contains("TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput"))
    }

    @Test
    func terminalInputRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let terminalInputSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TerminalInput+iOS.swift")
        )

        #expect(
            !mainSource.contains("func handleIMEProxyInsertText"),
            "GhosttyTerminalView+iOS.swift should not own IME text insertion routing."
        )
        #expect(
            !mainSource.contains("func sendModifiedKey("),
            "GhosttyTerminalView+iOS.swift should not own modified terminal key routing."
        )
        #expect(
            !mainSource.contains("private func terminalInputExecutionContext"),
            "GhosttyTerminalView+iOS.swift should not own terminal input execution contexts."
        )

        #expect(terminalInputSource.contains("func handleIMEProxyInsertText"))
        #expect(terminalInputSource.contains("func sendModifiedKey("))
        #expect(terminalInputSource.contains("func sendSpecialKey"))
        #expect(terminalInputSource.contains("func sendControlKey"))
        #expect(terminalInputSource.contains("TerminalIOSInputRuntime.IMEInsertExecutionContext"))
    }

    @Test
    func selectionInteractionsLiveOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Selection/GhosttyTerminalView+SelectionInteractions+iOS.swift")
        )

        #expect(
            !mainSource.contains("func handleSelectionPress"),
            "GhosttyTerminalView+iOS.swift should not own touch selection gesture routing."
        )
        #expect(
            !mainSource.contains("func nativeSelectionMenuElements"),
            "GhosttyTerminalView+iOS.swift should not own native selection menu construction."
        )
        #expect(
            !mainSource.contains("func selectAllVisibleText"),
            "GhosttyTerminalView+iOS.swift should not own selection command policy."
        )

        #expect(selectionSource.contains("func handleSelectionPress"))
        #expect(selectionSource.contains("func nativeSelectionMenuElements"))
        #expect(selectionSource.contains("func selectAllVisibleText"))
        #expect(selectionSource.contains("TerminalTouchSelectionLayout"))
    }

    @Test
    func nativeSelectionStateLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Selection/GhosttyTerminalView+SelectionInteractions+iOS.swift")
        )
        let surfaceOwnerSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )

        #expect(
            !mainSource.contains("func setupNativeTextSelectionInteractions"),
            "GhosttyTerminalView+iOS.swift should not own native text-selection interaction setup."
        )
        #expect(
            !mainSource.contains("func refreshNativeSelectionSnapshot"),
            "GhosttyTerminalView+iOS.swift should not own native selection snapshot refresh."
        )
        #expect(
            !mainSource.contains("func setNativeSelectedRange"),
            "GhosttyTerminalView+iOS.swift should not own native selected-range mutation."
        )
        #expect(
            !mainSource.contains("func isPointOnNativeSelectionHandleHitArea"),
            "GhosttyTerminalView+iOS.swift should not own native selection hit testing."
        )

        #expect(selectionSource.contains("func setupNativeTextSelectionInteractions"))
        #expect(selectionSource.contains("func refreshNativeSelectionSnapshot"))
        #expect(selectionSource.contains("func setNativeSelectedRange"))
        #expect(surfaceOwnerSource.contains("selectionRuntime.nativeTextSnapshot"))
    }

    @Test
    func scrollGestureRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let scrollSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Scroll/GhosttyTerminalView+ScrollGesture+iOS.swift")
        )

        #expect(
            !mainSource.contains("func handlePanGesture"),
            "GhosttyTerminalView+iOS.swift should not own pan scroll routing."
        )
        #expect(
            !mainSource.contains("func currentScrollOwner"),
            "GhosttyTerminalView+iOS.swift should not own scroll owner policy wiring."
        )
        #expect(
            !mainSource.contains("func setNativeHostScrollContainerEnabled"),
            "GhosttyTerminalView+iOS.swift should not own native host scroll toggling."
        )

        #expect(scrollSource.contains("func handlePanGesture"))
        #expect(scrollSource.contains("func currentScrollOwner"))
        #expect(scrollSource.contains("TerminalScrollRoutingPolicy.owner"))
        #expect(scrollSource.contains("scrollRuntime.handlePanGesture"))
    }

    @Test
    func zoomGestureRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let zoomSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Zoom/GhosttyTerminalView+ZoomGesture+iOS.swift")
        )

        #expect(
            !mainSource.contains("func handlePinchGesture"),
            "GhosttyTerminalView+iOS.swift should not own pinch zoom gesture routing."
        )
        #expect(
            !mainSource.contains("var canHandlePinchZoom"),
            "GhosttyTerminalView+iOS.swift should not own pinch zoom availability policy."
        )

        #expect(zoomSource.contains("func handlePinchGesture"))
        #expect(zoomSource.contains("var canHandlePinchZoom"))
        #expect(zoomSource.contains("zoomRuntime.handlePinchGesture"))
    }

    @Test
    func surfaceLifecycleLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let surfaceSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Surface/GhosttyTerminalView+SurfaceRuntime+iOS.swift")
        )
        let surfaceOwnerSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )

        #expect(
            !mainSource.contains("func setupSurface"),
            "GhosttyTerminalView+iOS.swift should not own Ghostty C surface creation."
        )
        #expect(
            !mainSource.contains("func cleanup()"),
            "GhosttyTerminalView+iOS.swift should not own terminal surface teardown sequencing."
        )
        #expect(
            !mainSource.contains("func pauseRendering"),
            "GhosttyTerminalView+iOS.swift should not own surface pause lifecycle."
        )
        #expect(
            !mainSource.contains("func resumeRendering"),
            "GhosttyTerminalView+iOS.swift should not own surface resume lifecycle."
        )

        #expect(surfaceSource.contains("func setupSurface"))
        #expect(surfaceSource.contains("surfaceOwner.cleanup"))
        #expect(!surfaceSource.contains("using: surfaceLifecycleRuntime"))
        #expect(surfaceSource.contains("surfaceOwner.createAndRegisterSurface"))
        #expect(surfaceOwnerSource.contains("surfaceRegistration.register"))
        #expect(surfaceOwnerSource.contains("renderingSetup.setupSurface"))
    }

    @Test
    func findNavigatorRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let findSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Find/GhosttyTerminalView+FindNavigator+iOS.swift")
        )

        #expect(
            !mainSource.contains("func setupNativeFindInteraction"),
            "GhosttyTerminalView+iOS.swift should not own native find interaction setup."
        )
        #expect(
            !mainSource.contains("func presentFindNavigator"),
            "GhosttyTerminalView+iOS.swift should not own find navigator presentation."
        )
        #expect(
            !mainSource.contains("func performGhosttyFindQuery"),
            "GhosttyTerminalView+iOS.swift should not own Ghostty find action routing."
        )
        #expect(
            !mainSource.contains("func handleGhosttySearchStarted"),
            "GhosttyTerminalView+iOS.swift should not own Ghostty search lifecycle callbacks."
        )

        #expect(findSource.contains("func setupNativeFindInteraction"))
        #expect(findSource.contains("func presentFindNavigator"))
        #expect(findSource.contains("func performGhosttyFindQuery"))
        #expect(findSource.contains("findRuntime.beginNavigatorLifecycle"))
        #expect(findSource.contains("nativeFindInteraction?.updateResultCount"))
    }

    @Test
    func interactionDelegatesLiveOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let interactionDelegateSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+InteractionDelegates+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("extension GhosttyTerminalView: UITextInteractionDelegate"),
            "GhosttyTerminalView+iOS.swift should not own native text-selection delegate callbacks."
        )
        #expect(
            !mainSource.contains("extension GhosttyTerminalView: UIFindInteractionDelegate"),
            "GhosttyTerminalView+iOS.swift should not own native find delegate callbacks."
        )
        #expect(
            !mainSource.contains("extension GhosttyTerminalView: UIGestureRecognizerDelegate"),
            "GhosttyTerminalView+iOS.swift should not own gesture-recognizer delegate callbacks."
        )
        #expect(
            !mainSource.contains("extension GhosttyTerminalView: UIEditMenuInteractionDelegate"),
            "GhosttyTerminalView+iOS.swift should not own edit-menu delegate callbacks."
        )

        // Then UIKit interaction delegate routing has a dedicated extension file.
        #expect(interactionDelegateSource.contains("extension GhosttyTerminalView: UITextInteractionDelegate"))
        #expect(interactionDelegateSource.contains("extension GhosttyTerminalView: UIFindInteractionDelegate"))
        #expect(
            interactionDelegateSource.contains("extension GhosttyTerminalView: @preconcurrency UITextSearching"),
            "UIKit UITextSearching conformance should defer legacy nonisolated protocol checks instead of weakening GhosttyTerminalView main-actor isolation."
        )
        #expect(interactionDelegateSource.contains("extension GhosttyTerminalView: UIGestureRecognizerDelegate"))
        #expect(interactionDelegateSource.contains("extension GhosttyTerminalView: UIEditMenuInteractionDelegate"))
    }

    @Test
    func terminalKeyModelLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let keySource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/TerminalKey+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("enum TerminalKey"),
            "GhosttyTerminalView+iOS.swift should not own the terminal key model."
        )

        // Then toolbar key modeling and Ghostty modifier bridging have a dedicated file.
        #expect(keySource.contains("enum TerminalKey"))
        #expect(keySource.contains("ansiSequence"))
        #expect(keySource.contains("TerminalAccessoryShortcutModifiers"))
    }

    @Test
    func findNavigatorLifecycleLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let lifecycleSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Find/TerminalFindNavigatorLifecycle+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("struct TerminalFindNavigatorLifecycle"),
            "GhosttyTerminalView+iOS.swift should not own the find navigator lifecycle helper."
        )

        // Then the find navigator lifecycle state machine has a dedicated file.
        #expect(lifecycleSource.contains("struct TerminalFindNavigatorLifecycle"))
        #expect(lifecycleSource.contains("consumeSuppressedGhosttySearchEnd"))
    }

    @Test
    func zoomIndicatorViewLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let zoomSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Zoom/TerminalZoomIndicatorView+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("final class TerminalZoomIndicatorView"),
            "GhosttyTerminalView+iOS.swift should not own the zoom indicator view class."
        )

        // Then the zoom indicator rendering helper has a dedicated UIKit file.
        #expect(zoomSource.contains("final class TerminalZoomIndicatorView"))
        #expect(zoomSource.contains("UIVisualEffectView"))
        #expect(zoomSource.contains("TerminalZoomPresentation"))
    }

    @Test
    func terminalSurfaceStateCallbacksAreMainActorBound() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )

        #expect(
            mainSource.contains("var onKeyboardBrowseModeChange: (@MainActor (Bool) -> Void)?"),
            "Keyboard browse state callbacks should be main-actor bound so managers do not need untracked Tasks."
        )
        #expect(
            mainSource.contains("var onFindNavigatorVisibilityChange: (@MainActor (Bool) -> Void)?"),
            "Find navigator visibility callbacks should be main-actor bound so managers do not need untracked Tasks."
        )
    }

    @Test
    func surfaceRuntimeLifecycleLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let surfaceRuntimeSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Surface/GhosttyTerminalView+SurfaceRuntime+iOS.swift")
        )

        #expect(
            !mainSource.contains("func forceRefresh()"),
            "GhosttyTerminalView+iOS.swift should not own surface refresh orchestration."
        )
        #expect(
            !mainSource.contains("func writeOutput(_ data: Data)"),
            "GhosttyTerminalView+iOS.swift should not own external backend output routing."
        )

        #expect(surfaceRuntimeSource.contains("extension GhosttyTerminalView"))
        #expect(surfaceRuntimeSource.contains("func forceRefresh()"))
        #expect(surfaceRuntimeSource.contains("func writeOutput(_ data: Data)"))
        #expect(surfaceRuntimeSource.contains("func externalExited"))
    }

    @Test
    func momentumScrollStateLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let momentumSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Scroll/TerminalMomentumScrollState+iOS.swift")
        )

        // Given the iOS Ghostty terminal main view source.
        #expect(
            !mainSource.contains("private var momentumVelocity"),
            "GhosttyTerminalView+iOS.swift should not own raw momentum velocity state."
        )
        #expect(
            !mainSource.contains("private var momentumPhase"),
            "GhosttyTerminalView+iOS.swift should not own raw Ghostty momentum phase state."
        )

        // Then inertial scroll state and phase calculation have a dedicated file.
        #expect(momentumSource.contains("struct TerminalMomentumScrollState"))
        #expect(momentumSource.contains("nextFrameEvent"))
    }

    @Test
    func iOSPresentationPolicyLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let presentationSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Presentation/TerminalIOSPresentationEnvironment.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Selection/GhosttyTerminalView+SelectionInteractions+iOS.swift")
        )

        // Given GhosttyTerminalView needs app-active state, menu presentation,
        // and URL opening for iOS terminal interactions.
        #expect(mainSource.contains("let presentationEnvironment: TerminalIOSPresentationEnvironment"))
        #expect(mainSource.contains("presentationEnvironment.isApplicationActive()"))
        #expect(selectionSource.contains("presentationEnvironment.presentController"))
        #expect(selectionSource.contains("presentationEnvironment.openURL(url)"))

        // Then the main surface view does not own those platform singleton
        // lookups or presenter traversal details.
        #expect(!mainSource.contains("UIApplication.shared"))
        #expect(!mainSource.contains("topMostPresentedViewController"))
        #expect(!mainSource.contains("nearestPresentingViewController"))
        #expect(!mainSource.contains("present(controller"))
        #expect(!mainSource.contains("open(url)"))

        #expect(presentationSource.contains("struct TerminalIOSPresentationEnvironment"))
        #expect(presentationSource.contains("static var live: Self"))
        #expect(presentationSource.contains("UIApplication.shared.applicationState == .active"))
        #expect(presentationSource.contains("UIApplication.shared.open(url)"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
