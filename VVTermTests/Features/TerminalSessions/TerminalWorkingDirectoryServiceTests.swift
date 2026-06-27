import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect TerminalSessions working-directory restore ownership.
// Runtime managers decide whether a pane/session should restore a path; the
// service owns remote shell payload generation and write orchestration. Update
// only when that Application service boundary intentionally changes.

struct TerminalWorkingDirectoryServiceTests {
    @Test
    func payloadUsesRemoteShellDirectoryChangeCommand() {
        // Given a POSIX remote shell and a path that needs shell quoting.
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "zsh"),
            activeShellName: "zsh",
            powerShellExecutable: nil
        )

        // When the working-directory service builds the restore payload.
        let payload = TerminalWorkingDirectoryService.directoryChangePayload(
            for: "/var/www/app's",
            environment: environment
        )

        // Then it emits the same bytes the terminal should write after shell startup.
        #expect(payload == Data("cd -- '/var/www/app'\\''s'\n".utf8))
    }

    @Test
    func payloadSkipsUnknownShellProfiles() {
        // Given a remote shell profile whose directory-change syntax is unknown.
        let environment = RemoteEnvironment(
            platform: .unknown,
            shellProfile: .unknown(shellName: nil),
            activeShellName: nil,
            powerShellExecutable: nil
        )

        // When the working-directory service is asked for a restore payload.
        let payload = TerminalWorkingDirectoryService.directoryChangePayload(
            for: "/srv/app",
            environment: environment
        )

        // Then no shell input is produced instead of sending an ambiguous newline.
        #expect(payload == nil)
    }

    @Test
    func runtimeManagersDelegateWorkingDirectoryRestoreToService() throws {
        let root = try sourceRoot()
        let serviceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalWorkingDirectoryService.swift")
        )
        let sessionRuntimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Runtime.swift")
        )
        let tabRuntimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift")
        )

        // Given shell startup lives in the runtime manager extensions.
        #expect(sessionRuntimeSource.contains("TerminalConnectionRunner.run"))
        #expect(tabRuntimeSource.contains("TerminalConnectionRunner.run"))

        // Then runtime managers delegate restore payload/write behavior to the service.
        #expect(serviceSource.contains("struct TerminalWorkingDirectoryService"))
        #expect(serviceSource.contains("protocol TerminalWorkingDirectoryApplying"))
        #expect(serviceSource.contains("directoryChangePayload"))
        #expect(serviceSource.contains("RemoteTerminalBootstrap.directoryChangeCommand"))
        #expect(sessionRuntimeSource.contains("workingDirectoryService.apply"))
        #expect(tabRuntimeSource.contains("workingDirectoryService.apply"))
        #expect(!sessionRuntimeSource.contains("TerminalWorkingDirectoryService.shared"))
        #expect(!tabRuntimeSource.contains("TerminalWorkingDirectoryService.shared"))
        #expect(!sessionRuntimeSource.contains("RemoteTerminalBootstrap.directoryChangeCommand"))
        #expect(!tabRuntimeSource.contains("RemoteTerminalBootstrap.directoryChangeCommand"))
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
