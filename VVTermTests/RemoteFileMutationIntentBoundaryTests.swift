import Foundation
import Testing

// Test Context:
// These tests protect RemoteFiles UI/Application ownership for user-triggered
// browser mutations and transfers such as create folder, rename, move, delete,
// permission changes, uploads, downloads, drops, and file promises. The UI may
// adapt inputs and present errors, but the application store must own the
// lifecycle of mutation/transfer tasks so later tests can await them and
// failures remain ordered. The test inspects source placement only; update it
// only when request ownership intentionally moves to another application-layer
// owner.
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

    @Test
    func previewTextSaveDelegatesTaskOwnershipToStore() throws {
        // Given shared, macOS, and iOS RemoteFiles preview UI sources.
        let root = try sourceRoot()
        let previewSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Preview/RemoteFilePreviewViews.swift")
        )
        let platformSources = try [
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift",
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserIOSScreen.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Then the preview view must send save intent synchronously, and the
        // platform containers must delegate the actual save task to the
        // application store.
        #expect(
            !previewSource.contains("Task {\n                        await saveEditedText(for: entry)"),
            "RemoteFileInspectorView should not own edited preview save Task state."
        )
        #expect(
            !previewSource.contains("private func saveEditedText(for entry: RemoteFileEntry) async"),
            "Edited preview save helper should not be async if the view is only sending intent."
        )
        #expect(
            platformSources.contains("browser.requestTextPreviewSave("),
            "Preview save UI should delegate task ownership to RemoteFileBrowserStore.requestTextPreviewSave."
        )
        #expect(
            !platformSources.contains("try await browser.saveTextPreview"),
            "Platform preview UI should not call the async preview-save implementation directly."
        )
    }

    @Test
    func transferAndDropDelegatesTaskOwnershipToStore() throws {
        // Given shared RemoteFiles browser UI plus the macOS file-promise
        // support source.
        let root = try sourceRoot()
        let browserSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let macOSSupportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserSupport.swift")
        )

        // Then transfer UI should send intent to the application store instead
        // of owning transfer/drop/file-promise async Tasks.
        #expect(
            browserSource.contains("browser.requestTransfer("),
            "RemoteFileBrowserScreen.performTransfer should delegate transfer task ownership to RemoteFileBrowserStore."
        )
        #expect(
            !browserSource.contains("Task {\n            do {\n                try await operation { progress in"),
            "RemoteFileBrowserScreen should not own the transfer Task in performTransfer."
        )
        #expect(
            !browserSource.contains("func beginUploadFlow(urls: [URL], to destinationPath: String, initialMessage: String) {\n        Task {"),
            "RemoteFileBrowserScreen should not own the upload planning Task before starting a transfer request."
        )
        #expect(
            !browserSource.contains("Task {\n                do {\n                    let temporaryURL = try preparedTemporaryURL.get()"),
            "Remote drag file representations should not download through a UI-owned Task."
        )
        #expect(
            !macOSSupportSource.contains("Task { @MainActor in\n                do {\n                    try await export(entry, url)"),
            "FilePromiseDelegate should complete through an application-owned request instead of starting its own Task."
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
