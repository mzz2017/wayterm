import Foundation
import Testing

// Test Context:
// Protects ownership of iOS hardware-key repeat. The UIKit view may decide
// when to start/stop repeat, but the timer and repeating key state must remain
// in TerminalIOSKeyRepeatRuntime so view teardown can release one stable owner.
// Update this test only when repeat timer ownership intentionally moves again.
@Suite(.serialized)
struct GhosttyIOSKeyRepeatRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesHardwareKeyRepeatTimerToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSKeyRepeatRuntime.swift")
        )

        #expect(viewSource.contains("private let keyRepeatRuntime = TerminalIOSKeyRepeatRuntime()"))
        #expect(viewSource.contains("keyRepeatRuntime.start"))
        #expect(viewSource.contains("keyRepeatRuntime.stop"))
        #expect(viewSource.contains("keyRepeatRuntime.isRepeating"))

        #expect(!viewSource.contains("private var keyRepeatTimer"))
        #expect(!viewSource.contains("private var repeatingHardwareKey"))
        #expect(!viewSource.contains("private var repeatingFallbackKey"))
        #expect(!viewSource.contains("private var repeatingFallbackModifiers"))
        #expect(!viewSource.contains("private var repeatingKeyCode"))
        #expect(!viewSource.contains("private func shouldRepeatHardwareKey"))

        #expect(runtimeSource.contains("final class TerminalIOSKeyRepeatRuntime"))
        #expect(runtimeSource.contains("private var timer"))
        #expect(runtimeSource.contains("private var repeatingHardwareKey"))
        #expect(runtimeSource.contains("func start"))
        #expect(runtimeSource.contains("func stop"))
        #expect(runtimeSource.contains("func isRepeating"))
        #expect(runtimeSource.contains("enum TerminalHardwareKeyRepeatPolicy"))
        #expect(runtimeSource.contains("static func shouldRepeat"))
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
