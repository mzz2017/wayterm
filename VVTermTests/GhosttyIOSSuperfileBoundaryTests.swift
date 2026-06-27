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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let proxySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIMEProxyTextView+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let accessorySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalInputAccessoryView+iOS.swift")
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
    func terminalKeyModelLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let keySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalKey+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let lifecycleSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalFindNavigatorLifecycle+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let zoomSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalZoomIndicatorView+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
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
    func momentumScrollStateLivesOutsideMainGhosttyTerminalViewFile() throws {
        let root = try sourceRoot()
        let mainSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let momentumSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalMomentumScrollState+iOS.swift")
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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let presentationSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSPresentationEnvironment.swift")
        )

        // Given GhosttyTerminalView needs app-active state, menu presentation,
        // and URL opening for iOS terminal interactions.
        #expect(mainSource.contains("private let presentationEnvironment: TerminalIOSPresentationEnvironment"))
        #expect(mainSource.contains("presentationEnvironment.isApplicationActive()"))
        #expect(mainSource.contains("presentationEnvironment.presentController"))
        #expect(mainSource.contains("presentationEnvironment.openURL(url)"))

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
