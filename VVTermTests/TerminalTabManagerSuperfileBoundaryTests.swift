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
    func persistenceOrchestrationLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let persistenceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Persistence.swift")
        )

        // Given tab snapshot shape, storage, and restore planning already
        // live in dedicated Application files, the manager should delegate
        // persistence orchestration too.
        #expect(persistenceSource.contains("extension TerminalTabManager"))
        #expect(persistenceSource.contains("func makeSnapshot"))
        #expect(persistenceSource.contains("func applyRestoredSnapshot"))
        #expect(persistenceSource.contains("func schedulePersist"))
        #expect(persistenceSource.contains("func persistSnapshot"))
        #expect(persistenceSource.contains("func restoreSnapshot"))

        // Then the superfile should not own snapshot assembly or
        // persist/restore scheduling directly.
        #expect(
            !managerSource.containsRegex(#"func\s+makeSnapshot\s*\("#),
            "TerminalTabManager.swift should not own snapshot assembly."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+applyRestoredSnapshot\s*\("#),
            "TerminalTabManager.swift should not own snapshot restoration mapping."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+schedulePersist\s*\("#),
            "TerminalTabManager.swift should not own persistence scheduling."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+persistSnapshot\s*\("#),
            "TerminalTabManager.swift should not own persistence writes."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+restoreSnapshot\s*\("#),
            "TerminalTabManager.swift should not own persistence restores."
        )
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

    @Test
    func serverTeardownTaskTrackingUsesTeardownTaskStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTeardownTaskStore.swift")
        )

        // Given tab close/open ordering waits on per-server teardown tasks.
        #expect(storeSource.contains("struct TerminalTeardownTaskStore"))
        #expect(storeSource.contains("tasks(forServer"))

        // Then teardown task indexing should not remain a bespoke nested dictionary in the superfile.
        #expect(
            !managerSource.contains("serverTeardownTasks"),
            "TerminalTabManager.swift should not own bespoke server teardown task indexing."
        )
        #expect(managerSource.contains("serverTeardownTaskStore"))
    }

    @Test
    func reconnectInFlightTrackingUsesReconnectInFlightStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalReconnectInFlightStore.swift")
        )

        // Given reconnect duplicate suppression is per terminal entity.
        #expect(storeSource.contains("struct TerminalReconnectInFlightStore"))
        #expect(storeSource.contains("func begin"))

        // Then reconnect in-flight state should not remain a bespoke Set in the superfile.
        #expect(
            !managerSource.contains("paneReconnectsInFlight"),
            "TerminalTabManager.swift should not own bespoke reconnect in-flight indexing."
        )
        #expect(managerSource.contains("reconnectInFlightStore"))
    }

    @Test
    func tmuxCleanupTrackingUsesTmuxCleanupStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTmuxCleanupStore.swift")
        )

        // Given tmux cleanup state tracks cleaned servers across attach attempts.
        #expect(storeSource.contains("struct TerminalTmuxCleanupStore"))
        #expect(storeSource.contains("func replace"))

        // Then cleanup state should not remain a bespoke Set in the superfile.
        #expect(
            !managerSource.contains("tmuxCleanupServers"),
            "TerminalTabManager.swift should not own bespoke tmux cleanup server indexing."
        )
        #expect(managerSource.contains("tmuxCleanupStore"))
    }

    @Test
    func connectWatchdogTrackingUsesWatchdogStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalConnectWatchdogStore.swift")
        )

        // Given connect watchdog lifecycle needs task and generation tracking.
        #expect(storeSource.contains("struct TerminalConnectWatchdogStore"))
        #expect(storeSource.contains("beginGeneration"))

        // Then watchdog task/generation indexing should not remain bespoke state in the superfile.
        #expect(
            !managerSource.contains("connectWatchdogTasks"),
            "TerminalTabManager.swift should not own bespoke connect watchdog task indexing."
        )
        #expect(
            !managerSource.contains("connectWatchdogGenerations"),
            "TerminalTabManager.swift should not own bespoke connect watchdog generation tracking."
        )
        #expect(managerSource.contains("connectWatchdogStore"))
    }

    @Test
    func paneTerminalIORequestLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let ioSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+TerminalIO.swift")
        )

        // Given pane input, rich-paste upload, and resize requests share
        // application-owned async lifecycle tracking.
        #expect(ioSource.contains("extension TerminalTabManager"))
        #expect(ioSource.contains("func requestPaneInput"))
        #expect(ioSource.contains("func requestPaneRichPasteUpload"))
        #expect(ioSource.contains("func requestPaneResize"))
        #expect(ioSource.contains("func cancelPaneRichPasteUploadRequests"))

        // Then the superfile should not own pane terminal I/O request
        // implementations directly.
        #expect(
            !managerSource.containsRegex(#"func\s+sendInput\s*\("#),
            "TerminalTabManager.swift should not own pane input sending."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestPaneInput\s*\("#),
            "TerminalTabManager.swift should not own pane input request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestPaneRichPasteUpload\s*\("#),
            "TerminalTabManager.swift should not own pane rich-paste upload request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+resizePane\s*\("#),
            "TerminalTabManager.swift should not own pane resize sending."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestPaneResize\s*\("#),
            "TerminalTabManager.swift should not own pane resize request lifecycle."
        )
    }

    @Test
    func paneTerminalSurfaceLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let surfaceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+TerminalSurfaces.swift")
        )

        // Given pane terminal surface attach and detach are UI-surface
        // lifecycle concerns in the TerminalSessions Application layer.
        #expect(surfaceSource.contains("extension TerminalTabManager"))
        #expect(surfaceSource.contains("func registerTerminal"))
        #expect(surfaceSource.contains("func unregisterTerminal"))
        #expect(surfaceSource.contains("func getTerminal"))
        #expect(surfaceSource.contains("func requestSurfaceAttach"))
        #expect(surfaceSource.contains("func attachSurface"))
        #expect(surfaceSource.contains("func detachSurface"))

        // Then the superfile should not own pane terminal surface
        // registration or attach/detach request lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+registerTerminal\s*\("#),
            "TerminalTabManager.swift should not own pane terminal registration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+unregisterTerminal\s*\("#),
            "TerminalTabManager.swift should not own pane terminal unregister cleanup."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSurfaceAttach\s*\("#),
            "TerminalTabManager.swift should not own pane surface attach request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+attachSurface\s*\("#),
            "TerminalTabManager.swift should not own pane surface attach execution."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+detachSurface\s*\("#),
            "TerminalTabManager.swift should not own pane surface detach lifecycle."
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

private extension String {
    func containsRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
