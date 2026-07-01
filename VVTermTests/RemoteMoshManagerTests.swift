import Foundation
import Testing
import MoshBootstrap
@testable import VVTerm

// Test Context:
// These tests protect RemoteMoshManager command construction/output parsing and
// SSHClient's mosh stream teardown ownership without starting mosh or opening a
// network connection. Fakes model command executor responses; source-boundary
// checks protect that SSHClient owns mosh stream/teardown tasks. Update only
// when supported mosh bootstrap behavior changes or mosh runtime ownership
// intentionally moves to an equivalent SSH infrastructure owner.

struct RemoteMoshManagerTests {
    @Test
    func sshClientMoshStreamTeardownIsTrackedByClientOwner() throws {
        // Given SSHClient owns MoshClientSession runtimes and host-op stream
        // delivery for mosh-backed terminal shells.
        let clientSource = try source(at: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift"))
        let moshRuntimeSource = try source(
            at: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHMoshShellRuntime.swift")
        )
        let moshSource = try slice(
            startingAt: "    private func startMoshShell(",
            endingBefore: "    nonisolated static func runWithTimeout",
            in: clientSource
        )
        let disconnectSource = try slice(
            startingAt: "    func disconnect() async {",
            endingBefore: "    // MARK: - Command Execution",
            in: clientSource
        )

        // Then the runtime must own the stream task, synchronous stream
        // termination must register teardown with SSHClient, and disconnect
        // must await tracked mosh teardown before completing.
        #expect(
            moshRuntimeSource.contains("setStreamTask")
                && moshRuntimeSource.contains("cancelStreamTask")
                && moshRuntimeSource.contains("clearStreamTask"),
            "SSHMoshShellRuntime should own, cancel, and clear the host-op stream task."
        )
        #expect(
            moshSource.contains("runtime.clearStreamTask()"),
            "Mosh stream natural completion should clear stream ownership before closeShell cleanup."
        )
        #expect(
            clientSource.contains("trackMoshTeardownTask") && clientSource.contains("waitForMoshTeardownTasks"),
            "SSHClient should expose private mosh teardown tracking helpers."
        )
        #expect(
            moshSource.contains("trackMoshTeardownTask"),
            "Mosh stream termination should register close/stop work with the SSHClient owner."
        )
        #expect(
            !moshSource.contains("\n                Task { [weak self] in\n                    await self?.closeShell(shellId)"),
            "Mosh stream termination must not launch an untracked closeShell task."
        )
        #expect(
            disconnectSource.contains("await waitForMoshTeardownTasks()"),
            "SSHClient.disconnect should await tracked mosh teardown before reporting disconnect complete."
        )
    }

    @Test
    func parseValidMoshConnectOutput() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let output = """
        MOSH CONNECT 60001 \(key)
        mosh-server (mosh 1.4.0) [pid=12345]
        """

        let info = try RemoteMoshManager.shared.parseConnectInfo(from: output)
        #expect(info.port == 60001)
        #expect(info.key == key)
    }

    @Test
    func parseMissingServerMapsToTypedSSHError() {
        do {
            _ = try RemoteMoshManager.shared.parseConnectInfo(from: "mosh-server: command not found")
            Issue.record("Expected moshServerMissing error")
        } catch let error as SSHError {
            guard case .moshServerMissing = error else {
                Issue.record("Unexpected SSHError: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func parseMalformedOutputMapsToBootstrapError() {
        do {
            _ = try RemoteMoshManager.shared.parseConnectInfo(from: "MOSH CONNECT")
            Issue.record("Expected moshBootstrapFailed error")
        } catch let error as SSHError {
            guard case .moshBootstrapFailed = error else {
                Issue.record("Unexpected SSHError: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func installScriptContainsSupportedPackageManagers() {
        let script = RemoteMoshManager.shared.installScript()
        #expect(script.contains("apt-get"))
        #expect(script.contains("dnf"))
        #expect(script.contains("brew"))
        #expect(script.contains("mosh-server"))
    }

    @Test
    func utf8LocaleExportScriptSetsUtf8LocaleVars() {
        let script = RemoteMoshManager.shared.utf8LocaleExportScript()
        #expect(script.contains("locale -a"))
        #expect(script.contains("locale charmap"))
        #expect(script.contains("C.UTF-8"))
        #expect(script.contains("vvterm_validate_utf8_locale"))
        #expect(script.contains("[Uu][Tt][Ff]*8"))
        #expect(script.contains("VVTERM_LOCALE_CANDIDATE"))
        #expect(script.contains("awk") == false)
        #expect(script.contains("IGNORECASE") == false)
        #expect(script.contains("export LANG="))
        #expect(script.contains("export LC_ALL="))
        #expect(script.contains("export LC_CTYPE="))
    }

    @Test
    func moshChildStartupScriptAlsoSetsUtf8Locale() {
        let script = RemoteMoshManager.shared.moshChildStartupScript(
            startCommand: "echo hi",
            terminalType: .xtermGhostty
        )

        #expect(script.contains("VVTERM_UTF8_LOCALE"))
        #expect(script.contains("TERM='xterm-ghostty'"))
        #expect(script.contains("echo hi"))
    }

    @Test
    func localeBootstrapErrorMessageIsSpecific() {
        let error = RemoteMoshManager.shared.mapInvalidConnectLine(
            output: "mosh-server needs a UTF-8 native locale to run."
        )

        switch error {
        case .moshBootstrapFailed(let message):
            #expect(message.contains("UTF-8 locale"))
            #expect(message.contains("mosh-server needs a UTF-8 native locale"))
        default:
            Issue.record("Expected moshBootstrapFailed for invalid connect line")
        }
    }

    @Test
    func moshStartupScriptContainsDefaultShell() {
        let script = RemoteTerminalBootstrap.moshStartupScript(startCommand: nil)
        #expect(script.contains("$SHELL"))
        #expect(script.contains("TERM='xterm-256color'"))
    }

    @Test
    func moshStartupScriptUsesResolvedTerminalTypeWhenProvided() {
        let script = RemoteTerminalBootstrap.moshStartupScript(
            startCommand: "echo hi",
            terminalType: .xtermGhostty
        )
        #expect(script.contains("TERM='xterm-ghostty'"))
        #expect(script.contains("echo hi"))
    }

    @Test
    func mapBootstrapPermissionDeniedProducesReadableSSHError() {
        let mapped = RemoteMoshManager.shared.mapBootstrapError(.permissionDenied)
        switch mapped {
        case .moshBootstrapFailed(let message):
            #expect(message.contains("Permission denied"))
        default:
            Issue.record("Expected moshBootstrapFailed for permissionDenied")
        }
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

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private enum SourceRootError: Error {
        case notFound
    }

    private enum SourceSliceError: Error {
        case notFound
    }
}
