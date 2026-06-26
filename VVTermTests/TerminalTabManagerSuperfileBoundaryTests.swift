import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalTabManager superfile control.
// The manager owns tab orchestration; persistence shapes and reusable request
// indexing should live in dedicated Application support files. Update only when
// those ownership boundaries intentionally move again.

@Suite(.serialized)
struct TerminalTabManagerSuperfileBoundaryTests {
    @Test
    func persistenceSnapshotLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let snapshotSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabsSnapshot.swift")
        )

        // Given the terminal tab manager source.
        #expect(
            !managerSource.contains("struct TerminalTabsSnapshot"),
            "TerminalTabManager.swift should not own Codable persistence snapshot shape."
        )

        // Then tab persistence serialization has a dedicated Application file.
        #expect(snapshotSource.contains("struct TerminalTabsSnapshot"))
        #expect(snapshotSource.contains("struct ServerSnapshot"))
        #expect(snapshotSource.contains("struct TabSnapshot"))
    }

    @Test
    func snapshotStoreLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabsSnapshotStore.swift")
        )

        // Given the terminal tab manager source.
        #expect(
            !managerSource.contains("JSONEncoder().encode(makeSnapshot())"),
            "TerminalTabManager.swift should not own snapshot encoding."
        )
        #expect(
            !managerSource.contains("JSONDecoder().decode(TerminalTabsSnapshot.self"),
            "TerminalTabManager.swift should not own snapshot decoding."
        )

        // Then tab snapshot storage has a dedicated Application file.
        #expect(storeSource.contains("struct TerminalTabsSnapshotStore"))
        #expect(storeSource.contains("func save"))
        #expect(storeSource.contains("func load"))
        #expect(storeSource.contains("func remove"))
    }

    @Test
    func supportTypesLiveOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManagerSupport.swift")
        )

        // Given the terminal tab manager source.
        #expect(
            !managerSource.contains("struct PaneCloseResult"),
            "TerminalTabManager.swift should not own pane close result support shape."
        )
        #expect(
            !managerSource.contains("struct SurfaceAttachRequest"),
            "TerminalTabManager.swift should not own pending surface attach request shape."
        )
        #expect(
            !managerSource.contains("final class PaneRuntimeState"),
            "TerminalTabManager.swift should not own pane runtime support storage."
        )

        // Then tab-manager-only support types have a dedicated Application file.
        #expect(supportSource.contains("enum TerminalTabManagerSupport"))
        #expect(supportSource.contains("struct PaneCloseResult"))
        #expect(supportSource.contains("struct SurfaceAttachRequest"))
        #expect(supportSource.contains("final class PaneRuntimeState"))
    }

    @Test
    func paneInstallRequestIndexingUsesSharedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given pane- and session-scoped request indexing has a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then install requests should not keep bespoke pane/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("tmuxInstallRequestByPane"),
            "TerminalTabManager.swift should not own bespoke tmux install request indexing."
        )
        #expect(
            !managerSource.contains("moshInstallRequestByPane"),
            "TerminalTabManager.swift should not own bespoke mosh install request indexing."
        )
        #expect(managerSource.contains("tmuxInstallRequestStore"))
        #expect(managerSource.contains("moshInstallRequestStore"))
    }

    @Test
    func paneSurfaceAttachRequestIndexingUsesSharedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given pane-scoped surface attach indexing has a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then surface attach should not keep bespoke pane/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("surfaceAttachRequestByPane"),
            "TerminalTabManager.swift should not own bespoke surface attach request indexing."
        )
        #expect(managerSource.contains("surfaceAttachRequestStore"))
    }

    @Test
    func paneResizeRequestIndexingUsesSharedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given pane-scoped resize indexing has a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then resize should not keep bespoke pane/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("resizeRequestByPane"),
            "TerminalTabManager.swift should not own bespoke resize request indexing."
        )
        #expect(managerSource.contains("resizeRequestStore"))
    }

    @Test
    func paneProcessExitRequestIndexingUsesSharedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given pane-scoped process-exit indexing has a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then process-exit should not keep bespoke pane/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("processExitRequestByPane"),
            "TerminalTabManager.swift should not own bespoke process-exit request indexing."
        )
        #expect(managerSource.contains("processExitRequestStore"))
    }

    @Test
    func paneRichPasteUploadRequestIndexingUsesSharedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given pane-scoped rich-paste upload indexing has a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))
        #expect(storeSource.contains("removeAllRequests(forScope"))

        // Then rich-paste upload should not keep bespoke pane/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("richPasteUploadRequestByPane"),
            "TerminalTabManager.swift should not own bespoke rich-paste upload request indexing."
        )
        #expect(managerSource.contains("richPasteUploadRequestStore"))
    }

    @Test
    func paneInputRequestIndexingUsesSerialStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalSerialRequestStore.swift")
        )

        // Given pane input needs per-pane serial task chaining.
        #expect(storeSource.contains("struct TerminalSerialRequestStore"))
        #expect(storeSource.contains("lastTask(forScope"))

        // Then input should not keep bespoke pane/request/task dictionaries in the superfile.
        #expect(
            !managerSource.contains("inputRequestByPane"),
            "TerminalTabManager.swift should not own bespoke input request indexing."
        )
        #expect(
            !managerSource.contains("lastInputTaskByPane"),
            "TerminalTabManager.swift should not own bespoke input task-chain indexing."
        )
        #expect(managerSource.contains("inputRequestStore"))
    }

    @Test
    func tabOpenRequestTrackingUsesOpenRequestStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalOpenRequestStore.swift")
        )

        // Given tab opening needs request tracking and per-server in-flight gating.
        #expect(storeSource.contains("struct TerminalOpenRequestStore"))
        #expect(storeSource.contains("beginOpen(forScope"))

        // Then tab open request bookkeeping should not remain bespoke state in the superfile.
        #expect(
            !managerSource.contains("tabOpenRequests"),
            "TerminalTabManager.swift should not own bespoke tab open request indexing."
        )
        #expect(
            !managerSource.contains("tabOpensInFlight"),
            "TerminalTabManager.swift should not own bespoke tab open in-flight gating."
        )
        #expect(managerSource.contains("tabOpenRequestStore"))
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
