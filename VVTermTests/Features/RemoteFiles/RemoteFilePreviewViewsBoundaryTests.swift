import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFiles preview UI superfile control.
// RemoteFileInspectorView owns inspector composition and preview intent callbacks;
// media rendering/playback views live beside it so image/video details do not
// inflate the inspector root. Update these tests only when preview UI ownership
// intentionally changes.
@Suite
struct RemoteFilePreviewViewsBoundaryTests {
    @Test
    func inspectorDoesNotOwnMediaPreviewRenderingViews() throws {
        let root = try sourceRoot()
        let inspectorSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Preview/RemoteFilePreviewViews.swift")
        )
        let mediaSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Preview/RemoteFileMediaPreviewViews.swift")
        )

        // Given image/video preview rendering is a separate UI responsibility
        // from inspector composition.
        for typeName in [
            "PresentedMediaPreview",
            "RemoteFileImagePreview",
            "RemoteFileVideoPreview",
            "RemoteFileExpandedMediaPreview"
        ] {
            #expect(
                !inspectorSource.contains("struct \(typeName)"),
                "RemoteFilePreviewViews.swift should not define \(typeName)."
            )
            #expect(
                mediaSource.contains("struct \(typeName)"),
                "RemoteFileMediaPreviewViews.swift should define \(typeName)."
            )
        }

        #expect(
            !inspectorSource.contains("AVPlayer"),
            "RemoteFileInspectorView should not own media playback state."
        )
        #expect(
            mediaSource.contains("AVPlayer"),
            "RemoteFileMediaPreviewViews should own media playback state."
        )
    }

    @Test
    func inspectorDoesNotOwnMetadataAndActionRenderingViews() throws {
        let root = try sourceRoot()
        let inspectorSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Preview/RemoteFilePreviewViews.swift")
        )
        let metadataSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Preview/RemoteFileInspectorMetadataViews.swift")
        )

        // Given metadata and file action rendering is separate from preview
        // loading/editing state in the inspector root.
        for typeName in [
            "RemoteFileInspectorActions",
            "RemoteFileInspectorHeader",
            "RemoteFileInspectorMetadataFormSection",
            "RemoteFileInspectorPrimaryActionsFormSection",
            "RemoteFileInspectorDeleteFormSection",
            "RemoteFileInspectorActionMenu",
            "RemoteFileInspectorMetadataPolicy"
        ] {
            #expect(
                !inspectorSource.contains("struct \(typeName)") && !inspectorSource.contains("enum \(typeName)"),
                "RemoteFilePreviewViews.swift should not define \(typeName)."
            )
            #expect(
                metadataSource.contains("struct \(typeName)") || metadataSource.contains("enum \(typeName)"),
                "RemoteFileInspectorMetadataViews.swift should define \(typeName)."
            )
        }

        for functionName in [
            "canDownload",
            "canShare",
            "canEditPermissions",
            "showsPrimaryActions",
            "kindLabel",
            "sizeLabel",
            "modifiedLabel"
        ] {
            #expect(
                !inspectorSource.contains("func \(functionName)"),
                "RemoteFileInspectorView should not own \(functionName)."
            )
            #expect(
                metadataSource.contains("func \(functionName)"),
                "RemoteFileInspectorMetadataViews should own \(functionName)."
            )
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

    private enum SourceRootError: Error {
        case notFound
    }
}
