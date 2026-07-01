import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect server-scoped disconnect orchestration at the App
// Application boundary. UI may ask to disconnect a server and update
// presentation when completion returns, but RemoteFiles teardown, file-tab
// cleanup, terminal disconnect, duplicate request coalescing, and completion
// ordering must be owned by a tracked application-layer request. Fakes are
// in-memory closures plus small gates; update this context only if server
// disconnect orchestration intentionally moves to another non-UI owner with
// equivalent request tracking and ordering guarantees.
@Suite(.serialized)
@MainActor
struct ServerConnectionLifecycleCoordinatorTests {
    @Test
    func serverDisconnectRequestAwaitsRemoteFilesBeforeTabsTerminalAndCompletion() async {
        let serverId = UUID()
        let recorder = ServerDisconnectRecorder()
        let remoteGate = ServerDisconnectGate()
        let coordinator = ServerConnectionLifecycleCoordinator()

        // Given RemoteFiles teardown is still running for a server.
        let requestID = coordinator.requestServerDisconnect(
            serverId: serverId,
            disconnectRemoteFiles: { requestedServerId in
                #expect(requestedServerId == serverId)
                return Task { @MainActor in
                    recorder.record("remote-start")
                    await remoteGate.wait()
                    recorder.record("remote-end")
                }
            },
            disconnectFileTabs: { requestedServerId in
                #expect(requestedServerId == serverId)
                recorder.record("file-tabs")
            },
            disconnectTerminals: { requestedServerId in
                #expect(requestedServerId == serverId)
                recorder.record("terminal")
            },
            onCompleted: {
                recorder.record("complete")
            }
        )
        await recorder.waitForCount(1)

        // Then the request stays pending and terminal teardown has not started.
        #expect(
            coordinator.pendingDisconnectRequestIDs == [requestID],
            "Server disconnect should remain tracked while RemoteFiles teardown is in flight."
        )
        #expect(recorder.events == ["remote-start"])

        // When RemoteFiles teardown completes.
        await remoteGate.open()
        await coordinator.waitForDisconnectRequest(requestID)

        // Then file tabs, terminal disconnect, and completion run in order.
        #expect(
            recorder.events == ["remote-start", "remote-end", "file-tabs", "terminal", "complete"],
            "Server disconnect must finish RemoteFiles before clearing tabs, disconnecting terminals, and notifying UI."
        )
        #expect(
            coordinator.pendingDisconnectRequestIDs.isEmpty,
            "Server disconnect tracking should clear only after completion callbacks run."
        )
    }

    @Test
    func duplicateServerDisconnectRequestsShareOneTrackedTeardown() async {
        let serverId = UUID()
        let recorder = ServerDisconnectRecorder()
        let remoteGate = ServerDisconnectGate()
        let coordinator = ServerConnectionLifecycleCoordinator()

        // Given one server disconnect request is already blocked in RemoteFiles.
        let firstRequestID = coordinator.requestServerDisconnect(
            serverId: serverId,
            disconnectRemoteFiles: { _ in
                Task { @MainActor in
                    recorder.record("remote-start")
                    await remoteGate.wait()
                    recorder.record("remote-end")
                }
            },
            disconnectFileTabs: { _ in recorder.record("file-tabs") },
            disconnectTerminals: { _ in recorder.record("terminal") },
            onCompleted: { recorder.record("complete-1") }
        )
        await recorder.waitForCount(1)

        // When the same server is disconnected again before teardown finishes.
        let secondRequestID = coordinator.requestServerDisconnect(
            serverId: serverId,
            disconnectRemoteFiles: { _ in
                Task { @MainActor in
                    recorder.record("unexpected-remote")
                }
            },
            disconnectFileTabs: { _ in recorder.record("unexpected-tabs") },
            disconnectTerminals: { _ in recorder.record("unexpected-terminal") },
            onCompleted: { recorder.record("complete-2") }
        )

        // Then both callers share the same request and no second teardown chain starts.
        #expect(secondRequestID == firstRequestID)
        #expect(coordinator.pendingDisconnectRequestIDs == [firstRequestID])
        #expect(recorder.events == ["remote-start"])

        await remoteGate.open()
        await coordinator.waitForDisconnectRequest(firstRequestID)

        #expect(
            recorder.events == ["remote-start", "remote-end", "file-tabs", "terminal", "complete-1", "complete-2"],
            "Duplicate server disconnect callers should receive completion from the one tracked teardown chain."
        )
        #expect(coordinator.pendingDisconnectRequestIDs.isEmpty)
    }

    @Test
    func duplicateServerDisconnectRequestedDuringCompletionRunsCallback() async {
        let serverId = UUID()
        let recorder = ServerDisconnectRecorder()
        let coordinator = ServerConnectionLifecycleCoordinator()
        var firstRequestID: UUID?
        var nestedRequestID: UUID?

        // Given a disconnect completion callback that synchronously asks to
        // disconnect the same server again.
        let requestID = coordinator.requestServerDisconnect(
            serverId: serverId,
            disconnectRemoteFiles: { _ in
                Task { @MainActor in
                    recorder.record("remote")
                }
            },
            disconnectFileTabs: { _ in recorder.record("file-tabs") },
            disconnectTerminals: { _ in recorder.record("terminal") },
            onCompleted: {
                recorder.record("complete-1")
                nestedRequestID = coordinator.requestServerDisconnect(
                    serverId: serverId,
                    disconnectRemoteFiles: { _ in
                        Task { @MainActor in
                            recorder.record("unexpected-remote")
                        }
                    },
                    disconnectFileTabs: { _ in recorder.record("unexpected-tabs") },
                    disconnectTerminals: { _ in recorder.record("unexpected-terminal") },
                    onCompleted: {
                        recorder.record("complete-2")
                    }
                )
            }
        )
        firstRequestID = requestID

        // When the first teardown reaches completion callback delivery.
        await coordinator.waitForDisconnectRequest(requestID)

        // Then the reentrant duplicate intent remains coalesced with the same
        // completed teardown and its callback is not dropped.
        #expect(nestedRequestID == firstRequestID)
        #expect(
            recorder.events == ["remote", "file-tabs", "terminal", "complete-1", "complete-2"],
            "Disconnect callbacks appended during completion delivery should run before request tracking clears."
        )
        #expect(coordinator.pendingDisconnectRequestIDs.isEmpty)
    }

    @Test
    func serverDisconnectRequestUsesConfiguredTeardownWhenCallerOnlySendsServerIntent() async {
        let serverId = UUID()
        let recorder = ServerDisconnectRecorder()
        let remoteGate = ServerDisconnectGate()
        let coordinator = ServerConnectionLifecycleCoordinator()

        coordinator.configureResourceDisconnects(
            disconnectRemoteFiles: { requestedServerId in
                #expect(requestedServerId == serverId)
                return Task { @MainActor in
                    recorder.record("remote-start")
                    await remoteGate.wait()
                    recorder.record("remote-end")
                }
            },
            disconnectStats: { requestedServerId in
                #expect(requestedServerId == serverId)
                recorder.record("stats")
            },
            disconnectFileTabs: { requestedServerId in
                #expect(requestedServerId == serverId)
                recorder.record("file-tabs")
            },
            disconnectTerminals: { requestedServerId in
                #expect(requestedServerId == serverId)
                recorder.record("terminal")
            }
        )

        // Given UI only sends a server disconnect intent.
        let requestID = coordinator.requestServerDisconnect(serverId: serverId, onCompleted: {
            recorder.record("complete")
        })
        await recorder.waitForCount(1)

        // Then configured resource and terminal teardown are owned and awaited by the coordinator.
        #expect(recorder.events == ["remote-start"])
        #expect(coordinator.pendingDisconnectRequestIDs == [requestID])

        await remoteGate.open()
        await coordinator.waitForDisconnectRequest(requestID)

        #expect(
            recorder.events == ["remote-start", "remote-end", "stats", "file-tabs", "terminal", "complete"],
            "Server disconnect should use configured resource and terminal teardown when UI sends only intent."
        )
        #expect(coordinator.pendingDisconnectRequestIDs.isEmpty)
    }

    @Test
    func serverDisconnectAwaitsStatsCleanupBeforeTabsAndTerminal() async {
        let serverId = UUID()
        let recorder = ServerDisconnectRecorder()
        let statsGate = ServerDisconnectGate()
        let coordinator = ServerConnectionLifecycleCoordinator()

        let requestID = coordinator.requestServerDisconnect(
            serverId: serverId,
            disconnectRemoteFiles: { _ in
                Task { @MainActor in
                    recorder.record("remote")
                }
            },
            disconnectStats: { requestedServerId in
                #expect(requestedServerId == serverId)
                recorder.record("stats-start")
                await statsGate.wait()
                recorder.record("stats-end")
            },
            disconnectFileTabs: { _ in recorder.record("file-tabs") },
            disconnectTerminals: { _ in recorder.record("terminal") },
            onCompleted: { recorder.record("complete") }
        )

        await recorder.waitForCount(2)
        #expect(recorder.events == ["remote", "stats-start"])
        #expect(
            coordinator.pendingDisconnectRequestIDs == [requestID],
            "Server disconnect should remain tracked while Stats cleanup is in flight."
        )

        await statsGate.open()
        await coordinator.waitForDisconnectRequest(requestID)

        #expect(
            recorder.events == ["remote", "stats-start", "stats-end", "file-tabs", "terminal", "complete"],
            "Server disconnect must await Stats cleanup before clearing tabs, disconnecting terminals, and notifying UI."
        )
    }

    @Test
    func serverDeletionTeardownWaitsForTrackedDisconnectChain() async {
        let workspaceId = UUID()
        let server = Server(
            id: UUID(),
            workspaceId: workspaceId,
            name: "Delete Target",
            host: "delete-target.example.com",
            username: "root"
        )
        let recorder = ServerDisconnectRecorder()
        let remoteGate = ServerDisconnectGate()
        let coordinator = ServerConnectionLifecycleCoordinator()

        let teardownTask = Task { @MainActor in
            await coordinator.disconnectServerBeforeDeletion(
                server: server,
                disconnectRemoteFiles: { requestedServerId in
                    #expect(requestedServerId == server.id)
                    return Task { @MainActor in
                        recorder.record("remote-start")
                        await remoteGate.wait()
                        recorder.record("remote-end")
                    }
                },
                disconnectStats: { requestedServerId in
                    #expect(requestedServerId == server.id)
                    recorder.record("stats")
                },
                disconnectFileTabs: { requestedServerId in
                    #expect(requestedServerId == server.id)
                    recorder.record("file-tabs")
                },
                disconnectConnectionSessions: { requestedServerId in
                    #expect(requestedServerId == server.id)
                    recorder.record("connection-sessions")
                },
                disconnectTerminalTabs: { requestedServerId in
                    #expect(requestedServerId == server.id)
                    recorder.record("terminal-tabs")
                }
            )
            recorder.record("deletion-teardown-returned")
        }
        await recorder.waitForCount(1)

        #expect(
            recorder.events == ["remote-start"],
            "Server deletion teardown should remain pending while remote file cleanup is in flight."
        )

        await remoteGate.open()
        await teardownTask.value

        #expect(
            recorder.events == [
                "remote-start",
                "remote-end",
                "stats",
                "file-tabs",
                "connection-sessions",
                "terminal-tabs",
                "deletion-teardown-returned"
            ],
            "Server deletion must await the shared server disconnect owner before metadata removal can continue."
        )
        #expect(coordinator.pendingDisconnectRequestIDs.isEmpty)
    }

    @Test
    func serverDeletionUsesConfiguredResourceTeardownWhenCallSiteOnlySendsIntent() async {
        let workspaceId = UUID()
        let server = Server(
            id: UUID(),
            workspaceId: workspaceId,
            name: "Configured Delete Target",
            host: "configured-delete.example.com",
            username: "root"
        )
        let recorder = ServerDisconnectRecorder()
        let remoteGate = ServerDisconnectGate()
        let coordinator = ServerConnectionLifecycleCoordinator()

        coordinator.configureResourceDisconnects(
            disconnectRemoteFiles: { requestedServerId in
                #expect(requestedServerId == server.id)
                return Task { @MainActor in
                    recorder.record("remote-start")
                    await remoteGate.wait()
                    recorder.record("remote-end")
                }
            },
            disconnectStats: { requestedServerId in
                #expect(requestedServerId == server.id)
                recorder.record("stats")
            },
            disconnectFileTabs: { requestedServerId in
                #expect(requestedServerId == server.id)
                recorder.record("file-tabs")
            }
        )

        let teardownTask = Task { @MainActor in
            await coordinator.disconnectServerBeforeDeletion(
                server: server,
                disconnectConnectionSessions: { requestedServerId in
                    #expect(requestedServerId == server.id)
                    recorder.record("connection-sessions")
                },
                disconnectTerminalTabs: { requestedServerId in
                    #expect(requestedServerId == server.id)
                    recorder.record("terminal-tabs")
                }
            )
            recorder.record("deletion-teardown-returned")
        }
        await recorder.waitForCount(1)

        #expect(
            recorder.events == ["remote-start"],
            "Server deletion should await configured RemoteFiles cleanup before continuing."
        )

        await remoteGate.open()
        await teardownTask.value

        #expect(
            recorder.events == [
                "remote-start",
                "remote-end",
                "stats",
                "file-tabs",
                "connection-sessions",
                "terminal-tabs",
                "deletion-teardown-returned"
            ],
            "Server deletion should use the App/Application owner's configured resource teardown chain."
        )
        #expect(coordinator.pendingDisconnectRequestIDs.isEmpty)
    }
}

@MainActor
private final class ServerDisconnectRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func waitForCount(_ count: Int) async {
        while events.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ServerDisconnectGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
