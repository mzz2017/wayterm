import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Servers application-layer owner for user-initiated
// connection tests from ServerFormSheet. Connection tests create temporary SSH
// transports and may run mosh bootstrap probes, so SwiftUI may build the draft
// server and credentials but must not own the async task or touch Core SSH
// services directly. Fakes keep all network work in memory; update this context
// only when server-form connection-test ownership intentionally moves to
// another application-layer owner.
@Suite(.serialized)
@MainActor
struct ServerConnectionTesterTests {
    @Test
    func connectionTestRequestTracksSuccessAndClearsPendingTask() async {
        // Given an application-layer connection tester backed by a delayed fake.
        let fake = DelayedServerConnectionTesting()
        let tester = ServerConnectionTester(connectionTesting: fake)
        let server = makeServer(host: "success.example.com")
        let credentials = ServerCredentials(serverId: server.id)
        var didSucceed = false
        var failure: Error?

        // When UI sends connection-test intent.
        let requestID = tester.requestConnectionTest(
            server: server,
            credentials: credentials,
            onSucceeded: { didSucceed = true },
            onFailed: { failure = $0 }
        )

        // Then the request remains tracked until the application-layer tester
        // finishes the temporary connection check.
        #expect(
            tester.pendingConnectionTestRequestIDs.contains(requestID),
            "Connection tests should be tracked while temporary SSH work is in flight."
        )
        await fake.waitUntilStarted()
        #expect(fake.requests.map(\.server.id) == [server.id])

        fake.finish()
        await tester.waitForConnectionTestRequest(requestID)

        #expect(!tester.pendingConnectionTestRequestIDs.contains(requestID))
        #expect(didSucceed)
        #expect(failure == nil)
        #expect(tester.connectionTestFailure == nil)
    }

    @Test
    func connectionTestRequestRecordsOrdinaryFailureAndSkipsSuccess() async {
        // Given a temporary connection check that fails before authentication
        // completes.
        let fake = DelayedServerConnectionTesting()
        let tester = ServerConnectionTester(connectionTesting: fake)
        let server = makeServer(host: "failure.example.com")
        let credentials = ServerCredentials(serverId: server.id)
        var didSucceed = false
        var failure: Error?

        // When UI sends connection-test intent.
        let requestID = tester.requestConnectionTest(
            server: server,
            credentials: credentials,
            onSucceeded: { didSucceed = true },
            onFailed: { failure = $0 }
        )
        await fake.waitUntilStarted()
        fake.finish(error: FakeConnectionTestError.rejected)
        await tester.waitForConnectionTestRequest(requestID)

        // Then failure remains distinguishable to the form and success is not
        // called as if the temporary connection had succeeded.
        #expect(!tester.pendingConnectionTestRequestIDs.contains(requestID))
        #expect(!didSucceed)
        #expect(failure is FakeConnectionTestError)
        #expect(tester.connectionTestFailure?.operation == .testConnection(server.id))
        #expect(tester.connectionTestFailure?.message.contains("rejected") == true)
    }

    @Test
    func connectionTestRequestTreatsCancellationAsCompletionWithoutFailure() async {
        // Given a temporary connection check cancelled by lifecycle teardown.
        let fake = DelayedServerConnectionTesting()
        let tester = ServerConnectionTester(connectionTesting: fake)
        let server = makeServer(host: "cancelled.example.com")
        let credentials = ServerCredentials(serverId: server.id)
        var didSucceed = false
        var failure: Error?
        var didComplete = false

        // When the connection-test owner observes cancellation.
        let requestID = tester.requestConnectionTest(
            server: server,
            credentials: credentials,
            onSucceeded: { didSucceed = true },
            onFailed: { failure = $0 },
            onCompleted: { didComplete = true }
        )
        await fake.waitUntilStarted()
        fake.finish(error: CancellationError())
        await tester.waitForConnectionTestRequest(requestID)

        // Then cancellation remains non-failure lifecycle state, while UI still
        // gets a completion signal to clear transient testing state.
        #expect(!tester.pendingConnectionTestRequestIDs.contains(requestID))
        #expect(!didSucceed)
        #expect(failure == nil)
        #expect(didComplete)
        #expect(tester.connectionTestFailure == nil)
    }

    @Test
    func connectionTestRequestCancellationClearsPendingAndSkipsLateSuccess() async {
        // Given a temporary connection check is in flight for a form draft that
        // may be edited before the request completes.
        let fake = DelayedServerConnectionTesting()
        let tester = ServerConnectionTester(connectionTesting: fake)
        let server = makeServer(host: "superseded-success.example.com")
        let credentials = ServerCredentials(serverId: server.id)
        var didSucceed = false
        var failure: Error?

        let requestID = tester.requestConnectionTest(
            server: server,
            credentials: credentials,
            onSucceeded: { didSucceed = true },
            onFailed: { failure = $0 }
        )
        await fake.waitUntilStarted()

        // When the form changes fields and cancels the active connection test.
        tester.cancelConnectionTestRequest(requestID)

        // Then the request is no longer visible as pending, and a later
        // successful temporary connection cannot write stale success state.
        #expect(!tester.pendingConnectionTestRequestIDs.contains(requestID))

        fake.finish()
        await tester.waitForConnectionTestRequest(requestID)

        #expect(!didSucceed)
        #expect(failure == nil)
        #expect(tester.connectionTestFailure == nil)
    }

    @Test
    func connectionTestRequestCancellationSkipsLateFailure() async {
        // Given a temporary connection check is in flight for a stale form
        // snapshot.
        let fake = DelayedServerConnectionTesting()
        let tester = ServerConnectionTester(connectionTesting: fake)
        let server = makeServer(host: "superseded-failure.example.com")
        let credentials = ServerCredentials(serverId: server.id)
        var didSucceed = false
        var failure: Error?

        let requestID = tester.requestConnectionTest(
            server: server,
            credentials: credentials,
            onSucceeded: { didSucceed = true },
            onFailed: { failure = $0 }
        )
        await fake.waitUntilStarted()

        // When the stale request is canceled before the fake operation reports
        // an ordinary failure.
        tester.cancelConnectionTestRequest(requestID)
        fake.finish(error: FakeConnectionTestError.rejected)
        await tester.waitForConnectionTestRequest(requestID)

        // Then cancellation wins over the late failure: no stale error is
        // surfaced to the form and no failure state is recorded.
        #expect(!tester.pendingConnectionTestRequestIDs.contains(requestID))
        #expect(!didSucceed)
        #expect(failure == nil)
        #expect(tester.connectionTestFailure == nil)
    }

    @Test
    func connectionTestRequestPassesMoshServerToInjectedTester() async {
        // Given a mosh-mode server draft and fake tester.
        let fake = DelayedServerConnectionTesting()
        let tester = ServerConnectionTester(connectionTesting: fake)
        let server = makeServer(host: "mosh.example.com", connectionMode: .mosh)
        let credentials = ServerCredentials(serverId: server.id)

        // When the form requests a connection test.
        let requestID = tester.requestConnectionTest(
            server: server,
            credentials: credentials
        )
        await fake.waitUntilStarted()
        fake.finish()
        await tester.waitForConnectionTestRequest(requestID)

        // Then the application owner preserves the server mode for the injected
        // connection-testing boundary where real mosh bootstrap probing lives.
        #expect(fake.requests.map(\.server.connectionMode) == [.mosh])
        #expect(fake.requests.map(\.credentials.serverId) == [server.id])
    }

    @Test
    func operationTesterUsesInjectedTemporaryConnectionAndMoshBootstrapper() async throws {
        // Given a live operation tester wired to in-memory SSH and mosh services.
        let connectionService = FakeServerConnectionOperationService()
        let moshBootstrapper = FakeServerConnectionMoshBootstrapper()
        let tester = ServerConnectionOperationTester(
            connectionService: connectionService,
            moshBootstrapper: moshBootstrapper
        )
        let server = makeServer(host: "mosh-service.example.com", connectionMode: .mosh)
        let credentials = ServerCredentials(serverId: server.id)

        // When a mosh-mode server connection test runs.
        try await tester.testConnection(server: server, credentials: credentials)

        // Then the tester delegates temporary SSH and mosh bootstrap work to
        // the injected services instead of resolving transport singletons at use.
        #expect(connectionService.requests.map(\.server.id) == [server.id])
        #expect(connectionService.requests.map(\.credentials.serverId) == [server.id])
        #expect(moshBootstrapper.requests.map(\.startCommand) == ["exec true"])
        #expect(moshBootstrapper.requests.map(\.portRange) == [60001...61000])
    }

    @Test
    func operationTesterSkipsMoshBootstrapperForStandardConnection() async throws {
        // Given a live operation tester wired to in-memory SSH and mosh services.
        let connectionService = FakeServerConnectionOperationService()
        let moshBootstrapper = FakeServerConnectionMoshBootstrapper()
        let tester = ServerConnectionOperationTester(
            connectionService: connectionService,
            moshBootstrapper: moshBootstrapper
        )
        let server = makeServer(host: "ssh-service.example.com", connectionMode: .standard)
        let credentials = ServerCredentials(serverId: server.id)

        // When a standard SSH connection test runs.
        try await tester.testConnection(server: server, credentials: credentials)

        // Then the temporary connection is still checked without doing mosh work.
        #expect(connectionService.requests.map(\.server.id) == [server.id])
        #expect(moshBootstrapper.requests.isEmpty)
    }

    private func makeServer(
        host: String,
        connectionMode: SSHConnectionMode = .standard
    ) -> Server {
        Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "Tencent",
            host: host,
            username: "root",
            connectionMode: connectionMode
        )
    }
}

@MainActor
private final class DelayedServerConnectionTesting: ServerConnectionTesting {
    struct Request {
        let server: Server
        let credentials: ServerCredentials
    }

    private(set) var requests: [Request] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var finishError: Error?
    private var hasStarted = false

    func testConnection(server: Server, credentials: ServerCredentials) async throws {
        requests.append(Request(server: server, credentials: credentials))
        hasStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }

        if let finishError {
            throw finishError
        }
    }

    func waitUntilStarted() async {
        if hasStarted {
            return
        }

        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func finish(error: Error? = nil) {
        finishError = error
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private enum FakeConnectionTestError: LocalizedError {
    case rejected

    var errorDescription: String? {
        "connection rejected"
    }
}

private final class FakeServerConnectionOperationService: ServerConnectionOperationServing {
    struct Request {
        let server: Server
        let credentials: ServerCredentials
    }

    private(set) var requests: [Request] = []

    func withTemporaryConnection<T: Sendable>(
        server: Server,
        credentials: ServerCredentials,
        operation: @Sendable @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        requests.append(Request(server: server, credentials: credentials))
        return try await operation(SSHClient())
    }
}

private final class FakeServerConnectionMoshBootstrapper: ServerConnectionMoshBootstrapping, @unchecked Sendable {
    struct Request: Sendable {
        let startCommand: String?
        let portRange: ClosedRange<Int>
    }

    private let lock = NSLock()
    private var requestStorage: [Request] = []

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func bootstrapConnectInfo(
        using executor: any RemoteCommandExecuting,
        startCommand: String?,
        portRange: ClosedRange<Int>
    ) async throws {
        record(Request(startCommand: startCommand, portRange: portRange))
    }

    private func record(_ request: Request) {
        lock.lock()
        requestStorage.append(request)
        lock.unlock()
    }
}
