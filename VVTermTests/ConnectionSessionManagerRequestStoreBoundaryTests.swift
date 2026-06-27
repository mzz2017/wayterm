import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions Application request and
// tracking store ownership. ConnectionSessionManager may orchestrate requests,
// but indexing, de-duplication, and task tracking should stay in focused
// Application helpers so future lifecycle work does not regrow the manager
// superfile. Update only when this ownership intentionally moves again.
@Suite(.serialized)
struct ConnectionSessionManagerRequestStoreBoundaryTests {
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
    func connectionOpenLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let openSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Open.swift")
        )

        // Given connection opening owns request gating, unlock, teardown
        // ordering, existing-session reuse, and new session creation.
        #expect(openSource.contains("extension ConnectionSessionManager"))
        #expect(openSource.contains("func requestConnectionOpen"))
        #expect(openSource.contains("func waitForConnectionOpenRequest"))
        #expect(openSource.contains("func openConnection"))
        #expect(openSource.contains("func sourceSessionForNewTab"))

        // Then the superfile should not own connection open lifecycle directly.
        #expect(
            !managerSource.containsRegex(#"func\s+requestConnectionOpen\s*\("#),
            "ConnectionSessionManager.swift should not own connection-open request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+waitForConnectionOpenRequest\s*\("#),
            "ConnectionSessionManager.swift should not own connection-open request waiting."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+openConnection\s*\("#),
            "ConnectionSessionManager.swift should not own connection-open orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+sourceSessionForNewTab\s*\("#),
            "ConnectionSessionManager.swift should not own source-session selection for new tabs."
        )
    }

    @Test
    func debugTestingLifecycleLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let testingSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )

        // Given test reset and fake-injection hooks perform lifecycle teardown
        // and should not keep the production manager source near superfile size.
        #expect(testingSource.contains("#if DEBUG"))
        #expect(testingSource.contains("extension ConnectionSessionManager"))
        #expect(testingSource.contains("func resetForTesting"))
        #expect(testingSource.contains("func setTerminalConnectionClientFactoryForTesting"))
        #expect(testingSource.contains("func completeRuntimeShellStartForTesting"))

        // Then the production manager file should not own debug lifecycle support.
        #expect(
            !managerSource.containsRegex(#"func\s+resetForTesting\s*\("#),
            "ConnectionSessionManager.swift should not own debug reset lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+setTerminalConnectionClientFactoryForTesting\s*\("#),
            "ConnectionSessionManager.swift should not own test client injection."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+completeRuntimeShellStartForTesting\s*\("#),
            "ConnectionSessionManager.swift should not own test shell-start completion helpers."
        )
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
    func serverDisconnectTaskTrackingUsesServerTaskStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalServerTaskStore.swift")
        )

        // Given explicit server disconnect gates allow one tracked task per server.
        #expect(storeSource.contains("struct TerminalServerTaskStore"))
        #expect(storeSource.contains("task(forServer"))

        // Then server disconnect task indexing should not remain a bespoke dictionary in the superfile.
        #expect(
            !managerSource.contains("serverDisconnectTasks"),
            "ConnectionSessionManager.swift should not own bespoke server disconnect task indexing."
        )
        #expect(managerSource.contains("serverDisconnectTaskStore"))
    }

    @Test
    func reconnectInFlightTrackingUsesReconnectInFlightStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalReconnectInFlightStore.swift")
        )

        // Given reconnect duplicate suppression is per terminal entity.
        #expect(storeSource.contains("struct TerminalReconnectInFlightStore"))
        #expect(storeSource.contains("func begin"))

        // Then reconnect in-flight state should not remain a bespoke Set in the superfile.
        #expect(
            !managerSource.contains("sessionReconnectsInFlight"),
            "ConnectionSessionManager.swift should not own bespoke reconnect in-flight indexing."
        )
        #expect(managerSource.contains("reconnectInFlightStore"))
    }

    @Test
    func tmuxCleanupTrackingUsesTmuxCleanupStore() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
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
            "ConnectionSessionManager.swift should not own bespoke tmux cleanup server indexing."
        )
        #expect(managerSource.contains("tmuxCleanupStore"))
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

private extension String {
    func containsRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
