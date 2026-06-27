import Foundation
import Testing

// Test Context:
// Protects ownership of iOS hardware-press bookkeeping. GhosttyTerminalView and
// its IME proxy may process UIKit press events, but sent-key tracking, fallback
// release records, and pending system text-input keys must live in one state owner.
// Update this test only when that ownership intentionally moves again.
@Suite(.serialized)
struct GhosttyIOSHardwarePressStateBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesHardwarePressBookkeepingToStateOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let hardwareKeyboardSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+HardwareKeyboard+iOS.swift")
        )
        let textInputSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TextInput+iOS.swift")
        )
        let proxySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/TerminalIMEProxyTextView+iOS.swift")
        )
        let stateSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/TerminalIOSHardwarePressState.swift")
        )

        #expect(viewSource.contains("let hardwarePressState = TerminalIOSHardwarePressState()"))
        #expect(hardwareKeyboardSource.contains("hardwarePressState.recordDirectGhosttyPress"))
        #expect(hardwareKeyboardSource.contains("hardwarePressState.recordFallbackGhosttyPress"))
        #expect(hardwareKeyboardSource.contains("hardwarePressState.releaseGhosttyPress"))
        #expect(textInputSource.contains("hardwarePressState.consumePendingSystemTextInputHardwareKey()"))
        #expect(textInputSource.contains("hardwarePressState.pendingSystemTextInputHardwareKeyCount"))

        #expect(!viewSource.contains("var pendingSystemTextInputHardwareKeys"))
        #expect(!viewSource.contains("private var hardwarePressesSentToGhostty"))
        #expect(!viewSource.contains("private var fallbackHardwarePressKeys"))
        #expect(!viewSource.contains("private var fallbackHardwarePressModifiers"))
        #expect(!viewSource.contains("private var systemTextInputPresses"))
        #expect(!proxySource.contains("pendingSystemTextInputHardwareKeys"))

        #expect(stateSource.contains("final class TerminalIOSHardwarePressState"))
        #expect(stateSource.contains("private var ghosttyPressKeyCodes"))
        #expect(stateSource.contains("private var fallbackPresses"))
        #expect(stateSource.contains("private var systemTextInputKeyCodes"))
        #expect(stateSource.contains("private var pendingSystemTextInputHardwareKeys"))
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
