import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These boundary tests protect the TerminalSessions shell-runner callback
// boundary. Runtime managers may start background shell tasks, but those tasks
// must receive explicit sendable handles for UI surfaces and process-exit
// callbacks instead of capturing GhosttyTerminalView or unqualified UI closures
// directly. This keeps the ownership rule testable while Swift 6 tightens
// actor/sendability checks.

struct TerminalRuntimeCallbackBoundaryTests {
    @Test
    func runtimeManagersPassSendableRunnerHandlesIntoDetachedShellTasks() throws {
        let root = try sourceRoot()
        let sessionRuntimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Runtime.swift")
        )
        let tabRuntimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift")
        )
        let runnerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift")
        )

        #expect(runnerSource.contains("terminal: TerminalConnectionSurfaceHandle"))
        #expect(runnerSource.contains("onProcessExit: TerminalProcessExitHandler"))

        #expect(sessionRuntimeSource.contains("TerminalConnectionSurfaceHandle("))
        #expect(sessionRuntimeSource.contains("terminalSurfaceRegistry.surface(for: .session(sessionId))"))
        #expect(sessionRuntimeSource.contains("TerminalProcessExitHandler(action: runtime.onProcessExit)"))
        #expect(tabRuntimeSource.contains("TerminalConnectionSurfaceHandle("))
        #expect(tabRuntimeSource.contains("terminalSurfaceRegistry.surface(for: .pane(paneId))"))
        #expect(tabRuntimeSource.contains("TerminalProcessExitHandler(action: runtime.onProcessExit)"))

        #expect(!sessionRuntimeSource.contains("Task.detached(priority: .userInitiated) { [weak self, weak terminal]"))
        #expect(!tabRuntimeSource.contains("Task.detached(priority: .userInitiated) { [weak self, weak terminal]"))
        #expect(!sessionRuntimeSource.contains("let onProcessExit = runtime.onProcessExit"))
        #expect(!tabRuntimeSource.contains("let onProcessExit = runtime.onProcessExit"))
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
}

private enum SourceRootError: Error {
    case notFound
}
