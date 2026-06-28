import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty input ownership. The UIKit
// terminal view may route UI events, but raw surface input access should be
// executed by TerminalIOSSurfaceInputRuntime behind TerminalIOSSurfaceOwner,
// while direct hardware key FFI, visible IME preedit state, IME proxy
// focus/resign state, toolbar key routing, and committed-text routing policy
// should stay in TerminalIOSInputRuntime. Update these tests only if those
// responsibilities intentionally move to another non-view owner.

@Suite(.serialized)
struct GhosttyIOSInputRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesHardwareKeyAndPreeditRuntimeToInputOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/TerminalIOSInputRuntime.swift")
        )
        let hardwareKeyboardSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+HardwareKeyboard+iOS.swift")
        )
        let keyboardAccessorySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+KeyboardAccessory+iOS.swift")
        )
        let terminalInputSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TerminalInput+iOS.swift")
        )
        let textInputSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+TextInput+iOS.swift")
        )
        let imeProxySource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+IMEProxy+iOS.swift")
        )
        let ownerSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )
        let surfaceInputSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceInputRuntime.swift")
        )

        // Given the iOS terminal view routes hardware keys and IME preedit.
        #expect(viewSource.contains("let inputRuntime = TerminalIOSInputRuntime()"))
        #expect(hardwareKeyboardSource.contains("surfaceOwner.sendDirectHardwareKeyEvent"))
        #expect(terminalInputSource.contains("surfaceOwner.syncVisiblePreedit"))
        #expect(imeProxySource.contains("inputRuntime.canResignIMEProxy"))
        #expect(hardwareKeyboardSource.contains("inputRuntime.suppressUnexpectedIMEProxyResign"))
        #expect(viewSource.contains("inputRuntime.performProgrammaticIMEProxyResign"))
        #expect(hardwareKeyboardSource.contains("inputRuntime.terminalKey"))
        #expect(terminalInputSource.contains("inputRuntime.handleIMEInsertText"))
        #expect(terminalInputSource.contains("inputRuntime.handleSpecialKey"))
        #expect(terminalInputSource.contains("inputRuntime.handleControlKey"))
        #expect(textInputSource.contains("surfaceOwner.sendKeyEvent(interpretedEvent)"))
        #expect(imeProxySource.contains("inputRuntime.handleTerminalTextInputEffects"))
        #expect(imeProxySource.contains("surfaceOwner.imePoint(using: inputRuntime)"))
        #expect(keyboardAccessorySource.contains("inputRuntime.handleToolbarKey"))
        #expect(keyboardAccessorySource.contains("inputRuntime.handleToolbarCustomAction"))

        // Then the main UIKit view does not directly own those C/FFI calls,
        // visible preedit state, or the Ghostty action conversion helper.
        #expect(!viewSource.contains("ghostty_surface_key"))
        #expect(!viewSource.contains("ghostty_surface_preedit"))
        #expect(!viewSource.contains("ghostty_surface_ime_point"))
        #expect(!viewSource.contains("private func ghosttyInputAction"))
        #expect(!viewSource.contains("private func sendToolbarKey"))
        #expect(!viewSource.contains("private func sendToolbarGhosttyKey"))
        #expect(!viewSource.contains("private func sendToolbarControlShortcut"))
        #expect(!viewSource.contains("private func handleToolbarCustomAction"))
        #expect(!viewSource.contains("private func ghosttyKeyMapping"))
        #expect(!viewSource.contains("inputRuntime.ghosttyKeyMapping"))
        #expect(!viewSource.contains("private func terminalKey(forKeyCommandInput"))
        #expect(!viewSource.contains("private func imeProxyGhosttyModifiers"))
        #expect(!viewSource.contains("private func executeIMEInsertRoute"))
        #expect(!viewSource.contains("private func sendRemainingIMEInsertTextIfNeeded"))
        #expect(!viewSource.contains("inputRuntime.imeInsertRoute"))
        #expect(!viewSource.contains("private func sendTerminalInputText"))
        #expect(!viewSource.contains("private func sendRawTerminalInputText"))
        #expect(!viewSource.contains("private func applyTerminalTextInputEffects"))
        #expect(!viewSource.contains("inputRuntime.handleTerminalInputText"))
        #expect(!viewSource.contains("case let .sendBackspaces"))
        #expect(!viewSource.contains("case let .moveCursor"))
        #expect(!viewSource.contains("replacingOccurrences(of: \"\\r\\n\", with: \"\\r\")"))
        #expect(!viewSource.contains("TerminalControlKey.controlCharacter"))
        #expect(!viewSource.contains("TerminalSpecialKeySequence.escapeSequence"))
        #expect(!viewSource.contains("private var renderedIMEPreeditText"))
        #expect(!viewSource.contains("private func shouldDisplayVisiblePreedit"))
        #expect(!viewSource.contains("private var allowIMEProxyProgrammaticResign"))
        #expect(!viewSource.contains("private var suppressUnexpectedIMEProxyResignUntil"))
        #expect(!viewSource.contains("private var shouldSuppressUnexpectedIMEProxyResign"))
        #expect(!hardwareKeyboardSource.contains("unsafeCValue"))
        #expect(!terminalInputSource.contains("unsafeCValue"))
        #expect(!imeProxySource.contains("unsafeCValue"))
        #expect(!hardwareKeyboardSource.contains("surface.sendKeyEvent"))
        #expect(!terminalInputSource.contains("surface.sendKeyEvent"))
        #expect(!textInputSource.contains("surface.sendKeyEvent"))
        #expect(!textInputSource.contains("guard canRouteTerminalInput, let surface"))

        #expect(runtimeSource.contains("final class TerminalIOSInputRuntime"))
        #expect(runtimeSource.contains("private var renderedPreeditText"))
        #expect(runtimeSource.contains("private var isIMEProxyProgrammaticResignAllowed"))
        #expect(runtimeSource.contains("private var suppressUnexpectedIMEProxyResignUntil"))
        #expect(runtimeSource.contains("func sendDirectHardwareKeyEvent"))
        #expect(runtimeSource.contains("func sendKeyPress("))
        #expect(runtimeSource.contains("func sendModifiedKey("))
        #expect(runtimeSource.contains("func syncVisiblePreedit"))
        #expect(runtimeSource.contains("func syncPreedit"))
        #expect(runtimeSource.contains("func imePoint(surface: ghostty_surface_t)"))
        #expect(runtimeSource.contains("func canResignIMEProxy"))
        #expect(runtimeSource.contains("func suppressUnexpectedIMEProxyResign"))
        #expect(runtimeSource.contains("func performProgrammaticIMEProxyResign"))
        #expect(runtimeSource.contains("func handleToolbarKey"))
        #expect(runtimeSource.contains("func handleToolbarCustomAction"))
        #expect(runtimeSource.contains("func ghosttyKeyMapping"))
        #expect(runtimeSource.contains("func terminalKey(forKeyCommandInput"))
        #expect(runtimeSource.contains("func ghosttyModifiers"))
        #expect(runtimeSource.contains("func imeInsertRoute"))
        #expect(runtimeSource.contains("func handleIMEInsertText"))
        #expect(runtimeSource.contains("func handleSpecialKey"))
        #expect(runtimeSource.contains("func handleControlKey"))
        #expect(runtimeSource.contains("func handleControlShortcut"))
        #expect(runtimeSource.contains("func handleTerminalInputText"))
        #expect(runtimeSource.contains("func handleTerminalTextInputEffects"))
        #expect(runtimeSource.contains("struct TerminalTextInputExecutionContext"))
        #expect(runtimeSource.contains("struct TerminalTextInputEffectExecutionContext"))
        #expect(runtimeSource.contains("replacingOccurrences(of: \"\\r\\n\", with: \"\\r\")"))
        #expect(runtimeSource.contains("private func executeIMEInsertRoute"))
        #expect(runtimeSource.contains("struct IMEInsertExecutionContext"))
        #expect(runtimeSource.contains("TerminalControlKey.controlCharacter"))
        #expect(runtimeSource.contains("TerminalSpecialKeySequence.escapeSequence"))
        #expect(runtimeSource.contains("private func sendToolbarKey"))
        #expect(runtimeSource.contains("private func sendToolbarGhosttyKey"))
        #expect(runtimeSource.contains("private func sendToolbarControlShortcut"))
        #expect(runtimeSource.contains("ghostty_surface_key"))
        #expect(runtimeSource.contains("ghostty_surface_preedit"))
        #expect(runtimeSource.contains("ghostty_surface_ime_point"))
        #expect(runtimeSource.contains("private func ghosttyInputAction"))
        #expect(surfaceInputSource.contains("final class TerminalIOSSurfaceInputRuntime"))
        #expect(surfaceInputSource.contains("func sendText("))
        #expect(surfaceInputSource.contains("func perform(action:"))
        #expect(surfaceInputSource.contains("func sendKeyPress("))
        #expect(surfaceInputSource.contains("func sendModifiedKey("))
        #expect(surfaceInputSource.contains("func sendKeyEvent("))
        #expect(surfaceInputSource.contains("func sendMousePosition("))
        #expect(surfaceInputSource.contains("func sendMouseButton("))
        #expect(surfaceInputSource.contains("func sendMouseScroll("))
        #expect(surfaceInputSource.contains("func sendDirectHardwareKeyEvent("))
        #expect(surfaceInputSource.contains("func syncVisiblePreedit("))
        #expect(surfaceInputSource.contains("func imePoint("))
        #expect(surfaceInputSource.contains("surface?.sendText"))
        #expect(surfaceInputSource.contains("surface?.perform"))
        #expect(surfaceInputSource.contains("surface?.sendKeyEvent"))
        #expect(surfaceInputSource.contains("surface?.sendMousePos"))
        #expect(surfaceInputSource.contains("surface?.sendMouseButton"))
        #expect(surfaceInputSource.contains("surface?.sendMouseScroll"))
        #expect(ownerSource.contains("func sendDirectHardwareKeyEvent("))
        #expect(ownerSource.contains("func sendKeyPress("))
        #expect(ownerSource.contains("func sendKeyEvent("))
        #expect(ownerSource.contains("func sendModifiedKey("))
        #expect(ownerSource.contains("func syncVisiblePreedit("))
        #expect(ownerSource.contains("func imePoint(using inputRuntime: TerminalIOSInputRuntime)"))
        #expect(ownerSource.contains("private let surfaceInputRuntime = TerminalIOSSurfaceInputRuntime()"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendText"))
        #expect(ownerSource.contains("surfaceInputRuntime.perform"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendKeyPress"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendModifiedKey"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendKeyEvent"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendMousePosition"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendMouseButton"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendMouseScroll"))
        #expect(ownerSource.contains("surfaceInputRuntime.sendDirectHardwareKeyEvent"))
        #expect(ownerSource.contains("surfaceInputRuntime.syncVisiblePreedit"))
        #expect(ownerSource.contains("surfaceInputRuntime.imePoint"))
        #expect(
            !ownerSource.contains("action: .press"),
            "TerminalIOSSurfaceOwner should delegate key-event sequencing to TerminalIOSInputRuntime."
        )
        #expect(
            !ownerSource.contains("action: .release"),
            "TerminalIOSSurfaceOwner should delegate key-event sequencing to TerminalIOSInputRuntime."
        )
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
