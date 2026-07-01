import Foundation
import MoshCore
import Testing
@testable import VVTerm

// Test Context:
// These tests protect small SSHClient support owners after they were moved out
// of SSHClient.swift. They avoid real SSH/network I/O; registry tests only use
// detached task bookkeeping and should be updated only if teardown tracking
// ownership intentionally changes.

struct SSHClientSupportOwnerTests {
    @Test
    func abortStateTracksAbortAndResetWithoutSession() {
        let state = SSHClientAbortState()

        // Given a fresh abort state.
        #expect(!state.isAborted)

        // When abort is requested without a registered session.
        state.abort()

        // Then the state records abort intent and reset clears it.
        #expect(state.isAborted)
        state.reset()
        #expect(!state.isAborted)
    }

    @Test
    func channelCleanupRegistryPublishesTaskBeforeTrackReturns() async {
        let registry = SSHChannelCleanupTaskRegistry()
        let gate = TeardownGate()

        // When a channel cleanup operation is tracked from a synchronous
        // stream-termination callback.
        registry.track {
            await gate.wait()
        }

        // Then the pending task is visible immediately, so a concurrent
        // disconnect wait cannot incorrectly observe no registered cleanup.
        #expect(registry.tasks().count == 1, "Channel cleanup task should be published before track returns.")

        // And completing the operation removes it from the registry.
        await gate.open()
        for _ in 0..<20 where !registry.tasks().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(registry.tasks().isEmpty, "Registry should remove completed cleanup tasks.")
    }

    @Test
    func moshTeardownRegistryPublishesTaskBeforeTrackReturns() async {
        let registry = SSHMoshTeardownTaskRegistry()
        let gate = TeardownGate()

        // When a mosh teardown operation is tracked from a synchronous
        // stream-termination callback.
        registry.track {
            await gate.wait()
        }

        // Then the pending task is visible immediately, so disconnect cannot
        // incorrectly observe no registered teardown.
        #expect(registry.tasks().count == 1, "Mosh teardown task should be published before track returns.")

        // And completing the operation removes it from the registry.
        await gate.open()
        for _ in 0..<20 where !registry.tasks().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(registry.tasks().isEmpty, "Registry should remove completed teardown tasks.")
    }

    @Test
    func moshShellRuntimeCancelsAndClearsStreamTask() async {
        let runtime = SSHMoshShellRuntime(
            session: MoshClientSession(
                endpoint: MoshEndpoint(host: "127.0.0.1", port: 60001, keyBase64_22: "abcdefghijklmnopqrstuv")
            )
        )
        let cancellationRecorder = TaskCancellationRecorder()
        let streamTask = Task {
            await cancellationRecorder.waitForCancellation()
        }

        // Given a Mosh shell runtime owns the host stream task.
        runtime.setStreamTask(streamTask)

        // When disconnect or stream termination cancels the runtime stream.
        runtime.cancelStreamTask()

        // Then the task is canceled and the runtime forgets it so repeated
        // teardown cannot retain or cancel stale stream work.
        for _ in 0..<20 where !(await cancellationRecorder.didCancel) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cancellationRecorder.didCancel)
        #expect(runtime.streamTaskForTesting == nil)
    }

    @Test
    func pendingConnectCoordinatorPublishesCurrentSessionAndCancelsForDisconnect() {
        let coordinator = SSHPendingConnectCoordinator()
        let requestID = UUID()
        let staleRequestID = UUID()
        let session = SSHSession(config: .libSSH2LifecycleTest)
        let staleSession = SSHSession(config: .libSSH2LifecycleTest)
        let task = Task<SSHSession, Error> {
            try await Task.sleep(for: .seconds(30))
            return session
        }
        defer {
            task.cancel()
        }

        // Given a pending connect request is the current owner.
        coordinator.begin(requestID: requestID, task: task)

        // When an older request tries to publish a session.
        let didRegisterStaleSession = coordinator.register(
            staleSession,
            requestID: staleRequestID
        )

        // Then stale sessions are rejected and only the active request can
        // publish the abortable pending session.
        #expect(!didRegisterStaleSession)
        #expect(coordinator.register(session, requestID: requestID))
        #expect(coordinator.isCurrentRequest(requestID))
        #expect(coordinator.isCurrentSession(session))
        #expect(!coordinator.isCurrentSession(staleSession))

        // And disconnect atomically detaches ownership, cancels the task, and
        // exposes whether pending session cleanup must be awaited.
        let snapshot = coordinator.cancelForDisconnect()
        #expect(snapshot.shouldWaitForPendingSessionCleanup)
        #expect(snapshot.task != nil)
        #expect(snapshot.session.map(ObjectIdentifier.init) == ObjectIdentifier(session))
        #expect(task.isCancelled)
        #expect(!coordinator.isCurrentRequest(requestID))
        #expect(!coordinator.isCurrentSession(session))
    }

    @Test
    func pendingConnectCleanupCancelsUnfinishedTaskOnTimeout() async {
        let cleanup = SSHPendingConnectCleanup(timeout: .milliseconds(20))
        let cancellationRecorder = TaskCancellationRecorder()
        let task = Task<SSHSession, Error> {
            await cancellationRecorder.waitForCancellation()
            throw CancellationError()
        }

        // Given a pending connect task does not finish before disconnect
        // cleanup's timeout.
        await cleanup.waitForPendingTask(task)

        // Then cleanup cancels the task so the connect path cannot keep running
        // after SSHClient disconnect has moved on.
        for _ in 0..<20 where !(await cancellationRecorder.didCancel) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(task.isCancelled)
        #expect(await cancellationRecorder.didCancel)
    }

    @Test
    func keepAliveCoordinatorIgnoresSupersededLoopAndClearsOnCancel() async {
        let sleepSequence = KeepAliveSleepSequence()
        let coordinator = SSHKeepAliveCoordinator { _ in
            await sleepSequence.sleep()
        }
        let recorder = KeepAliveRecorder()

        // Given a keepalive loop is sleeping when a newer loop replaces it.
        let firstRequestID = await coordinator.start(interval: 30) {
            await recorder.record("first")
        }
        await sleepSequence.waitForFirstStart()

        let secondRequestID = await coordinator.start(interval: 30) {
            await recorder.record("second")
        }
        await sleepSequence.waitForSecondStart()

        // Then only the latest loop remains owned.
        #expect(firstRequestID != secondRequestID)
        #expect(await coordinator.pendingRequestIDs == [secondRequestID])

        // When the superseded sleep completes late.
        await sleepSequence.releaseFirst()
        await Task.yield()

        // Then stale keepalive work must not run.
        #expect(await recorder.values == [])
        #expect(await coordinator.pendingRequestIDs == [secondRequestID])

        await sleepSequence.releaseSecond()
        for _ in 0..<20 where await recorder.values.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        await coordinator.cancelAllAndWait()
        let recordedValues = await recorder.values
        #expect(recordedValues.contains("second"))
        #expect(!recordedValues.contains("first"))
        #expect(await coordinator.pendingRequestIDs.isEmpty)
    }

    @Test
    func keepAliveLoopFactoryStopsBeforeOperationWhenCancelled() async {
        let sleepSequence = KeepAliveSleepSequence()
        let factory = SSHKeepAliveLoopFactory { _ in
            await sleepSequence.sleep()
        }
        let recorder = KeepAliveRecorder()
        let finishRecorder = KeepAliveRecorder()

        // Given a keepalive loop is sleeping before its first operation.
        let task = factory.makeLoop(
            interval: 30,
            shouldContinue: { true },
            operation: {
                await recorder.record("tick")
            },
            onFinished: {
                await finishRecorder.record("finished")
            }
        )
        await sleepSequence.waitForFirstStart()

        // When teardown cancels the loop before the sleep completes.
        task.cancel()
        await sleepSequence.releaseFirst()
        await task.value

        // Then the loop exits without sending a stale keepalive, while still
        // running its owner cleanup callback.
        #expect(await recorder.values == [])
        #expect(await finishRecorder.values == ["finished"])
    }

    @Test
    func moshShellStreamTerminationIsOwnedByClientTeardownRegistry() throws {
        let source = try source(at: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift"))
        let moshShellSource = try slice(
            startingAt: "private func startMoshShell(",
            endingBefore: "    nonisolated static func runWithTimeout",
            in: source
        )

        #expect(
            moshShellSource.contains("runtime.setStreamTask(streamTask)"),
            "Mosh host streams should publish their stream task through the runtime owner."
        )
        #expect(
            moshShellSource.contains("trackMoshTeardownTask"),
            "Mosh stream termination should register closeShell cleanup with SSHClient."
        )
        #expect(
            moshShellSource.contains("await self.closeShell(shellId)"),
            "Mosh stream completion should retain the SSHClient owner long enough to close the shell."
        )
        #expect(
            !moshShellSource.contains("Task { [weak self]"),
            "Mosh stream completion must not rely on weak self to perform lifecycle cleanup."
        )
        #expect(
            !moshShellSource.contains("await self?.closeShell(shellId)"),
            "Mosh closeShell cleanup must not silently disappear when a weak capture is nil."
        )
    }

    @Test
    func teardownRegistriesUseSharedCallbackTaskRegistryWithDetachedCleanup() throws {
        for path in [
            "VVTerm/Core/SSH/SSHChannelCleanupTaskRegistry.swift",
            "VVTerm/Core/SSH/SSHMoshTeardownTaskRegistry.swift"
        ] {
            let source = try source(at: sourceRoot().appendingPathComponent(path))

            #expect(
                source.contains("AsyncCallbackTaskRegistry"),
                "\(path) should delegate callback task bookkeeping to the shared lifecycle registry."
            )
            #expect(
                source.contains("trackDetached(operation)"),
                "\(path) should keep SSH cleanup detached from caller cancellation context."
            )
        }
    }
}

private actor TeardownGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor TaskCancellationRecorder {
    private(set) var didCancel = false

    func waitForCancellation() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        didCancel = true
    }
}

private actor KeepAliveSleepSequence {
    private let firstGate = TeardownGate()
    private let secondGate = TeardownGate()
    private var sleepCount = 0

    func sleep() async {
        sleepCount += 1
        if sleepCount == 1 {
            await firstGate.wait()
        } else {
            await secondGate.wait()
        }
    }

    func waitForFirstStart() async {
        await waitForStart(count: 1)
    }

    func waitForSecondStart() async {
        await waitForStart(count: 2)
    }

    func releaseFirst() async {
        await firstGate.open()
    }

    func releaseSecond() async {
        await secondGate.open()
    }

    private func waitForStart(count expectedCount: Int) async {
        for _ in 0..<20 where sleepCount < expectedCount {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor KeepAliveRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
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

private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker),
          let end = source[start.upperBound...].range(of: endMarker) else {
        throw SourceRootError.markerNotFound(marker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum SourceRootError: Error {
    case notFound
    case markerNotFound(String)
}
