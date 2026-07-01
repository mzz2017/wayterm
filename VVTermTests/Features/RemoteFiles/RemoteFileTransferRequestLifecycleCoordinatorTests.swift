import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote-file transfer request ownership. Fakes avoid SFTP
// and filesystem calls; update only when transfer pending tracking, awaitable
// completion, explicit cancellation, or late server-binding cancellation
// semantics intentionally change.

@MainActor
struct RemoteFileTransferRequestLifecycleCoordinatorTests {
    @Test
    func transferRequestTracksUntilOperationCompletes() async {
        let gate = RemoteFileTransferRequestGate()
        var successes: [String] = []
        let coordinator = RemoteFileTransferRequestLifecycleCoordinator()

        // Given a transfer request starts and remains suspended in remote work.
        let requestID = coordinator.requestTransfer(serverIds: []) { _, _ in
            await gate.waitForRelease()
            return "uploaded"
        } onSuccess: { result in
            successes.append(result)
        }
        await gate.waitForOperationStart()

        // Then the transfer remains pending until the operation exits.
        #expect(coordinator.pendingRequestIDs == [requestID])

        await gate.release()
        await coordinator.waitForTransferRequest(requestID)

        #expect(successes == ["uploaded"])
        #expect(
            coordinator.pendingRequestIDs.isEmpty,
            "Transfer tracking should clear only after the operation completes."
        )
    }

    @Test
    func lateServerBindingAfterServerCancellationCancelsTransferWithoutSuccess() async {
        let bindGate = RemoteFileTransferRequestGate()
        let finishGate = RemoteFileTransferRequestGate()
        let serverID = UUID()
        var events: [String] = []
        let coordinator = RemoteFileTransferRequestLifecycleCoordinator()

        // Given a transfer starts before it knows every server it depends on.
        let requestID = coordinator.requestTransfer(serverIds: []) { _, bindServers in
            await bindGate.waitForRelease()
            bindServers([serverID])
            try Task.checkCancellation()
            await finishGate.waitForRelease()
            return "copied"
        } onSuccess: { result in
            events.append("success:\(result)")
        } onCancel: {
            events.append("cancel")
        }
        await bindGate.waitForOperationStart()

        // When that server is disconnected before the transfer late-binds to it.
        let canceledTasks = coordinator.cancelTransferRequests(for: serverID)
        #expect(canceledTasks.isEmpty)
        await bindGate.release()
        await coordinator.waitForTransferRequest(requestID)

        // Then the late bind cancels the transfer and suppresses success.
        #expect(events == ["cancel"])
        #expect(coordinator.pendingRequestIDs.isEmpty)
    }

    @Test
    func lateServerBindingCancellationRemainsAwaitableUntilOperationExits() async {
        let bindGate = RemoteFileTransferRequestGate()
        let finishGate = RemoteFileTransferRequestGate()
        let waitProbe = RemoteFileTransferRequestWaitProbe()
        let serverID = UUID()
        let coordinator = RemoteFileTransferRequestLifecycleCoordinator()

        // Given a transfer starts before it knows the remote server that will
        // own its eventual SFTP work.
        let requestID = coordinator.requestTransfer(serverIds: []) { _, bindServers in
            await bindGate.waitForRelease()
            bindServers([serverID])
            await finishGate.waitForRelease()
            try Task.checkCancellation()
            return "copied"
        } onSuccess: { _ in
            Issue.record("Canceled late-bound transfer should not publish success.")
        }
        await bindGate.waitForOperationStart()

        // When the server is disconnected before the transfer late-binds to it.
        let canceledTasks = coordinator.cancelTransferRequests(for: serverID)
        #expect(canceledTasks.isEmpty)
        await bindGate.release()

        let waitTask = Task {
            await coordinator.waitForTransferCancellationTasks()
            await waitProbe.markReturned()
        }
        try? await Task.sleep(for: .milliseconds(20))

        // Then cancellation completion should still be owned and awaitable
        // until the underlying transfer operation exits.
        #expect(
            await !waitProbe.didReturn,
            "Late server-binding cancellation must remain awaitable while transfer work is still blocked."
        )

        await finishGate.release()
        await coordinator.waitForTransferRequest(requestID)
        await waitTask.value

        #expect(await waitProbe.didReturn)
    }
}

private actor RemoteFileTransferRequestGate {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var isReleased = false

    func waitForOperationStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForRelease() async {
        guard !hasStarted else {
            await waitUntilReleased()
            return
        }

        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
        await waitUntilReleased()
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}

private actor RemoteFileTransferRequestWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}
