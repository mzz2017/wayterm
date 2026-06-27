import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote connection lease ownership used by features that
// borrow live terminal SSH clients or create short-lived owned clients. The
// invariant is that closing a borrowed lease must not disconnect the underlying
// client, while closing an owned lease must await disconnect. Fakes are actor
// based and perform no network I/O. Update this context only if lease ownership
// semantics intentionally change.
struct RemoteConnectionLeaseTests {
    @Test
    func borrowedLeaseCloseDoesNotDisconnectClient() async {
        let client = RecordingRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .borrowed)

        await lease.close()

        let disconnectCount = await client.disconnectCount()
        #expect(disconnectCount == 0, "Borrowed leases must leave client lifetime with the stable owner")
    }

    @Test
    func ownedLeaseCloseDisconnectsClient() async {
        let client = RecordingRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .owned)

        await lease.close()

        let disconnectCount = await client.disconnectCount()
        #expect(disconnectCount == 1, "Owned leases must await underlying disconnect on close")
    }

    @Test
    func ownedLeaseCloseIsIdempotent() async {
        let client = RecordingRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .owned)

        await lease.close()
        await lease.close()

        let disconnectCount = await client.disconnectCount()
        #expect(disconnectCount == 1, "Repeated close calls must not disconnect the same lease more than once")
    }

    @Test
    func ownedLeaseConcurrentCloseDisconnectsClientOnce() async {
        let client = RecordingRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .owned)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await lease.close()
                }
            }
        }

        let disconnectCount = await client.disconnectCount()
        #expect(disconnectCount == 1, "Concurrent close calls must share the same owned disconnect")
    }

    @Test
    func concurrentCloseWaitsForDisconnectAlreadyInProgress() async throws {
        let client = BlockingDisconnectRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .owned)
        let secondClose = CloseCompletionProbe()

        let firstCloseTask = Task {
            await lease.close()
        }
        await client.waitUntilDisconnectStarted()

        let secondCloseTask = Task {
            await lease.close()
            await secondClose.markCompleted()
        }

        try await Task.sleep(for: .milliseconds(20))
        let didSecondCloseCompleteBeforeDisconnect = await secondClose.didComplete()
        #expect(
            !didSecondCloseCompleteBeforeDisconnect,
            "Concurrent close callers must wait for the in-flight owned disconnect to finish."
        )

        await client.releaseDisconnect()
        await firstCloseTask.value
        await secondCloseTask.value

        let disconnectCount = await client.disconnectCount()
        #expect(disconnectCount == 1, "Concurrent close callers should still share one owned disconnect.")
    }

    @Test
    func exclusiveOperationsForSameLeaseDoNotOverlap() async throws {
        let client = RecordingRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .borrowed)
        let probe = ExclusiveOperationProbe()

        async let first: Void = lease.withExclusiveClient { _ in
            await probe.runOperation()
        }
        async let second: Void = lease.withExclusiveClient { _ in
            await probe.runOperation()
        }

        try await first
        try await second

        let maxActiveOperations = await probe.maxActiveOperations()
        #expect(maxActiveOperations == 1, "Lease-protected operations must not overlap on the same client")
    }

    @Test
    func closeWaitsForExclusiveOperationBeforeDisconnectingOwnedClient() async throws {
        // Given an owned lease with one exclusive operation already in flight.
        let client = RecordingRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .owned)
        let blocker = BlockingOperationProbe()

        let operationTask = Task {
            try await lease.withExclusiveClient { _ in
                await blocker.markStarted()
                await blocker.waitUntilReleased()
            }
        }

        await blocker.waitUntilStarted()

        // When close starts while the operation is still active.
        let closeTask = Task {
            await lease.close()
        }

        try await Task.sleep(for: .milliseconds(20))
        let disconnectsBeforeRelease = await client.disconnectCount()
        #expect(disconnectsBeforeRelease == 0, "Owned disconnect must wait until the protected operation leaves the lease")

        await blocker.release()
        try await operationTask.value
        await closeTask.value

        let disconnectsAfterRelease = await client.disconnectCount()
        #expect(disconnectsAfterRelease == 1, "Owned close should disconnect once after the protected operation completes")
    }

    @Test
    func closeRejectsQueuedOperationsAfterCloseBegins() async throws {
        // Given an owned lease with one operation in flight and another operation waiting for exclusivity.
        let client = RecordingRemoteConnectionClient()
        let lease = RemoteConnectionLease(client: client, ownership: .owned)
        let blocker = BlockingOperationProbe()
        let queuedProbe = QueuedOperationProbe()

        let activeTask = Task {
            try await lease.withExclusiveClient { _ in
                await blocker.markStarted()
                await blocker.waitUntilReleased()
            }
        }

        await blocker.waitUntilStarted()

        let queuedTask = Task {
            try await lease.withExclusiveClient { _ in
                await queuedProbe.markRan()
            }
        }

        try await Task.sleep(for: .milliseconds(20))

        // When close begins before the queued operation has acquired the lease.
        let closeTask = Task {
            await lease.close()
        }

        try await Task.sleep(for: .milliseconds(20))
        await blocker.release()
        try await activeTask.value

        do {
            try await queuedTask.value
            Issue.record("Queued exclusive operations must be rejected once close begins")
        } catch is CancellationError {
            // Then the queued operation observes lifecycle cancellation instead of running against a closing client.
        }

        await closeTask.value

        let didRunQueuedOperation = await queuedProbe.didRun()
        #expect(!didRunQueuedOperation, "Queued operations must not run after lease close has started")

        let disconnectCount = await client.disconnectCount()
        #expect(disconnectCount == 1, "Owned close should still disconnect once after the active operation completes")
    }
}

private actor RecordingRemoteConnectionClient: RemoteConnectionLeaseClient {
    private var disconnects = 0

    func disconnect() async {
        disconnects += 1
    }

    func disconnectCount() -> Int {
        disconnects
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        ""
    }

    func upload(
        _ data: Data,
        to path: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        .fallbackPOSIX
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }
}

private actor BlockingDisconnectRemoteConnectionClient: RemoteConnectionLeaseClient {
    private var disconnects = 0
    private var didStartDisconnect = false
    private var didReleaseDisconnect = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func disconnect() async {
        disconnects += 1
        didStartDisconnect = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !didReleaseDisconnect else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilDisconnectStarted() async {
        if didStartDisconnect { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseDisconnect() {
        didReleaseDisconnect = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func disconnectCount() -> Int {
        disconnects
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        ""
    }

    func upload(
        _ data: Data,
        to path: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        .fallbackPOSIX
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }
}

private actor CloseCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func didComplete() -> Bool {
        completed
    }
}

private actor ExclusiveOperationProbe {
    private var activeOperations = 0
    private var maximumActiveOperations = 0

    func runOperation() async {
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        try? await Task.sleep(for: .milliseconds(20))
        activeOperations -= 1
    }

    func maxActiveOperations() -> Int {
        maximumActiveOperations
    }
}

private actor BlockingOperationProbe {
    private var didStart = false
    private var didRelease = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilReleased() async {
        if didRelease { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private actor QueuedOperationProbe {
    private var didRunOperation = false

    func markRan() {
        didRunOperation = true
    }

    func didRun() -> Bool {
        didRunOperation
    }
}
