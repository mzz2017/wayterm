import Foundation
import Testing

// Test Context:
// These tests protect RemoteFiles UI/Application ownership for user-triggered
// browser mutations and transfers such as create folder, rename, move, delete,
// permission changes, uploads, downloads, drops, file promises, and preview
// loads. The UI may adapt inputs and present errors, but the application store
// must own the lifecycle of mutation/transfer/preview-load tasks so later tests
// can await them and failures remain ordered. The test inspects source
// placement only; update it only when request ownership intentionally moves to
// another application-layer owner.
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
            containsRegex(#"browser\.requestMutation\(\s*serverId:\s*server\.id"#, in: source),
            "RemoteFileBrowserScreen.performOperation should pass server identity so disconnect can cancel same-server mutations."
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
    func previewLoadDelegatesTaskOwnershipToStore() throws {
        // Given shared, macOS, and iOS RemoteFiles preview UI sources.
        let root = try sourceRoot()
        let previewSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Preview/RemoteFilePreviewViews.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let platformSources = try [
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift",
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserIOSScreen.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Then the preview view may send synchronous selection-driven intent,
        // but platform containers must delegate remote preview-load work to the
        // application store instead of creating UI-owned loadPreview tasks.
        #expect(
            previewSource.contains(".task(id: previewRequestID)"),
            "RemoteFileInspectorView may keep a SwiftUI task only to send synchronous onLoadPreview intent."
        )
        #expect(
            platformSources.contains("browser.requestPreviewLoad("),
            "Platform preview UI should delegate preview-load task ownership to RemoteFileBrowserStore.requestPreviewLoad."
        )
        #expect(
            !containsRegex(
                #"Task\s*(?:\([^)]*\))?\s*\{\s*await browser\.loadPreview"#,
                in: platformSources
            ),
            "Platform preview UI should not own Task wrappers around browser.loadPreview."
        )
        #expect(
            !platformSources.contains("await browser.loadPreview"),
            "Platform preview UI should not call the async preview-load implementation directly."
        )
        #expect(
            storeSource.contains("RemoteFilePreviewLoadCoordinator"),
            "RemoteFileBrowserStore should delegate preview-load request lifecycle to a focused application coordinator."
        )
        #expect(
            !storeSource.contains("previewLoadRequestByTab"),
            "RemoteFileBrowserStore should not own preview-load request coalescing dictionaries directly."
        )
    }

    @Test
    func transferAndDropDelegatesTaskOwnershipToStore() throws {
        // Given shared RemoteFiles browser UI plus the macOS file-promise
        // support source.
        let root = try sourceRoot()
        let transferSource = try [
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+TransferStatus.swift",
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+FileTransfers.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")
        let macOSScreenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift")
        )
        let macOSSupportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserSupport.swift")
        )

        // Then transfer UI should send intent to the application store instead
        // of owning transfer/drop/file-promise async Tasks.
        #expect(
            transferSource.contains("browser.requestTransfer("),
            "RemoteFileBrowserScreen transfer extensions should delegate transfer task ownership to RemoteFileBrowserStore."
        )
        #expect(
            containsRegex(#"browser\.requestTransfer\(\s*serverId:\s*server\.id"#, in: transferSource),
            "RemoteFileBrowserScreen transfer extensions should pass server identity so disconnect can cancel same-server transfers."
        )
        #expect(
            containsRegex(#"browser\.requestTransfer\(\s*serverId:\s*server\.id"#, in: macOSScreenSource),
            "RemoteFileBrowserMacScreen file export should pass server identity into the store-owned transfer request."
        )
        #expect(
            !transferSource.contains("Task {\n            do {\n                try await operation { progress in"),
            "RemoteFileBrowserScreen should not own the transfer Task in performTransfer."
        )
        #expect(
            !transferSource.contains("func beginUploadFlow(urls: [URL], to destinationPath: String, initialMessage: String) {\n        Task {"),
            "RemoteFileBrowserScreen should not own the upload planning Task before starting a transfer request."
        )
        #expect(
            !transferSource.contains("Task {\n                do {\n                    let temporaryURL = try preparedTemporaryURL.get()"),
            "Remote drag file representations should not download through a UI-owned Task."
        )
        #expect(
            transferSource.contains("progress.cancellationHandler"),
            "Remote drag file representation Progress cancellation should be wired to store-owned transfer cancellation."
        )
        #expect(
            transferSource.contains("browser.cancelTransferRequest"),
            "Remote drag file representation cancellation should send transfer-cancel intent to RemoteFileBrowserStore."
        )
        #expect(
            !macOSSupportSource.contains("Task { @MainActor in\n                do {\n                    try await export(entry, url)"),
            "FilePromiseDelegate should complete through an application-owned request instead of starting its own Task."
        )
    }

    @Test
    func moveDestinationFolderLoadingDelegatesTaskOwnershipToStore() throws {
        // Given shared RemoteFiles browser UI plus the move destination sheet.
        let root = try sourceRoot()
        let browserSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let sheetFactorySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+Sheets.swift")
        )
        let sheetSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Sheets/RemoteFileBrowserSheets.swift")
        )
        let moveSheet = try slice(
            startingAt: "struct RemoteFileMoveSheet: View",
            endingBefore: "\nstruct RemoteFileDeleteConfirmationSheet",
            in: sheetSource
        )
        let moveSheetFactory = try slice(
            startingAt: "func moveSheet(entry: RemoteFileEntry) -> some View",
            endingBefore: "\n    @ViewBuilder\n    func deleteSheet",
            in: sheetFactorySource
        )

        // Then the sheet may keep local presentation state, but remote folder
        // loading task lifetime belongs to the RemoteFiles application store.
        #expect(
            !browserSource.contains("func moveSheet(entry: RemoteFileEntry) -> some View"),
            "RemoteFileBrowserScreen.swift should not own move sheet presentation."
        )
        #expect(
            moveSheet.contains("onRequestDirectories"),
            "RemoteFileMoveSheet should expose synchronous directory-load intent instead of awaiting remote listing itself."
        )
        #expect(
            !moveSheet.contains("onLoadDirectories"),
            "RemoteFileMoveSheet should not keep an async remote directory-loading closure."
        )
        #expect(
            !moveSheet.contains("Task { await loadDirectories() }"),
            "RemoteFileMoveSheet Retry should not start a UI-owned load task."
        )
        #expect(
            !moveSheet.contains("try await onLoadDirectories"),
            "RemoteFileMoveSheet should not await remote directory listing directly."
        )
        #expect(
            moveSheet.contains("guard currentDirectory == requestedDirectory"),
            "RemoteFileMoveSheet should ignore stale directory-load callbacks after navigation changes."
        )
        #expect(
            moveSheetFactory.contains("browser.requestMoveDestinationLoad"),
            "RemoteFileBrowserScreen.moveSheet should delegate move destination loading to RemoteFileBrowserStore."
        )
        #expect(
            !moveSheetFactory.contains("try await fileBrowser.listDirectories"),
            "RemoteFileBrowserScreen.moveSheet should not pass direct async listDirectories work into the sheet."
        )
        #expect(
            storeSource.contains("RemoteFileMoveDestinationLoadCoordinator"),
            "RemoteFileBrowserStore should delegate move destination request lifecycle to a focused application coordinator."
        )
        #expect(
            !storeSource.contains("MoveDestinationLoadRequestKey"),
            "RemoteFileBrowserStore should not own move destination request coalescing dictionaries directly."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
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

    private func containsRegex(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private enum SourceRootError: Error {
        case notFound
    }

    private enum SourceSliceError: Error {
        case notFound
    }
}
