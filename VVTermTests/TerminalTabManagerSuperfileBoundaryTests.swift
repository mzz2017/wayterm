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
    func tabOpenLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let openSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Open.swift")
        )

        // Given tab opening owns request gating, unlock, teardown ordering,
        // existing-tab reuse, and new root pane creation.
        #expect(openSource.contains("extension TerminalTabManager"))
        #expect(openSource.contains("func requestTabOpen"))
        #expect(openSource.contains("func requestServerTerminalOpen"))
        #expect(openSource.contains("func waitForTabOpenRequest"))
        #expect(openSource.contains("func openTab"))

        // Then the superfile should not own tab open lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+requestTabOpen\s*\("#),
            "TerminalTabManager.swift should not own tab-open request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestServerTerminalOpen\s*\("#),
            "TerminalTabManager.swift should not own server terminal-open request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+waitForTabOpenRequest\s*\("#),
            "TerminalTabManager.swift should not own tab-open request waiting."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+openTab\s*\("#),
            "TerminalTabManager.swift should not own tab-open orchestration."
        )
    }

    @Test
    func debugTestingLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let testingSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Testing.swift")
        )

        // Given test reset and fake-injection hooks perform lifecycle teardown
        // and should not keep the production manager source near superfile size.
        #expect(testingSource.contains("#if DEBUG"))
        #expect(testingSource.contains("extension TerminalTabManager"))
        #expect(testingSource.contains("func resetForTesting"))
        #expect(testingSource.contains("func setTerminalConnectionClientFactoryForTesting"))
        #expect(testingSource.contains("func completeRuntimeShellStartForTesting"))

        // Then the production manager file should not own debug lifecycle support.
        #expect(
            !managerSource.containsRegex(#"func\s+resetForTesting\s*\("#),
            "TerminalTabManager.swift should not own debug reset lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+setTerminalConnectionClientFactoryForTesting\s*\("#),
            "TerminalTabManager.swift should not own test client injection."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+completeRuntimeShellStartForTesting\s*\("#),
            "TerminalTabManager.swift should not own test shell-start completion helpers."
        )
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
    func paneReconnectRequestLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let reconnectSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Reconnect.swift")
        )

        // Given pane reconnect requests coordinate async retry, credential
        // loading, host retrust, and install/reconnect callbacks.
        #expect(reconnectSource.contains("extension TerminalTabManager"))
        #expect(reconnectSource.contains("func reconnectPane"))
        #expect(reconnectSource.contains("func requestPaneRetry"))
        #expect(reconnectSource.contains("func requestPaneCredentialLoad"))
        #expect(reconnectSource.contains("func requestPaneHostRetrust"))
        #expect(reconnectSource.contains("func requestMoshInstallAndReconnect"))

        // Then the superfile should not own pane reconnect request lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+reconnectPane\s*\("#),
            "TerminalTabManager.swift should not own pane reconnect orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestPaneRetry\s*\("#),
            "TerminalTabManager.swift should not own pane retry request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestPaneCredentialLoad\s*\("#),
            "TerminalTabManager.swift should not own pane credential-load request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestPaneHostRetrust\s*\("#),
            "TerminalTabManager.swift should not own pane host-retrust request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+requestMoshInstallAndReconnect\s*\("#),
            "TerminalTabManager.swift should not own pane mosh install/reconnect requests."
        )
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
    func tmuxLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let tmuxSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Tmux.swift")
        )

        // Given tmux prompt handling, attach planning, cleanup, and install
        // are remote runtime lifecycle concerns with their own policy surface.
        #expect(tmuxSource.contains("extension TerminalTabManager"))
        #expect(tmuxSource.contains("func resolveTmuxAttachPrompt"))
        #expect(tmuxSource.contains("func tmuxStartupPlan"))
        #expect(tmuxSource.contains("func startTmuxInstall"))
        #expect(tmuxSource.contains("func killTmuxIfNeeded"))
        #expect(tmuxSource.contains("func disableTmux"))

        // Then the superfile should not own tmux lifecycle policy directly.
        #expect(
            !managerSource.containsRegex(#"func\s+resolveTmuxAttachPrompt\s*\("#),
            "TerminalTabManager.swift should not own tmux prompt resolution."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+tmuxStartupPlan\s*\("#),
            "TerminalTabManager.swift should not own tmux startup planning."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+startTmuxInstall\s*\("#),
            "TerminalTabManager.swift should not own tmux installation orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+killTmuxIfNeeded\s*\("#),
            "TerminalTabManager.swift should not own tmux cleanup orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+disableTmux\s*\("#),
            "TerminalTabManager.swift should not own tmux disable policy."
        )
    }

    @Test
    func paneRuntimeLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift")
        )

        // Given SSH registration, shell-start gating, runtime startup, and
        // runtime teardown are long-lived pane resource lifecycle concerns.
        #expect(runtimeSource.contains("extension TerminalTabManager"))
        #expect(runtimeSource.contains("func registerSSHClient"))
        #expect(runtimeSource.contains("func configureRuntime"))
        #expect(runtimeSource.contains("func startRuntimeIfNeeded"))
        #expect(runtimeSource.contains("func cancelRuntime"))
        #expect(runtimeSource.contains("func unregisterSSHClient"))
        #expect(runtimeSource.contains("func registeredShellRoute"))
        #expect(runtimeSource.contains("func beginShellStart"))

        // Then the runtime callbacks stay bound to the manager instance instead
        // of resolving the shared singleton from detached lifecycle work.
        #expect(
            !runtimeSource.contains("TerminalTabManager.shared"),
            "Pane runtime callbacks should not resolve TerminalTabManager.shared."
        )

        // And the superfile should not own pane runtime/SSH lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+registerSSHClient\s*\("#),
            "TerminalTabManager.swift should not own pane SSH registration lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+configureRuntime\s*\("#),
            "TerminalTabManager.swift should not own pane runtime configuration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+startRuntimeIfNeeded\s*\("#),
            "TerminalTabManager.swift should not own pane runtime start orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+cancelRuntime\s*\("#),
            "TerminalTabManager.swift should not own pane runtime teardown orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+unregisterSSHClient\s*\("#),
            "TerminalTabManager.swift should not own pane SSH unregister teardown."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+registeredShellRoute\s*\("#),
            "TerminalTabManager.swift should not own pane registered shell route lookup."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+beginShellStart\s*\("#),
            "TerminalTabManager.swift should not own pane shell-start gating."
        )
    }

    @Test
    func paneCloseLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let closeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Closing.swift")
        )

        // Given tab and pane close paths own teardown ordering, request
        // cancellation, shell cleanup, and managed tmux kill tracking.
        #expect(closeSource.contains("extension TerminalTabManager"))
        #expect(closeSource.contains("func closeTab"))
        #expect(closeSource.contains("func closePane"))
        #expect(closeSource.contains("func preparePaneClose"))
        #expect(closeSource.contains("func finishPaneClose"))
        #expect(closeSource.contains("func waitForServerTeardownTasks"))
        #expect(closeSource.contains("func trackShellCleanup"))

        // Then the superfile should not own close/teardown lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+closeTab\s*\("#),
            "TerminalTabManager.swift should not own tab close lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+closePane\s*\("#),
            "TerminalTabManager.swift should not own pane close lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+preparePaneClose\s*\("#),
            "TerminalTabManager.swift should not own pane teardown preparation."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+finishPaneClose\s*\("#),
            "TerminalTabManager.swift should not own pane teardown completion."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+trackShellCleanup\s*\("#),
            "TerminalTabManager.swift should not own shell cleanup task tracking."
        )
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
    func paneConnectWatchdogLifecycleLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let watchdogSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Watchdog.swift")
        )

        // Given connect watchdog scheduling owns timeout retry lifecycle.
        #expect(watchdogSource.contains("extension TerminalTabManager"))
        #expect(watchdogSource.contains("func shouldScheduleConnectWatchdog"))
        #expect(watchdogSource.contains("func scheduleConnectWatchdog"))
        #expect(watchdogSource.contains("func handleConnectWatchdogTimeout"))

        // Then the superfile should not own watchdog lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+shouldScheduleConnectWatchdog\s*\("#),
            "TerminalTabManager.swift should not own watchdog scheduling policy."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+scheduleConnectWatchdog\s*\("#),
            "TerminalTabManager.swift should not own watchdog retry lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+handleConnectWatchdogTimeout\s*\("#),
            "TerminalTabManager.swift should not own watchdog timeout handling."
        )
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
