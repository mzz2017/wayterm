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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let proxySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/TerminalIMEProxyTextView+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let accessorySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/TerminalInputAccessoryView+iOS.swift")
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
    func keyboardAccessoryRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let accessoryRoutingSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+KeyboardAccessory+iOS.swift")
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
    func textInputConformanceLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let textInputSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TextInput+iOS.swift")
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
    func hardwareKeyboardRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let hardwareKeyboardSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+HardwareKeyboard+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let terminalInputSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TerminalInput+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Selection/GhosttyTerminalView+SelectionInteractions+iOS.swift")
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
    func scrollGestureRoutingLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let scrollSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Scroll/GhosttyTerminalView+ScrollGesture+iOS.swift")
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
    func interactionDelegatesLiveOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let interactionDelegateSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+InteractionDelegates+iOS.swift")
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
        #expect(interactionDelegateSource.contains("extension GhosttyTerminalView: UITextSearching"))
        #expect(interactionDelegateSource.contains("extension GhosttyTerminalView: UIGestureRecognizerDelegate"))
        #expect(interactionDelegateSource.contains("extension GhosttyTerminalView: UIEditMenuInteractionDelegate"))
    }

    @Test
    func terminalKeyModelLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let keySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/TerminalKey+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let lifecycleSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Find/TerminalFindNavigatorLifecycle+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let zoomSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Zoom/TerminalZoomIndicatorView+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let surfaceRuntimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/GhosttyTerminalView+SurfaceRuntime+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let momentumSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Scroll/TerminalMomentumScrollState+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let presentationSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Presentation/TerminalIOSPresentationEnvironment.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Selection/GhosttyTerminalView+SelectionInteractions+iOS.swift")
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
        while url.lastPathComponent != "VVTermTests" {
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
