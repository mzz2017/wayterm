import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect RemoteFiles application-layer lifecycle ownership for
// service disconnect serialization, mutation requests, and transfer requests.
// The fake clients and gates block remote work deterministically; failures
// usually mean UI intent can outlive, race, or bypass RemoteFileBrowserStore as
// the owner of async work. Update this context only when RemoteFiles request
// lifecycle ownership intentionally moves to another Application/Infrastructure
// owner with equivalent cancel, wait, and disconnect serialization semantics.
@MainActor
struct RemoteFileBrowserRequestLifecycleTests {
    @Test
    func sameServerOperationWaitsForDroppedDisconnectTask() async throws {
        let defaults = makeRemoteFileBrowserDefaults()
        let server = makeRemoteFileBrowserServer()
        let disconnectingClient = await BlockingDisconnectRemoteFileClient()
        let nextClient = await BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [disconnectingClient, nextClient]
        let operationProbe = RemoteFileBrowserOperationProbe()
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(defaults: defaults),
            remoteFileServiceAccess: SSHSFTPAdapter(
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
        let firstClient = await BlockingDisconnectRemoteFileClient()
        let secondClient = await BlockingDisconnectRemoteFileClient()
        let thirdClient = await BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [firstClient, secondClient, thirdClient]
        let operationProbe = RemoteFileBrowserOperationProbe()
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(defaults: defaults),
            remoteFileServiceAccess: SSHSFTPAdapter(
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
        let store = RemoteFileBrowserStore(persistedStateStore: makeRemoteFileBrowserPersistedStateStore(), serverProvider: { _ in nil })
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
        let store = RemoteFileBrowserStore(persistedStateStore: makeRemoteFileBrowserPersistedStateStore(), serverProvider: { _ in nil })
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
        let store = RemoteFileBrowserStore(persistedStateStore: makeRemoteFileBrowserPersistedStateStore(), serverProvider: { _ in nil })
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
        let store = RemoteFileBrowserStore(persistedStateStore: makeRemoteFileBrowserPersistedStateStore(), serverProvider: { _ in nil })
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
        let store = RemoteFileBrowserStore(persistedStateStore: makeRemoteFileBrowserPersistedStateStore(), serverProvider: { _ in nil })
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
    func cancelTransferRequestByIDHidesCallbacksButWaitsForOperationExit() async throws {
        let store = RemoteFileBrowserStore(persistedStateStore: makeRemoteFileBrowserPersistedStateStore(), serverProvider: { _ in nil })
        let gate = RemoteFileMutationGate()
        let waitProbe = RemoteFileWaitProbe()
        var operationEvents: [String] = []
        var callbackEvents: [String] = []

        let requestID = store.requestTransfer(
            operation: { onProgress in
                operationEvents.append("operation-started")
                await gate.wait()
                onProgress(RemoteFileBrowserStore.TransferProgress(
                    completedUnitCount: 1,
                    totalUnitCount: 1,
                    currentItemName: "export.txt"
                ))
                operationEvents.append("operation-finished")
                return "exported"
            },
            onProgress: { progress in
                callbackEvents.append("progress-\(progress.currentItemName)")
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

        // Given a system file-promise Progress cancel maps to a specific
        // store-owned transfer request.
        let canceledTask = store.cancelTransferRequest(requestID)
        let waitTask = Task {
            await store.waitForTransferRequest(requestID)
            await waitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then the request is no longer visible, but teardown remains
        // awaitable until the underlying transfer exits.
        #expect(canceledTask != nil)
        #expect(!store.pendingTransferRequestIDs.contains(requestID))
        #expect(
            await !waitProbe.didReturn,
            "Canceled transfer wait hook should not return before blocked remote transfer work exits."
        )

        await gate.release()
        await canceledTask?.value
        await waitTask.value

        #expect(await waitProbe.didReturn)
        #expect(operationEvents == ["operation-started", "operation-finished"])
        #expect(callbackEvents.isEmpty)
    }

    @Test
    func disconnectWaitsForCanceledTransferToExitBeforeDisconnectingService() async throws {
        let defaults = makeRemoteFileBrowserDefaults()
        let server = makeRemoteFileBrowserServer()
        let client = await BlockingDisconnectRemoteFileClient()
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(defaults: defaults),
            remoteFileServiceAccess: SSHSFTPAdapter(
                credentialsProvider: { server in makeRemoteFileBrowserCredentials(serverId: server.id) },
                ownedClientFactory: {
                    client
                }
            ),
            serverProvider: { _ in nil }
        )
        let gate = RemoteFileMutationGate()
        let disconnectWaitProbe = RemoteFileWaitProbe()

        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        let transferID = store.requestTransfer(
            serverId: server.id,
            operation: { _ in
                await gate.wait()
                return "uploaded"
            },
            onSuccess: { _ in
                Issue.record("Canceled transfer should not publish success after disconnect.")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        let disconnectTask = store.disconnect(serverId: server.id)
        let disconnectWaitTask = Task {
            await disconnectTask.value
            await disconnectWaitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(!store.pendingTransferRequestIDs.contains(transferID))
        #expect(
            await !client.hasStartedDisconnect(),
            "RemoteFiles disconnect should wait for canceled transfer work to exit before disconnecting the SFTP service."
        )
        #expect(
            await !disconnectWaitProbe.didReturn,
            "RemoteFiles disconnect task should not complete while canceled transfer work is still blocked."
        )

        await gate.release()
        await client.waitUntilDisconnectStarted()
        await client.releaseDisconnect()
        await disconnectWaitTask.value

        #expect(await disconnectWaitProbe.didReturn)
    }

    @Test
    func disconnectAllCancelsAllTransfersAndWaitsBeforeDisconnectingServices() async throws {
        let defaults = makeRemoteFileBrowserDefaults()
        let firstServer = makeRemoteFileBrowserServer()
        let secondServer = makeRemoteFileBrowserServer()
        let firstClient = await BlockingDisconnectRemoteFileClient()
        let secondClient = await BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [firstClient, secondClient]
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(defaults: defaults),
            remoteFileServiceAccess: SSHSFTPAdapter(
                credentialsProvider: { server in makeRemoteFileBrowserCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            ),
            serverProvider: { _ in nil }
        )
        let firstGate = RemoteFileMutationGate()
        let secondGate = RemoteFileMutationGate()
        let disconnectWaitProbe = RemoteFileWaitProbe()

        // Given RemoteFiles has active SFTP clients and transfers for multiple
        // servers.
        _ = try await store.withRemoteFileService(for: firstServer) { service in
            try await service.resolveHomeDirectory()
        }
        _ = try await store.withRemoteFileService(for: secondServer) { service in
            try await service.resolveHomeDirectory()
        }
        let firstTransferID = store.requestTransfer(
            serverId: firstServer.id,
            operation: { _ in
                await firstGate.wait()
                return "first"
            },
            onSuccess: { _ in
                Issue.record("Canceled first transfer should not publish success after disconnectAll.")
            }
        )
        let secondTransferID = store.requestTransfer(
            serverId: secondServer.id,
            operation: { _ in
                await secondGate.wait()
                return "second"
            },
            onSuccess: { _ in
                Issue.record("Canceled second transfer should not publish success after disconnectAll.")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        // When app-level teardown disconnects all RemoteFiles resources.
        let disconnectTask = store.disconnectAll()
        let disconnectWaitTask = Task {
            await disconnectTask.value
            await disconnectWaitProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then visible transfer state clears, but SFTP disconnect waits until
        // canceled transfer work exits.
        #expect(!store.pendingTransferRequestIDs.contains(firstTransferID))
        #expect(!store.pendingTransferRequestIDs.contains(secondTransferID))
        let firstDisconnectStartedBeforeRelease = await firstClient.hasStartedDisconnect()
        let secondDisconnectStartedBeforeRelease = await secondClient.hasStartedDisconnect()
        #expect(
            !firstDisconnectStartedBeforeRelease && !secondDisconnectStartedBeforeRelease,
            "RemoteFiles disconnectAll should wait for all canceled transfers before disconnecting SFTP services."
        )
        #expect(
            await !disconnectWaitProbe.didReturn,
            "RemoteFiles disconnectAll task should not complete while canceled transfer work is still blocked."
        )

        await firstGate.release()
        await secondGate.release()
        await firstClient.waitUntilDisconnectStarted()
        await secondClient.waitUntilDisconnectStarted()
        await firstClient.releaseDisconnect()
        await secondClient.releaseDisconnect()
        await disconnectWaitTask.value

        #expect(await disconnectWaitProbe.didReturn)
    }

    @Test
    func disconnectLeavesOtherServerMutationAndTransferRequestsPending() async throws {
        let disconnectingServer = makeRemoteFileBrowserServer()
        let otherServer = makeRemoteFileBrowserServer()
        let store = RemoteFileBrowserStore(persistedStateStore: makeRemoteFileBrowserPersistedStateStore(), serverProvider: { _ in nil })
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
