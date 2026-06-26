import Foundation
import Testing

// Test Context:
// These source-boundary tests protect Servers UI superfile control. ServerFormSheet
// is the add/edit form root; independent sheets and feature-specific presentation
// flows should stay in sibling files so the root form does not become the owner of
// every server-management workflow. Update these tests only when the Servers UI
// ownership boundary intentionally changes.
@Suite
struct ServerFormSuperfileBoundaryTests {
    @Test
    func serverFormSheetDoesNotOwnMoveServerSheet() throws {
        let root = try sourceRoot()
        let formSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )
        let moveSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/MoveServerSheet.swift")
        )

        // Given moving a server is a separate sheet workflow with its own
        // selection and save presentation state.
        #expect(
            !formSource.contains("struct MoveServerSheet"),
            "ServerFormSheet.swift should not own the move-server sheet workflow."
        )
        #expect(
            moveSource.contains("struct MoveServerSheet"),
            "MoveServerSheet.swift should own the move-server sheet workflow."
        )
        #expect(
            moveSource.contains("requestServerMove("),
            "MoveServerSheet should keep sending move intent through ServerManager."
        )
    }

    @Test
    func serverFormSheetDoesNotOwnTransportSelectionOrCredentialBuilder() throws {
        let root = try sourceRoot()
        let formSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerTransportSelection.swift")
        )
        let credentialBuilderSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerFormCredentialBuilder.swift")
        )

        // Given transport selection is UI support and credential assembly is
        // application-layer form orchestration, the root form should only call
        // into those collaborators.
        #expect(
            !formSource.contains("enum ServerTransportSelection"),
            "ServerFormSheet.swift should not own the transport selection support type."
        )
        #expect(
            !formSource.contains("struct ServerFormCredentialBuilder"),
            "ServerFormSheet.swift should not own credential assembly policy."
        )
        #expect(
            selectionSource.contains("enum ServerTransportSelection"),
            "ServerTransportSelection.swift should own transport selection UI support."
        )
        #expect(
            credentialBuilderSource.contains("struct ServerFormCredentialBuilder"),
            "Servers Application should own server form credential assembly."
        )
        #expect(
            credentialBuilderSource.contains("connectionMode: SSHConnectionMode"),
            "Credential assembly should depend on connection mode, not UI selection state."
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
