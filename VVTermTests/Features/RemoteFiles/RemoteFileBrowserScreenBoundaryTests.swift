import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFiles feature ownership. SwiftUI
// screens should present state and send user intent; feature policy such as
// remote name/path validation belongs in Application or Domain code. Update
// only when this ownership intentionally moves.

struct RemoteFileBrowserScreenBoundaryTests {
    @Test
    func screenDoesNotOwnRemoteNameOrPathValidationPolicy() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let transferSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileTransferCoordinator.swift")
        )

        // Given the RemoteFiles SwiftUI screen source.
        #expect(
            !screenSource.contains("func validatedRemoteName"),
            "RemoteFileBrowserScreen should not own remote name validation policy."
        )
        #expect(
            !screenSource.contains("func validatedRemoteDirectoryPath"),
            "RemoteFileBrowserScreen should not own remote directory path validation policy."
        )

        // Then the Application layer owns the validation entry points used by UI intent handlers.
        #expect(transferSource.contains("func validatedRemoteName"))
        #expect(transferSource.contains("func validatedRemoteDirectoryPath"))
    }

    @Test
    func screenDoesNotOwnDownloadTemporaryURLCreation() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let storageSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/RemoteFileTemporaryStorage.swift")
        )

        // Given the RemoteFiles SwiftUI screen source.
        #expect(
            !screenSource.contains("func temporaryDownloadURL"),
            "RemoteFileBrowserScreen should not own temporary download URL creation."
        )

        // Then RemoteFiles infrastructure owns temporary download export paths.
        #expect(storageSource.contains("func makeDownloadExportFileURL"))
    }

    @Test
    func screenDoesNotOwnDragTemporaryURLCreation() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let storageSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/RemoteFileTemporaryStorage.swift")
        )

        // Given the RemoteFiles SwiftUI screen source.
        #expect(
            !screenSource.contains("func temporaryDragExportURL"),
            "RemoteFileBrowserScreen should not own drag export URL creation."
        )
        #expect(
            !screenSource.contains("func temporaryDragExportDirectory"),
            "RemoteFileBrowserScreen should not own drag export directory creation."
        )

        // Then RemoteFiles infrastructure owns temporary drag export paths.
        #expect(storageSource.contains("func makeDragExportFileURL"))
    }

    @Test
    func platformSupportDoesNotOwnMacOSTableViewImplementation() throws {
        let root = try sourceRoot()
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserSupport.swift")
        )
        let tableSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserMacTableView.swift")
        )

        // Given the platform support source file.
        #expect(
            !supportSource.contains("struct MacOSRemoteFileTableView"),
            "RemoteFileBrowserSupport should not own the large macOS table view implementation."
        )

        // Then the macOS table view lives in its own platform UI file.
        #expect(tableSource.contains("struct MacOSRemoteFileTableView"))
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
