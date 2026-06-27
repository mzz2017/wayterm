import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty input runtime ownership. The
// UIKit terminal view may decide routing policy, but direct hardware key FFI,
// visible IME preedit state, IME proxy focus/resign state, and toolbar key
// routing should be owned by a focused runtime helper. Update these tests only
// if those responsibilities intentionally move to another non-view owner.

@Suite(.serialized)
struct GhosttyIOSInputRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesHardwareKeyAndPreeditRuntimeToInputOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSInputRuntime.swift")
        )

        // Given the iOS terminal view routes hardware keys and IME preedit.
        #expect(viewSource.contains("private let inputRuntime = TerminalIOSInputRuntime()"))
        #expect(viewSource.contains("inputRuntime.sendDirectHardwareKeyEvent"))
        #expect(viewSource.contains("inputRuntime.syncVisiblePreedit"))
        #expect(viewSource.contains("inputRuntime.canResignIMEProxy"))
        #expect(viewSource.contains("inputRuntime.suppressUnexpectedIMEProxyResign"))
        #expect(viewSource.contains("inputRuntime.performProgrammaticIMEProxyResign"))
        #expect(viewSource.contains("inputRuntime.handleToolbarKey"))
        #expect(viewSource.contains("inputRuntime.handleToolbarCustomAction"))
        #expect(viewSource.contains("inputRuntime.ghosttyKeyMapping"))

        // Then the main UIKit view does not directly own those C/FFI calls,
        // visible preedit state, or the Ghostty action conversion helper.
        #expect(!viewSource.contains("ghostty_surface_key"))
        #expect(!viewSource.contains("ghostty_surface_preedit"))
        #expect(!viewSource.contains("private func ghosttyInputAction"))
        #expect(!viewSource.contains("private func sendToolbarKey"))
        #expect(!viewSource.contains("private func sendToolbarGhosttyKey"))
        #expect(!viewSource.contains("private func sendToolbarControlShortcut"))
        #expect(!viewSource.contains("private func handleToolbarCustomAction"))
        #expect(!viewSource.contains("private func ghosttyKeyMapping"))
        #expect(!viewSource.contains("private var renderedIMEPreeditText"))
        #expect(!viewSource.contains("private func shouldDisplayVisiblePreedit"))
        #expect(!viewSource.contains("private var allowIMEProxyProgrammaticResign"))
        #expect(!viewSource.contains("private var suppressUnexpectedIMEProxyResignUntil"))
        #expect(!viewSource.contains("private var shouldSuppressUnexpectedIMEProxyResign"))

        #expect(runtimeSource.contains("final class TerminalIOSInputRuntime"))
        #expect(runtimeSource.contains("private var renderedPreeditText"))
        #expect(runtimeSource.contains("private var isIMEProxyProgrammaticResignAllowed"))
        #expect(runtimeSource.contains("private var suppressUnexpectedIMEProxyResignUntil"))
        #expect(runtimeSource.contains("func sendDirectHardwareKeyEvent"))
        #expect(runtimeSource.contains("func syncVisiblePreedit"))
        #expect(runtimeSource.contains("func syncPreedit"))
        #expect(runtimeSource.contains("func canResignIMEProxy"))
        #expect(runtimeSource.contains("func suppressUnexpectedIMEProxyResign"))
        #expect(runtimeSource.contains("func performProgrammaticIMEProxyResign"))
        #expect(runtimeSource.contains("func handleToolbarKey"))
        #expect(runtimeSource.contains("func handleToolbarCustomAction"))
        #expect(runtimeSource.contains("func ghosttyKeyMapping"))
        #expect(runtimeSource.contains("private func sendToolbarKey"))
        #expect(runtimeSource.contains("private func sendToolbarGhosttyKey"))
        #expect(runtimeSource.contains("private func sendToolbarControlShortcut"))
        #expect(runtimeSource.contains("ghostty_surface_key"))
        #expect(runtimeSource.contains("ghostty_surface_preedit"))
        #expect(runtimeSource.contains("private func ghosttyInputAction"))
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
