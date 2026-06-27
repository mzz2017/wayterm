import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect RemoteFiles application-layer lifecycle ownership for
// service disconnect serialization, mutation requests, and transfer requests.
// The fake clients and gates block remote work deterministically; failures
// usually mean UI intent can outlive, race, or bypass RemoteFileBrowserStore as
// the owner of async work.
@MainActor
struct RemoteFileBrowserRequestLifecycleTests {
    @Test
    func sameServerOperationWaitsForDroppedDisconnectTask() async throws {
        let defaults = makeRemoteFileBrowserDefaults()
        let server = makeRemoteFileBrowserServer()
        let disconnectingClient = BlockingDisconnectRemoteFileClient()
        let nextClient = BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [disconnectingClient, nextClient]
        let operationProbe = RemoteFileBrowserOperationProbe()
        let store = RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeRemoteFileBrowserCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            ),
            serverProvider: { _ in nil }
        )

        // Given RemoteFiles has an established service registration for a
        // server, and iOS sends disconnect intent without awaiting the returned
        // task.
        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        _ = store.disconnect(serverId: server.id)
        await disconnectingClient.waitUntilDisconnectStarted()

        // When a later same-server operation starts while the disconnect is
        // still closing the previous lease.
        let operationTask = Task {
            try await store.withRemoteFileService(for: server) { _ in
                await operationProbe.markStarted()
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then the store must wait for the pending disconnect instead of
        // racing a new SFTP registration over teardown.
        #expect(
            await !operationProbe.started,
            "Same-server RemoteFiles operations must wait for a pending disconnect even if the caller dropped the disconnect task."
        )

        await disconnectingClient.releaseDisconnect()
        try await operationTask.value
        #expect(await operationProbe.started)
    }

    @Test
    func sameServerOperationWaitsForDisconnectRegisteredAfterFirstWait() async throws {
        let defaults = makeRemoteFileBrowserDefaults()
        let server = makeRemoteFileBrowserServer()
        let firstClient = BlockingDisconnectRemoteFileClient()
        let secondClient = BlockingDisconnectRemoteFileClient()
        let thirdClient = BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [firstClient, secondClient, thirdClient]
        let operationProbe = RemoteFileBrowserOperationProbe()
        let store = RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeRemoteFileBrowserCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            ),
            serverProvider: { _ in nil }
        )
        var insertedSecondDisconnect = false
        store.setPendingDisconnectWaitDidFinishForTesting { serverId in
            guard serverId == server.id, !insertedSecondDisconnect else { return }
            insertedSecondDisconnect = true
            store.setPendingDisconnectWaitDidFinishForTesting(nil)
            _ = try? await store.withRemoteFileService(for: server) { service in
                try await service.resolveHomeDirectory()
            }
            _ = store.disconnect(serverId: server.id)
            await secondClient.waitUntilDisconnectStarted()
        }

        // Given an operation is waiting for a dropped disconnect task.
        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        _ = store.disconnect(serverId: server.id)
        await firstClient.waitUntilDisconnectStarted()
        let operationTask = Task {
            try await store.withRemoteFileService(for: server) { _ in
                await operationProbe.markStarted()
            }
        }

        // When the first disconnect finishes, another same-server disconnect
        // is registered before the waiting operation resumes service work.
        await firstClient.releaseDisconnect()
        try await Task.sleep(for: .milliseconds(20))

        // Then the waiting operation must re-check and wait for the second
        // pending disconnect too.
        #expect(
            await !operationProbe.started,
            "RemoteFiles should re-check pending disconnects after each awaited disconnect task."
        )

        await secondClient.releaseDisconnect()
        try await operationTask.value
        #expect(await operationProbe.started)
    }

    @Test
    func mutationRequestTracksTaskAndRunsSuccessAfterOperation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeRemoteFileBrowserDefaults(), serverProvider: { _ in nil })
        let gate = RemoteFileMutationGate()
        var events: [String] = []

        // Given a RemoteFiles mutation launched from synchronous UI intent.
        let requestID = store.requestMutation(
            operation: {
                events.append("operation-started")
                await gate.wait()
                events.append("operation-finished")
                return "created"
            },
            onSuccess: { result in
                events.append("success-\(result)")
            },
            onFailure: { _ in
                events.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        // Then the application store owns and exposes the pending mutation task
        // until the async operation finishes.
        #expect(store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started"])

        await gate.release()
        await store.waitForMutationRequest(requestID)

        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "operation-finished", "success-created"])
    }

    @Test
    func mutationRequestTracksFailureAndSkipsSuccessContinuation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeRemoteFileBrowserDefaults(), serverProvider: { _ in nil })
        var events: [String] = []

        // Given a RemoteFiles mutation whose async operation fails before it
        // can safely update UI state.
        let requestID = store.requestMutation(
            operation: {
                events.append("operation-started")
                throw RemoteFileMutationIntentFailure()
            },
            onSuccess: {
                events.append("success")
            },
            onFailure: { error in
                events.append("failure-\(type(of: error))")
            }
        )
        await store.waitForMutationRequest(requestID)

        // Then the application store keeps the failure path ordered and removes
        // the tracked request only after the failure handler runs.
        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "failure-RemoteFileMutationIntentFailure"])
    }

    @Test
    func transferRequestTracksTaskProgressAndSuccessAfterOperation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeRemoteFileBrowserDefaults(), serverProvider: { _ in nil })
        let gate = RemoteFileMutationGate()
        var events: [String] = []

        // Given a RemoteFiles transfer launched from synchronous UI intent.
        let requestID = store.requestTransfer(
            operation: { onProgress in
                events.append("operation-started")
                onProgress(RemoteFileBrowserStore.TransferProgress(
                    completedUnitCount: 1,
                    totalUnitCount: 2,
                    currentItemName: "logs.txt"
                ))
                await gate.wait()
                events.append("operation-finished")
                return "exported"
            },
            onProgress: { progress in
                events.append("progress-\(progress.completedUnitCount)-\(progress.totalUnitCount)-\(progress.currentItemName)")
            },
            onSuccess: { result in
                events.append("success-\(result)")
            },
            onFailure: { _ in
                events.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        // Then the application store owns the transfer task until the async
        // operation and success continuation finish.
        #expect(store.pendingTransferRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "progress-1-2-logs.txt"])

        await gate.release()
        await store.waitForTransferRequest(requestID)

        #expect(!store.pendingTransferRequestIDs.contains(requestID))
        #expect(events == [
            "operation-started",
            "progress-1-2-logs.txt",
            "operation-finished",
            "success-exported"
        ])
    }

    @Test
    func disconnectCancelsVisibleMutationRequestsForServerAndSkipsLateSuccess() async throws {
        let server = makeRemoteFileBrowserServer()
        let store = RemoteFileBrowserStore(defaults: makeRemoteFileBrowserDefaults(), serverProvider: { _ in nil })
        let gate = RemoteFileMutationGate()
        let waitProbe = RemoteFileWaitProbe()
        var operationEvents: [String] = []
        var callbackEvents: [String] = []

        // Given a same-server mutation is blocked in application-owned remote
        // work when the server disconnects.
        let requestID = store.requestMutation(
            serverId: server.id,
            operation: {
                operationEvents.append("operation-started")
                await gate.wait()
                operationEvents.append("operation-finished")
                return "created"
            },
            onSuccess: { result in
                callbackEvents.append("success-\(result)")
            },
            onFailure: { _ in
                callbackEvents.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.pendingMutationRequestIDs.contains(requestID))

        // When the same server disconnects before the operation exits.
        _ = store.disconnect(serverId: server.id)
        let waitTask = Task {
            await store.waitForMutationRequest(requestID)
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then visible pending state clears immediately, but the wait hook
        // remains awaitable until the blocked mutation operation exits.
        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(
            await !waitProbe.didReturn,
            "Canceled mutation wait hook should not return before blocked remote mutation work exits."
        )

        await gate.release()
        await waitTask.value

        #expect(await waitProbe.didReturn)
        #expect(operationEvents == ["operation-started", "operation-finished"])
        #expect(callbackEvents.isEmpty)
    }

    @Test
    func disconnectCancelsVisibleTransferRequestsForServerAndSkipsLateProgressAndSuccess() async throws {
        let server = makeRemoteFileBrowserServer()
        let store = RemoteFileBrowserStore(defaults: makeRemoteFileBrowserDefaults(), serverProvider: { _ in nil })
        let gate = RemoteFileMutationGate()
        let waitProbe = RemoteFileWaitProbe()
        var operationEvents: [String] = []
        var callbackEvents: [String] = []

        // Given a same-server transfer is blocked before emitting progress.
        let requestID = store.requestTransfer(
            serverId: server.id,
            operation: { onProgress in
                operationEvents.append("operation-started")
                await gate.wait()
                onProgress(RemoteFileBrowserStore.TransferProgress(
                    completedUnitCount: 1,
                    totalUnitCount: 2,
                    currentItemName: "logs.txt"
                ))
                operationEvents.append("operation-finished")
                return "exported"
            },
            onProgress: { progress in
                callbackEvents.append("progress-\(progress.completedUnitCount)-\(progress.totalUnitCount)-\(progress.currentItemName)")
            },
            onSuccess: { result in
                callbackEvents.append("success-\(result)")
            },
            onFailure: { _ in
                callbackEvents.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.pendingTransferRequestIDs.contains(requestID))

        // When the same server disconnects before the transfer exits.
        _ = store.disconnect(serverId: server.id)
        let waitTask = Task {
            await store.waitForTransferRequest(requestID)
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then visible pending state clears immediately, progress/success
        // callbacks are suppressed, and the wait hook remains awaitable.
        #expect(!store.pendingTransferRequestIDs.contains(requestID))
        #expect(
            await !waitProbe.didReturn,
            "Canceled transfer wait hook should not return before blocked remote transfer work exits."
        )

        await gate.release()
        await waitTask.value

        #expect(await waitProbe.didReturn)
        #expect(operationEvents == ["operation-started", "operation-finished"])
        #expect(callbackEvents.isEmpty)
    }

    @Test
    func disconnectLeavesOtherServerMutationAndTransferRequestsPending() async throws {
        let disconnectingServer = makeRemoteFileBrowserServer()
        let otherServer = makeRemoteFileBrowserServer()
        let store = RemoteFileBrowserStore(defaults: makeRemoteFileBrowserDefaults(), serverProvider: { _ in nil })
        let mutationGate = RemoteFileMutationGate()
        let transferGate = RemoteFileMutationGate()
        var events: [String] = []

        // Given mutation and transfer work belongs to a different server than
        // the one being disconnected.
        let mutationID = store.requestMutation(
            serverId: otherServer.id,
            operation: {
                await mutationGate.wait()
                return "mutated"
            },
            onSuccess: { events.append("mutation-\($0)") }
        )
        let transferID = store.requestTransfer(
            serverId: otherServer.id,
            operation: { _ in
                await transferGate.wait()
                return "transferred"
            },
            onSuccess: { events.append("transfer-\($0)") }
        )
        try await Task.sleep(for: .milliseconds(20))

        // When an unrelated server disconnects.
        _ = store.disconnect(serverId: disconnectingServer.id)

        // Then other-server work remains visible and completes normally.
        #expect(store.pendingMutationRequestIDs.contains(mutationID))
        #expect(store.pendingTransferRequestIDs.contains(transferID))

        await mutationGate.release()
        await transferGate.release()
        await store.waitForMutationRequest(mutationID)
        await store.waitForTransferRequest(transferID)

        #expect(events.count == 2)
        #expect(Set(events) == Set(["mutation-mutated", "transfer-transferred"]))
    }
}
