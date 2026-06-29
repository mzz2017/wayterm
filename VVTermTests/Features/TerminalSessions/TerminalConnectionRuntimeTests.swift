import Foundation
import XCTest
@testable import VVTerm

// Test Context:
// These tests protect the first application-layer owner for terminal SSH
// lifecycles. The runtime must own a client and make close/suspend operations
// await underlying shell/open work before returning.
//
// Fakes and assumptions: RecordingTerminalSSHClient is an actor fake that
// records method ordering only. It does not open sockets, allocate libssh2
// resources, or run a terminal stream. Update these tests only if the runtime
// lifecycle contract intentionally changes.
final class TerminalConnectionRuntimeTests: XCTestCase {
    func testCloseWaitsForShellCloseAndDisconnect() async {
        let fake = RecordingTerminalSSHClient()
        let runtime = TerminalConnectionRuntime(entityId: .session(UUID()), clientFactory: { fake })

        await runtime.open(configuration: .testing)
        await runtime.close(mode: .fullDisconnect)

        let events = await fake.events
        XCTAssertEqual(events, ["connect", "startShell", "closeShell", "disconnect"])
    }

    func testCloseRunnerFullDisconnectCanLeaveRegisteredClientForExternalOwner() async throws {
        // Given a runner-backed SSH client and shell whose registered lifetime
        // will be closed by a separate owner after runtime cancellation.
        let client = SSHClient()
        let runtime = TerminalConnectionRuntime(
            entityId: .pane(UUID()),
            sshClientFactory: { client }
        )
        let shellId = UUID()

        _ = await runtime.runnerClient()
        await runtime.setShellId(shellId)

        // When runtime cancellation is part of a full pane close, but the
        // registered shell/client are intentionally left to the registry owner.
        await runtime.closeRunner(
            mode: .fullDisconnect,
            closeShell: false,
            disconnectClient: false
        )

        // Then the runtime releases its shell state without closing the shell
        // or disconnecting the still-registered client.
        let currentShellId = await runtime.currentShellId()
        let isRunnerClient = await runtime.isRunnerClient(client)
        let state = await runtime.state
        XCTAssertNil(currentShellId)
        XCTAssertTrue(isRunnerClient)
        XCTAssertEqual(state, .disconnected)
    }

    func testSuspendWaitsForStoredShellTaskToExit() async throws {
        let runtime = TerminalConnectionRuntime(entityId: .session(UUID()))
        let shellTaskGate = TerminalConnectionRuntimeGate()
        let suspendCompletion = TerminalConnectionRuntimeFlag()
        let shellTask = Task {
            await shellTaskGate.wait()
        }
        await runtime.setShellTask(shellTask)

        let suspendTask = Task {
            await runtime.suspend()
            await suspendCompletion.mark()
        }

        for _ in 0..<20 where await !suspendCompletion.isMarked() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let completedBeforeRelease = await suspendCompletion.isMarked()
        XCTAssertFalse(
            completedBeforeRelease,
            "suspend() must not report completion before the stored shell task exits."
        )

        await shellTaskGate.open()
        await suspendTask.value
        let completedAfterRelease = await suspendCompletion.isMarked()
        XCTAssertTrue(completedAfterRelease)
    }

    func testSuspendWaitsForInFlightOpenTaskToExit() async throws {
        // Given an open is blocked inside the runtime-owned client.
        let fake = RecordingTerminalSSHClient(connectGate: TerminalConnectionRuntimeGate())
        let runtime = TerminalConnectionRuntime(entityId: .session(UUID()), clientFactory: { fake })
        let openTask = Task {
            await runtime.open(configuration: .testing)
        }
        await fake.waitUntilConnectStarted()

        // When background suspend is requested while open is still in flight.
        let suspendCompletion = TerminalConnectionRuntimeFlag()
        let suspendTask = Task {
            await runtime.suspend()
            await suspendCompletion.mark()
        }

        for _ in 0..<20 where await !suspendCompletion.isMarked() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let completedBeforeConnectReleased = await suspendCompletion.isMarked()
        XCTAssertFalse(
            completedBeforeConnectReleased,
            "suspend() must not report completion before the in-flight open task exits."
        )

        await fake.releaseConnect()
        await openTask.value
        await suspendTask.value
        let completedAfterConnectReleased = await suspendCompletion.isMarked()
        XCTAssertTrue(completedAfterConnectReleased)
    }
}

private actor RecordingTerminalSSHClient: TerminalConnectionClient {
    private(set) var events: [String] = []
    private let shellId = UUID()
    private let connectGate: TerminalConnectionRuntimeGate?
    private var connectStartedContinuations: [CheckedContinuation<Void, Never>] = []

    init(connectGate: TerminalConnectionRuntimeGate? = nil) {
        self.connectGate = connectGate
    }

    func connect() async throws {
        events.append("connect")
        connectStartedContinuations.forEach { $0.resume() }
        connectStartedContinuations.removeAll()
        await connectGate?.wait()
    }

    func startShell() async throws -> UUID {
        events.append("startShell")
        return shellId
    }

    func closeShell(_ shellId: UUID) async {
        events.append("closeShell")
    }

    func disconnect() async {
        events.append("disconnect")
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        events.append("write")
    }

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {
        events.append("resize")
    }

    func waitUntilConnectStarted() async {
        if events.contains("connect") { return }
        await withCheckedContinuation { continuation in
            connectStartedContinuations.append(continuation)
        }
    }

    func releaseConnect() async {
        await connectGate?.open()
    }
}

private actor TerminalConnectionRuntimeGate {
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
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor TerminalConnectionRuntimeFlag {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
