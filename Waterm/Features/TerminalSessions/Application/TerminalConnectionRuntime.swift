import Foundation

protocol TerminalConnectionClient: Sendable {
    func connect() async throws
    func startShell() async throws -> UUID
    func closeShell(_ shellId: UUID) async
    func disconnect() async
    func write(_ data: Data, to shellId: UUID) async throws
    func resize(cols: Int, rows: Int, for shellId: UUID) async throws
}

struct TerminalConnectionConfiguration: Sendable {
    static let testing = TerminalConnectionConfiguration()
}

actor TerminalConnectionRuntime {
    let entityId: TerminalEntityID

    private let clientFactory: (@MainActor @Sendable () -> any TerminalConnectionClient)?
    private let sshClientFactory: @Sendable () -> SSHClient
    private var client: (any TerminalConnectionClient)?
    private var sshClient: SSHClient?
    private var openTask: Task<UUID, Error>?
    private var openGeneration: UUID?
    private var shellId: UUID?
    private var shellTask: Task<Void, Never>?
    private var lastSize: (cols: Int, rows: Int) = (0, 0)
    private(set) var state: TerminalEntityConnectionState = .idle

    init(
        entityId: TerminalEntityID,
        clientFactory: @escaping @MainActor @Sendable () -> any TerminalConnectionClient,
        sshClientFactory: @escaping @Sendable () -> SSHClient = { SSHClient() }
    ) {
        self.entityId = entityId
        self.clientFactory = clientFactory
        self.sshClientFactory = sshClientFactory
    }

    init(
        entityId: TerminalEntityID,
        sshClientFactory: @escaping @Sendable () -> SSHClient = { SSHClient() }
    ) {
        self.entityId = entityId
        self.clientFactory = nil
        self.sshClientFactory = sshClientFactory
    }

    func open(configuration: TerminalConnectionConfiguration) async {
        guard let clientFactory else {
            state = .failed("Runtime client factory is not configured")
            return
        }

        if let openTask {
            _ = try? await openTask.value
            return
        }

        let client: any TerminalConnectionClient
        if let existingClient = self.client {
            client = existingClient
        } else {
            let createdClient = await clientFactory()
            self.client = createdClient
            client = createdClient
        }
        let generation = UUID()
        openGeneration = generation
        state = .connecting

        let task = Task {
            try await client.connect()
            try Task.checkCancellation()
            return try await client.startShell()
        }
        openTask = task

        do {
            let openedShellId = try await task.value
            guard openGeneration == generation else {
                await client.closeShell(openedShellId)
                return
            }
            shellId = openedShellId
            state = .streaming
        } catch is CancellationError {
            if openGeneration == generation {
                state = .disconnected
            }
        } catch {
            if openGeneration == generation {
                state = .failed(error.localizedDescription)
            }
        }

        if openGeneration == generation {
            openTask = nil
        }
    }

    func close(mode: ShellTeardownMode) async {
        openGeneration = nil
        let pendingOpenTask = openTask
        openTask = nil
        pendingOpenTask?.cancel()

        let pendingShellTask = shellTask
        shellTask = nil
        pendingShellTask?.cancel()

        let openedShellId: UUID?
        if let pendingOpenTask {
            openedShellId = try? await pendingOpenTask.value
        } else {
            openedShellId = nil
        }

        state = .closing

        if let sshClient {
            let shellToClose = shellId ?? openedShellId
            shellId = nil
            if let shellToClose {
                await sshClient.closeShell(shellToClose)
            }
            if case .fullDisconnect = mode {
                await sshClient.disconnect()
                self.sshClient = nil
            }
            await pendingShellTask?.value
            state = .disconnected
            return
        }

        guard let client else {
            shellId = nil
            await pendingShellTask?.value
            state = .disconnected
            return
        }

        let shellToClose = shellId ?? openedShellId
        shellId = nil
        if let shellToClose {
            await client.closeShell(shellToClose)
        }

        if case .fullDisconnect = mode {
            await client.disconnect()
            self.client = nil
        }

        await pendingShellTask?.value
        state = .disconnected
    }

    func suspend() async {
        openGeneration = nil
        let pendingOpenTask = openTask
        openTask = nil
        pendingOpenTask?.cancel()
        let pendingShellTask = shellTask
        shellTask = nil
        pendingShellTask?.cancel()
        shellId = nil
        if let pendingOpenTask {
            _ = try? await pendingOpenTask.value
        }
        await pendingShellTask?.value
        state = .suspended
    }

    func send(_ data: Data) async throws {
        if let client, let shellId {
            try await client.write(data, to: shellId)
            return
        }

        if let sshClient, let shellId {
            try await sshClient.write(data, to: shellId)
            return
        }

        throw SSHError.notConnected
    }

    func resize(cols: Int, rows: Int) async throws {
        guard cols != lastSize.cols || rows != lastSize.rows else { return }
        lastSize = (cols, rows)

        if let client, let shellId {
            try await client.resize(cols: cols, rows: rows, for: shellId)
            return
        }

        if let sshClient, let shellId {
            try await sshClient.resize(cols: cols, rows: rows, for: shellId)
            return
        }

        throw SSHError.notConnected
    }

    func runnerClient() -> SSHClient {
        if let sshClient {
            return sshClient
        }
        let created = sshClientFactory()
        sshClient = created
        return created
    }

    func runnerClientIfCreated() -> SSHClient? {
        sshClient
    }

    func hasShellTask() -> Bool {
        shellTask != nil
    }

    func setShellTask(_ task: Task<Void, Never>) {
        shellTask = task
    }

    func installShellTask(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) {
        let task = Task.detached(priority: priority) {
            await operation()
        }
        shellTask = task
    }

    func clearShellTask(ifUsing client: SSHClient) {
        guard let sshClient, ObjectIdentifier(sshClient) == ObjectIdentifier(client) else { return }
        shellTask = nil
    }

    func setShellId(_ shellId: UUID?) {
        self.shellId = shellId
    }

    func currentShellId() -> UUID? {
        shellId
    }

    func updateLastSize(cols: Int, rows: Int) {
        lastSize = (cols, rows)
    }

    func markConnecting() {
        state = .connecting
    }

    func markStreaming() {
        state = .streaming
    }

    func markFailed(_ message: String) {
        state = .failed(message)
    }

    func markDisconnected() {
        state = .disconnected
    }

    func isRunnerClient(_ client: SSHClient) -> Bool {
        guard let sshClient else { return false }
        return ObjectIdentifier(sshClient) == ObjectIdentifier(client)
    }

    func closeRunner(
        mode: ShellTeardownMode,
        closeShell: Bool,
        disconnectClient: Bool? = nil
    ) async {
        let pendingShellTask = shellTask
        shellTask = nil
        pendingShellTask?.cancel()

        let shellToClose = shellId
        shellId = nil

        if closeShell, let shellToClose {
            await sshClient?.closeShell(shellToClose)
        }

        let shouldDisconnectClient = disconnectClient ?? {
            if case .fullDisconnect = mode {
                return true
            }
            return false
        }()
        if shouldDisconnectClient {
            await sshClient?.disconnect()
            sshClient = nil
        }

        await pendingShellTask?.value
        state = .disconnected
    }

    func ensureTestingClientFactoryConfigured() throws {
        guard clientFactory != nil else {
            throw SSHError.notConnected
        }
    }
}
