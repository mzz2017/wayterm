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
