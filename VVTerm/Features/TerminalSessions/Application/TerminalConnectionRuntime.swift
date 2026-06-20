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

    private let clientFactory: @Sendable () -> any TerminalConnectionClient
    private var client: (any TerminalConnectionClient)?
    private var openTask: Task<UUID, Error>?
    private var openGeneration: UUID?
    private var shellId: UUID?
    private(set) var state: TerminalEntityConnectionState = .idle

    init(
        entityId: TerminalEntityID,
        clientFactory: @escaping @Sendable () -> any TerminalConnectionClient
    ) {
        self.entityId = entityId
        self.clientFactory = clientFactory
    }

    func open(configuration: TerminalConnectionConfiguration) async {
        if let openTask {
            _ = try? await openTask.value
            return
        }

        let client = client ?? clientFactory()
        self.client = client
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

        let openedShellId: UUID?
        if let pendingOpenTask {
            openedShellId = try? await pendingOpenTask.value
        } else {
            openedShellId = nil
        }

        state = .closing

        guard let client else {
            shellId = nil
            state = .disconnected
            return
        }

        let shellToClose = shellId ?? openedShellId
        shellId = nil
        if let shellToClose {
            await client.closeShell(shellToClose)
        }

        if mode == .fullDisconnect {
            await client.disconnect()
            self.client = nil
        }

        state = .disconnected
    }

    func suspend() async {
        openGeneration = nil
        openTask?.cancel()
        openTask = nil
        shellId = nil
        state = .suspended
    }

    func send(_ data: Data) async throws {
        guard let client, let shellId else {
            throw SSHError.notConnected
        }
        try await client.write(data, to: shellId)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard let client, let shellId else {
            throw SSHError.notConnected
        }
        try await client.resize(cols: cols, rows: rows, for: shellId)
    }
}
