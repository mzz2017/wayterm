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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let proxySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIMEProxyTextView+iOS.swift")
        )
        let stateSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSHardwarePressState.swift")
        )

        #expect(viewSource.contains("private let hardwarePressState = TerminalIOSHardwarePressState()"))
        #expect(viewSource.contains("hardwarePressState.recordDirectGhosttyPress"))
        #expect(viewSource.contains("hardwarePressState.recordFallbackGhosttyPress"))
        #expect(viewSource.contains("hardwarePressState.releaseGhosttyPress"))
        #expect(viewSource.contains("hardwarePressState.pendingSystemTextInputHardwareKeyCount"))

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
