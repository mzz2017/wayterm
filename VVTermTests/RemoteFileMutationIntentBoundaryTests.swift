import Foundation
import Testing

// Test Context:
// These tests protect RemoteFiles UI/Application ownership for user-triggered
// browser mutations such as create folder, rename, move, delete, and permission
// changes. The UI may adapt inputs and present errors, but the application
// store must own the lifecycle of mutation tasks so later tests can await them
// and failures remain ordered. The test inspects source placement only; update
// it only when mutation request ownership intentionally moves to another
// application-layer owner.
@Suite
struct RemoteFileMutationIntentBoundaryTests {
    @Test
    func browserScreenDelegatesMutationTaskOwnershipToStore() throws {
        // Given the shared RemoteFiles browser SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )

        // Then the generic browser mutation helper must send intent to the
        // application store instead of wrapping arbitrary mutations in
        // fire-and-forget UI-owned tasks.
        #expect(
            source.contains("browser.requestMutation("),
            "RemoteFileBrowserScreen.performOperation should delegate mutation task ownership to RemoteFileBrowserStore."
        )
        #expect(
            !source.contains("Task {\n            do {\n                try await operation()"),
            "RemoteFileBrowserScreen should not own the Void mutation Task in performOperation."
        )
        #expect(
            !source.contains("Task {\n            do {\n                let result = try await operation()"),
            "RemoteFileBrowserScreen should not own the result mutation Task in performOperation."
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
