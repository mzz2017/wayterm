import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions Application superfile
// control. ConnectionSessionManager owns orchestration; shared lifecycle value
// types and persistence snapshots should live in dedicated support files so
// future connection behavior changes do not expand the manager superfile.
// Update only when this ownership intentionally moves again.

@Suite(.serialized)
struct ConnectionSessionManagerSuperfileBoundaryTests {
    @Test
    func lifecycleSupportTypesLiveOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalSessionLifecycleTypes.swift")
        )

        // Given the terminal session manager source.
        #expect(
            !managerSource.contains("enum ShellTeardownMode"),
            "ConnectionSessionManager.swift should not own shared shell teardown mode types."
        )
        #expect(
            !managerSource.contains("struct TerminalSurfaceAttachContext"),
            "ConnectionSessionManager.swift should not own shared terminal surface attach context types."
        )

        // Then shared lifecycle value types have a dedicated Application file.
        #expect(supportSource.contains("enum ShellTeardownMode"))
        #expect(supportSource.contains("enum TerminalSurfaceDetachReason"))
        #expect(supportSource.contains("struct TerminalSurfaceAttachContext"))
        #expect(supportSource.contains("struct TerminalResizeRequestSize"))
    }

    @Test
    func persistenceSnapshotLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let snapshotSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionsSnapshot.swift")
        )

        // Given the terminal session manager source.
        #expect(
            !managerSource.contains("struct ConnectionSessionsSnapshot"),
            "ConnectionSessionManager.swift should not own Codable persistence snapshot shape."
        )

        // Then session persistence serialization has a dedicated Application file.
        #expect(snapshotSource.contains("struct ConnectionSessionsSnapshot"))
        #expect(snapshotSource.contains("struct SessionSnapshot"))
        #expect(snapshotSource.contains("struct ServerSnapshot"))
    }

    @Test
    func snapshotStoreLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionsSnapshotStore.swift")
        )

        // Given the connection session manager source.
        #expect(
            !managerSource.contains("JSONEncoder().encode(makeSnapshot())"),
            "ConnectionSessionManager.swift should not own snapshot encoding."
        )
        #expect(
            !managerSource.contains("JSONDecoder().decode(ConnectionSessionsSnapshot.self"),
            "ConnectionSessionManager.swift should not own snapshot decoding."
        )

        // Then connection session snapshot storage has a dedicated Application file.
        #expect(storeSource.contains("struct ConnectionSessionsSnapshotStore"))
        #expect(storeSource.contains("func save"))
        #expect(storeSource.contains("func load"))
        #expect(storeSource.contains("func remove"))
    }

    @Test
    func supportTypesLiveOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManagerSupport.swift")
        )

        // Given the connection session manager source.
        #expect(
            !managerSource.contains("struct SessionCloseResult"),
            "ConnectionSessionManager.swift should not own session close result support shape."
        )
        #expect(
            !managerSource.contains("struct ForegroundReconnectRequest"),
            "ConnectionSessionManager.swift should not own foreground reconnect request shape."
        )
        #expect(
            !managerSource.contains("final class SessionRuntimeState"),
            "ConnectionSessionManager.swift should not own session runtime support storage."
        )

        // Then session-manager-only support types have a dedicated Application file.
        #expect(supportSource.contains("enum ConnectionSessionManagerSupport"))
        #expect(supportSource.contains("struct SessionCloseResult"))
        #expect(supportSource.contains("struct ForegroundReconnectRequest"))
        #expect(supportSource.contains("final class SessionRuntimeState"))
    }

    @Test
    func reliabilityManagerLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let reliabilitySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionReliabilityManager.swift")
        )

        // Given the connection session manager source.
        #expect(
            !managerSource.contains("actor ConnectionReliabilityManager"),
            "ConnectionSessionManager.swift should not own the reconnect reliability actor."
        )

        // Then reconnect reliability policy has a dedicated Application file.
        #expect(reliabilitySource.contains("actor ConnectionReliabilityManager"))
        #expect(reliabilitySource.contains("handleDisconnect"))
        #expect(reliabilitySource.contains("resetAttempts"))
    }

    @Test
    func installRequestIndexingUsesSharedScopedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given session- and pane-scoped request indexing has a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then install requests should not keep bespoke session/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("tmuxInstallRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke tmux install request indexing."
        )
        #expect(
            !managerSource.contains("moshInstallRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke mosh install request indexing."
        )
        #expect(managerSource.contains("tmuxInstallRequestStore"))
        #expect(managerSource.contains("moshInstallRequestStore"))
    }

    @Test
    func lifecycleRequestIndexingUsesSharedScopedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given session lifecycle requests have a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then lifecycle requests should not keep bespoke session/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("sessionRetryRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke retry request indexing."
        )
        #expect(
            !managerSource.contains("sessionHostRetrustRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke host retrust request indexing."
        )
        #expect(
            !managerSource.contains("sessionCredentialLoadRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke credential-load request indexing."
        )
        #expect(managerSource.contains("sessionRetryRequestStore"))
        #expect(managerSource.contains("sessionHostRetrustRequestStore"))
        #expect(managerSource.contains("sessionCredentialLoadRequestStore"))
    }

    @Test
    func reconnectIntentRequestIndexingUsesSharedScopedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given reconnect intent requests have a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then reconnect intents should not keep bespoke session/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("activeConnectionOpenRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke active-open request indexing."
        )
        #expect(
            !managerSource.contains("foregroundReconnectRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke foreground reconnect request indexing."
        )
        #expect(managerSource.contains("activeConnectionOpenRequestStore"))
        #expect(managerSource.contains("foregroundReconnectRequestStore"))
    }

    @Test
    func surfaceAttachRequestIndexingUsesSharedScopedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given surface attach requests have a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then surface attach should not keep bespoke session/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("surfaceAttachRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke surface attach request indexing."
        )
        #expect(managerSource.contains("surfaceAttachRequestStore"))
    }

    @Test
    func terminalEventRequestIndexingUsesSharedScopedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given terminal event requests have a shared Application helper.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))

        // Then resize and process-exit requests should not keep bespoke
        // session/request double dictionaries in the superfile.
        #expect(
            !managerSource.contains("resizeRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke resize request indexing."
        )
        #expect(
            !managerSource.contains("processExitRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke process-exit request indexing."
        )
        #expect(managerSource.contains("resizeRequestStore"))
        #expect(managerSource.contains("processExitRequestStore"))
    }

    @Test
    func richPasteUploadRequestIndexingUsesSharedScopedStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalScopedRequestStore.swift")
        )

        // Given rich-paste upload requests can keep superseded request IDs
        // awaitable while tracking the latest visible request per session.
        #expect(storeSource.contains("struct TerminalScopedRequestStore"))
        #expect(storeSource.contains("removeAllRequests(forScope"))

        // Then rich-paste upload should not keep bespoke session/request
        // double dictionaries in the superfile.
        #expect(
            !managerSource.contains("richPasteUploadRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke rich-paste upload request indexing."
        )
        #expect(managerSource.contains("richPasteUploadRequestStore"))
    }

    @Test
    func connectionOpenRequestTrackingUsesOpenRequestStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalOpenRequestStore.swift")
        )

        // Given connection opening needs request tracking and per-server in-flight gating.
        #expect(storeSource.contains("struct TerminalOpenRequestStore"))
        #expect(storeSource.contains("beginOpen(forScope"))

        // Then connection open request bookkeeping should not remain bespoke state in the superfile.
        #expect(
            !managerSource.contains("connectionOpenRequests"),
            "ConnectionSessionManager.swift should not own bespoke connection open request indexing."
        )
        #expect(
            !managerSource.contains("sessionOpensInFlight"),
            "ConnectionSessionManager.swift should not own bespoke connection open in-flight gating."
        )
        #expect(managerSource.contains("connectionOpenRequestStore"))
    }

    @Test
    func sessionInputRequestIndexingUsesSerialStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalSerialRequestStore.swift")
        )

        // Given session input needs per-session serial task chaining.
        #expect(storeSource.contains("struct TerminalSerialRequestStore"))
        #expect(storeSource.contains("lastTask(forScope"))

        // Then input should not keep bespoke session/request/task dictionaries in the superfile.
        #expect(
            !managerSource.contains("inputRequestBySession"),
            "ConnectionSessionManager.swift should not own bespoke input request indexing."
        )
        #expect(
            !managerSource.contains("lastInputTaskBySession"),
            "ConnectionSessionManager.swift should not own bespoke input task-chain indexing."
        )
        #expect(managerSource.contains("inputRequestStore"))
    }

    @Test
    func serverTeardownTaskTrackingUsesTeardownTaskStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTeardownTaskStore.swift")
        )

        // Given connection close/open ordering waits on per-server teardown tasks.
        #expect(storeSource.contains("struct TerminalTeardownTaskStore"))
        #expect(storeSource.contains("tasks(forServer"))

        // Then teardown task indexing should not remain a bespoke nested dictionary in the superfile.
        #expect(
            !managerSource.contains("serverTeardownTasks"),
            "ConnectionSessionManager.swift should not own bespoke server teardown task indexing."
        )
        #expect(managerSource.contains("serverTeardownTaskStore"))
    }

    @Test
    func connectWatchdogTrackingUsesWatchdogStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
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
            "ConnectionSessionManager.swift should not own bespoke connect watchdog task indexing."
        )
        #expect(
            !managerSource.contains("connectWatchdogGenerations"),
            "ConnectionSessionManager.swift should not own bespoke connect watchdog generation tracking."
        )
        #expect(managerSource.contains("connectWatchdogStore"))
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
