import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions Application superfile
// control. ConnectionSessionManager owns orchestration; shared lifecycle value
// types, persistence snapshots, and infrastructure stores should live in
// dedicated owned files so future connection behavior changes do not expand the
// manager superfile.
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
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Infrastructure/ConnectionSessionsSnapshotStore.swift")
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
        #expect(storeSource.contains("UserDefaults"))
        #expect(storeSource.contains("func save"))
        #expect(storeSource.contains("func load"))
        #expect(storeSource.contains("func remove"))
    }

    @Test
    func persistenceOrchestrationLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let persistenceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Persistence.swift")
        )

        // Given snapshot shape and storage already live in dedicated
        // Application files, the manager should delegate persistence
        // orchestration too.
        #expect(persistenceSource.contains("extension ConnectionSessionManager"))
        #expect(persistenceSource.contains("func makeSnapshot"))
        #expect(persistenceSource.contains("func applyRestoredSnapshot"))
        #expect(persistenceSource.contains("func schedulePersist"))
        #expect(persistenceSource.contains("func persistSnapshot"))
        #expect(persistenceSource.contains("func restoreSnapshot"))

        // Then the superfile should not own snapshot assembly or
        // persist/restore scheduling directly.
        #expect(
            !managerSource.containsRegex(#"func\s+makeSnapshot\s*\("#),
            "ConnectionSessionManager.swift should not own snapshot assembly."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+applyRestoredSnapshot\s*\("#),
            "ConnectionSessionManager.swift should not own snapshot restoration mapping."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+schedulePersist\s*\("#),
            "ConnectionSessionManager.swift should not own persistence scheduling."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+persistSnapshot\s*\("#),
            "ConnectionSessionManager.swift should not own persistence writes."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+restoreSnapshot\s*\("#),
            "ConnectionSessionManager.swift should not own persistence restores."
        )
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
    func shellHandlerTrackingUsesShellHandlerStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalShellHandlerStore.swift")
        )

        // Given shell cancel and suspend handlers share a session lifecycle boundary.
        #expect(storeSource.contains("struct TerminalShellHandlerStore"))
        #expect(storeSource.contains("takeCancelHandler"))

        // Then handler bookkeeping should not remain as bespoke twin dictionaries in the superfile.
        #expect(
            !managerSource.contains("shellCancelHandlers"),
            "ConnectionSessionManager.swift should not own bespoke shell cancel handler indexing."
        )
        #expect(
            !managerSource.contains("shellSuspendHandlers"),
            "ConnectionSessionManager.swift should not own bespoke shell suspend handler indexing."
        )
        #expect(managerSource.contains("shellHandlerStore"))
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
        let appDependencySource = try source(
            at: root.appendingPathComponent("VVTerm/App/TerminalSessionLiveDependencies.swift")
        )

        // Given the connection session manager source.
        #expect(
            !managerSource.contains("actor ConnectionReliabilityManager"),
            "ConnectionSessionManager.swift should not own the reconnect reliability actor."
        )

        // Then reconnect reliability policy has a dedicated Application file.
        #expect(reliabilitySource.contains("actor ConnectionReliabilityManager"))
        #expect(reliabilitySource.contains("typealias ReconnectOperation"))
        #expect(reliabilitySource.contains("typealias DelayOperation"))
        #expect(reliabilitySource.contains("handleDisconnect"))
        #expect(reliabilitySource.contains("resetAttempts"))
        #expect(
            !reliabilitySource.contains("ConnectionSessionManager.shared"),
            "ConnectionReliabilityManager retry policy should not reach directly into the shared manager."
        )
        #expect(appDependencySource.contains("extension ConnectionReliabilityManager"))
        #expect(appDependencySource.contains("ConnectionSessionManager.shared.reconnect(session: session)"))
    }

    @Test
    func tmuxLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let tmuxSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Tmux.swift")
        )

        // Given tmux prompt handling, attach planning, cleanup, and install
        // are remote runtime lifecycle concerns with their own policy surface.
        #expect(tmuxSource.contains("extension ConnectionSessionManager"))
        #expect(tmuxSource.contains("func resolveTmuxAttachPrompt"))
        #expect(tmuxSource.contains("func tmuxStartupPlan"))
        #expect(tmuxSource.contains("func startTmuxInstall"))
        #expect(tmuxSource.contains("func killTmuxIfNeeded"))
        #expect(tmuxSource.contains("func disableTmux"))

        // Then the superfile should not own tmux lifecycle policy directly.
        #expect(
            !managerSource.containsRegex(#"func\s+resolveTmuxAttachPrompt\s*\("#),
            "ConnectionSessionManager.swift should not own tmux prompt resolution."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+tmuxStartupPlan\s*\("#),
            "ConnectionSessionManager.swift should not own tmux startup planning."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+startTmuxInstall\s*\("#),
            "ConnectionSessionManager.swift should not own tmux installation orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+killTmuxIfNeeded\s*\("#),
            "ConnectionSessionManager.swift should not own tmux cleanup orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+disableTmux\s*\("#),
            "ConnectionSessionManager.swift should not own tmux disable policy."
        )
    }

    @Test
    func sessionCloseLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let closeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Closing.swift")
        )

        // Given session close and disconnect paths own teardown ordering,
        // request cancellation, shell teardown handlers, and background
        // suspension cleanup.
        #expect(closeSource.contains("extension ConnectionSessionManager"))
        #expect(closeSource.contains("func closeSession"))
        #expect(closeSource.contains("func disconnectAllAndWait"))
        #expect(closeSource.contains("func suspendAllForBackground"))
        #expect(closeSource.contains("func requestSessionProcessExit"))
        #expect(closeSource.contains("func trackShellTeardownForClosedSession"))
        #expect(closeSource.contains("func waitForServerTeardownTasks"))

        // Then the superfile should not own session close/teardown lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+closeSession\s*\("#),
            "ConnectionSessionManager.swift should not own session close lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+disconnectAllAndWait\s*\("#),
            "ConnectionSessionManager.swift should not own disconnect-all teardown."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+suspendAllForBackground\s*\("#),
            "ConnectionSessionManager.swift should not own background suspension teardown."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSessionProcessExit\s*\("#),
            "ConnectionSessionManager.swift should not own process-exit request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+trackShellTeardownForClosedSession\s*\("#),
            "ConnectionSessionManager.swift should not own shell teardown tracking."
        )
    }

    @Test
    func sessionReconnectRequestLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let reconnectSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Reconnect.swift")
        )

        // Given reconnect requests coordinate async retry, credential
        // loading, host retrust, active-view reconnect, and install/reconnect
        // callbacks.
        #expect(reconnectSource.contains("extension ConnectionSessionManager"))
        #expect(reconnectSource.contains("func reconnect"))
        #expect(reconnectSource.contains("func requestActiveConnectionOpen"))
        #expect(reconnectSource.contains("func requestForegroundReconnectForSelectedSession"))
        #expect(reconnectSource.contains("func requestSessionRetry"))
        #expect(reconnectSource.contains("func requestSessionCredentialLoad"))
        #expect(reconnectSource.contains("func requestSessionHostRetrust"))
        #expect(reconnectSource.contains("func requestMoshInstallAndReconnect"))

        // Then the superfile should not own reconnect request lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+reconnect\s*\("#),
            "ConnectionSessionManager.swift should not own reconnect orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestActiveConnectionOpen\s*\("#),
            "ConnectionSessionManager.swift should not own active connection-open reconnect requests."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestForegroundReconnectForSelectedSession\s*\("#),
            "ConnectionSessionManager.swift should not own foreground reconnect requests."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSessionRetry\s*\("#),
            "ConnectionSessionManager.swift should not own retry request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSessionCredentialLoad\s*\("#),
            "ConnectionSessionManager.swift should not own credential-load request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSessionHostRetrust\s*\("#),
            "ConnectionSessionManager.swift should not own host-retrust request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestMoshInstallAndReconnect\s*\("#),
            "ConnectionSessionManager.swift should not own mosh install/reconnect requests."
        )
    }

    @Test
    func sessionRuntimeLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Runtime.swift")
        )

        // Given SSH registration, shell-start gating, runtime startup, and
        // runtime teardown are long-lived resource lifecycle concerns.
        #expect(runtimeSource.contains("extension ConnectionSessionManager"))
        #expect(runtimeSource.contains("func registerSSHClient"))
        #expect(runtimeSource.contains("func configureRuntime"))
        #expect(runtimeSource.contains("func startRuntimeIfNeeded"))
        #expect(runtimeSource.contains("func cancelRuntime"))
        #expect(runtimeSource.contains("func registeredShellRoute"))
        #expect(runtimeSource.contains("func beginShellStart"))

        // Then the runtime callbacks stay bound to the manager instance instead
        // of resolving the shared singleton from detached lifecycle work.
        #expect(
            !runtimeSource.contains("ConnectionSessionManager.shared"),
            "Session runtime callbacks should not resolve ConnectionSessionManager.shared."
        )

        // And the superfile should not own session runtime/SSH lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+registerSSHClient\s*\("#),
            "ConnectionSessionManager.swift should not own SSH registration lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+configureRuntime\s*\("#),
            "ConnectionSessionManager.swift should not own runtime configuration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+startRuntimeIfNeeded\s*\("#),
            "ConnectionSessionManager.swift should not own runtime start orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+cancelRuntime\s*\("#),
            "ConnectionSessionManager.swift should not own runtime teardown orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+registeredShellRoute\s*\("#),
            "ConnectionSessionManager.swift should not own registered shell route lookup."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+beginShellStart\s*\("#),
            "ConnectionSessionManager.swift should not own shell-start gating."
        )
    }

    @Test
    func sessionConnectWatchdogLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let watchdogSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Watchdog.swift")
        )

        // Given connect watchdog scheduling owns timeout retry lifecycle.
        #expect(watchdogSource.contains("extension ConnectionSessionManager"))
        #expect(watchdogSource.contains("func shouldScheduleConnectWatchdog"))
        #expect(watchdogSource.contains("func scheduleConnectWatchdog"))
        #expect(watchdogSource.contains("func handleConnectWatchdogTimeout"))

        // Then the superfile should not own watchdog lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+shouldScheduleConnectWatchdog\s*\("#),
            "ConnectionSessionManager.swift should not own watchdog scheduling policy."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+scheduleConnectWatchdog\s*\("#),
            "ConnectionSessionManager.swift should not own watchdog retry lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+handleConnectWatchdogTimeout\s*\("#),
            "ConnectionSessionManager.swift should not own watchdog timeout handling."
        )
    }

    @Test
    func terminalSurfaceManagementLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let surfaceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+TerminalSurfaces.swift")
        )

        // Given terminal surface ownership remains in the TerminalSessions
        // Application layer.
        #expect(surfaceSource.contains("extension ConnectionSessionManager"))
        #expect(surfaceSource.contains("func registerTerminal"))
        #expect(surfaceSource.contains("func unregisterTerminal"))
        #expect(surfaceSource.contains("func getTerminal"))
        #expect(surfaceSource.contains("func evictOldTerminalsIfNeeded"))
        #expect(surfaceSource.contains("func requestSurfaceAttach"))
        #expect(surfaceSource.contains("func attachSurface"))
        #expect(surfaceSource.contains("func detachSurface"))
        #expect(surfaceSource.contains("func handleClosedSessionSurfaceTeardown"))

        // Then the superfile should not own the terminal surface registration
        // and attach/detach lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+registerTerminal\s*\("#),
            "ConnectionSessionManager.swift should not own terminal surface registration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+unregisterTerminal\s*\("#),
            "ConnectionSessionManager.swift should not own terminal surface unregister cleanup."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+evictOldTerminalsIfNeeded\s*\("#),
            "ConnectionSessionManager.swift should not own terminal surface LRU eviction."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSurfaceAttach\s*\("#),
            "ConnectionSessionManager.swift should not own surface attach request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+attachSurface\s*\("#),
            "ConnectionSessionManager.swift should not own surface attach execution."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+detachSurface\s*\("#),
            "ConnectionSessionManager.swift should not own surface detach lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+handleClosedSessionSurfaceTeardown\s*\("#),
            "ConnectionSessionManager.swift should not own closed-session surface teardown routing."
        )
    }

    @Test
    func terminalIORequestLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let ioSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+TerminalIO.swift")
        )

        // Given terminal input, rich-paste upload, and resize requests share
        // application-owned async lifecycle tracking.
        #expect(ioSource.contains("extension ConnectionSessionManager"))
        #expect(ioSource.contains("func requestSessionInput"))
        #expect(ioSource.contains("func requestSessionRichPasteUpload"))
        #expect(ioSource.contains("func requestSessionResize"))
        #expect(ioSource.contains("func cancelSessionRichPasteUploadRequests"))

        // Then the superfile should not own the terminal I/O request
        // implementations directly.
        #expect(
            !managerSource.containsRegex(#"func\s+sendInput\s*\("#),
            "ConnectionSessionManager.swift should not own terminal input sending."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSessionInput\s*\("#),
            "ConnectionSessionManager.swift should not own terminal input request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSessionRichPasteUpload\s*\("#),
            "ConnectionSessionManager.swift should not own rich-paste upload request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+resizeSession\s*\("#),
            "ConnectionSessionManager.swift should not own terminal resize sending."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestSessionResize\s*\("#),
            "ConnectionSessionManager.swift should not own terminal resize request lifecycle."
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
