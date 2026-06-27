import Foundation
import Testing

// Test Context:
// These source-boundary tests protect SSHClient superfile control. SSHClient
// owns high-level connection behavior; shared error models should live in
// dedicated Core/SSH support files so future transport changes do not expand
// the client superfile. Update only when this ownership intentionally moves.

@Suite(.serialized)
struct SSHClientSuperfileBoundaryTests {
    @Test
    func sshErrorLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let errorSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHError.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("enum SSHError"),
            "SSHClient.swift should not own the shared SSH error model."
        )

        // Then SSH errors have a dedicated Core/SSH file with descriptions and retry policy.
        #expect(errorSource.contains("enum SSHError"))
        #expect(errorSource.contains("LocalizedError"))
        #expect(errorSource.contains("isRetryable"))
    }

    @Test
    func atomicSocketLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let socketSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/AtomicSocket.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("final class AtomicSocket"),
            "SSHClient.swift should not own the shared atomic socket wrapper."
        )

        // Then socket abort storage has a dedicated Core/SSH file.
        #expect(socketSource.contains("final class AtomicSocket"))
        #expect(socketSource.contains("closeImmediately"))
    }

    @Test
    func sessionConfigLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let configSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHSessionConfig.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("struct SSHSessionConfig"),
            "SSHClient.swift should not own the shared SSH session configuration value."
        )

        // Then session connection configuration has a dedicated Core/SSH file.
        #expect(configSource.contains("struct SSHSessionConfig"))
        #expect(configSource.contains("connectionTimeout"))
        #expect(configSource.contains("keepAliveInterval"))
    }

    @Test
    func clientSupportValuesLiveOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let shellHandleSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/ShellHandle.swift")
        )
        let uploadStrategySource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHUploadStrategy.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("struct ShellHandle"),
            "SSHClient.swift should not own the shell stream handle value."
        )
        #expect(
            !clientSource.contains("enum SSHUploadStrategy"),
            "SSHClient.swift should not own the upload policy value."
        )

        // Then shared client support values have dedicated Core/SSH files.
        #expect(shellHandleSource.contains("struct ShellHandle"))
        #expect(shellHandleSource.contains("ShellTransport"))
        #expect(uploadStrategySource.contains("enum SSHUploadStrategy"))
        #expect(uploadStrategySource.contains("execPreferred"))
    }

    @Test
    func connectionOperationServiceLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let serviceSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHConnectionOperationService.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("actor SSHConnectionOperationService"),
            "SSHClient.swift should not own the reusable SSH connection operation service."
        )

        // Then reusable connection operation orchestration has a dedicated Core/SSH file.
        #expect(serviceSource.contains("actor SSHConnectionOperationService"))
        #expect(serviceSource.contains("runWithConnection"))
        #expect(serviceSource.contains("withTemporaryConnection"))
    }

    @Test
    func keyboardInteractiveAuthHelperLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let authSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHKeyboardInteractiveAuth.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("final class KeyboardInteractiveContext"),
            "SSHClient.swift should not own the libssh2 keyboard-interactive auth context."
        )
        #expect(
            !clientSource.contains("let kbdintCallback"),
            "SSHClient.swift should not own the libssh2 keyboard-interactive auth callback."
        )

        // Then keyboard-interactive auth support has a dedicated Core/SSH file.
        #expect(authSource.contains("final class KeyboardInteractiveContext"))
        #expect(authSource.contains("keyboardInteractivePassword"))
        #expect(authSource.contains("kbdintCallback"))
    }

    @Test
    func channelCleanupTaskRegistryLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let registrySource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHChannelCleanupTaskRegistry.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("final class SSHChannelCleanupTaskRegistry"),
            "SSHClient.swift should not own SSHSession channel cleanup task tracking."
        )

        // Then session cleanup task tracking has a dedicated Core/SSH file.
        #expect(registrySource.contains("final class SSHChannelCleanupTaskRegistry"))
        #expect(registrySource.contains("Task.detached"))
        #expect(registrySource.contains("func tasks()"))
    }

    @Test
    func abortStateLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let abortStateSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClientAbortState.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("final class SSHClientAbortState"),
            "SSHClient.swift should not own abort synchronization state."
        )

        // Then connection abort state has a dedicated Core/SSH file.
        #expect(abortStateSource.contains("final class SSHClientAbortState"))
        #expect(abortStateSource.contains("setSessionForAbort"))
        #expect(abortStateSource.contains("func abort()"))
    }

    @Test
    func moshTeardownTaskRegistryLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let registrySource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHMoshTeardownTaskRegistry.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("final class SSHMoshTeardownTaskRegistry"),
            "SSHClient.swift should not own Mosh teardown task tracking."
        )

        // Then Mosh stream teardown tracking has a dedicated Core/SSH file.
        #expect(registrySource.contains("final class SSHMoshTeardownTaskRegistry"))
        #expect(registrySource.contains("Task.detached"))
        #expect(registrySource.contains("func tasks()"))
    }

    @Test
    func remoteFileErrorMapperLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let mapperSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHRemoteFileErrorMapper.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("case UInt(LIBSSH2_FX_PERMISSION_DENIED)"),
            "SSHClient.swift should not own SFTP error-code to domain-error mapping."
        )
        #expect(
            !clientSource.contains("case UInt(LIBSSH2_FX_LINK_LOOP)"),
            "SSHClient.swift should not own SFTP link-loop error mapping."
        )

        // Then SFTP remote-file error mapping has a dedicated Core/SSH file.
        #expect(mapperSource.contains("enum SSHRemoteFileErrorMapper"))
        #expect(mapperSource.contains("LIBSSH2_FX_PERMISSION_DENIED"))
        #expect(mapperSource.contains("func remoteFileError"))
    }

    @Test
    func sessionActorLivesOutsideSSHClientFile() throws {
        let root = try sourceRoot()
        let clientSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift")
        )
        let sessionSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHSession.swift")
        )
        let channelSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/SSHSession+Channels.swift")
        )

        // Given the SSH client superfile source.
        #expect(
            !clientSource.contains("nonisolated actor SSHSession"),
            "SSHClient.swift should not own the libssh2 session lifecycle actor."
        )

        // Then libssh2 session lifecycle has a dedicated Core/SSH owner file.
        #expect(sessionSource.contains("nonisolated actor SSHSession"))
        #expect(sessionSource.contains("func connect() async throws"))
        #expect(sessionSource.contains("func disconnect() async"))
        #expect(!sessionSource.contains("func startShell"))
        #expect(channelSource.contains("func startShell"))
        #expect(channelSource.contains("func execute(_ command: String) async throws -> String"))
        #expect(
            sessionSource.split(separator: "\n", omittingEmptySubsequences: false).count < 1_200,
            "SSHSession.swift should not become a replacement superfile."
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
