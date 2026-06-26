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
