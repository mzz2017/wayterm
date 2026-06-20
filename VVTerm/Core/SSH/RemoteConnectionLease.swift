import Foundation

enum RemoteConnectionLeaseOwnership: Equatable, Sendable {
    case borrowed
    case owned
}

nonisolated protocol RemoteConnectionLeaseClient: AnyObject, RemoteCommandExecuting {
    func upload(
        _ data: Data,
        to path: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws
    func disconnect() async
}

struct RemoteConnectionLease: Sendable {
    let client: any RemoteConnectionLeaseClient
    let ownership: RemoteConnectionLeaseOwnership
    private let state: RemoteConnectionLeaseState

    var commandExecutor: any RemoteCommandExecuting {
        client
    }

    init(
        client: any RemoteConnectionLeaseClient,
        ownership: RemoteConnectionLeaseOwnership
    ) {
        self.client = client
        self.ownership = ownership
        self.state = RemoteConnectionLeaseState()
    }

    func close() async {
        await state.close(client: client, ownership: ownership)
    }
}

extension SSHClient: RemoteConnectionLeaseClient {}

private actor RemoteConnectionLeaseState {
    private var didClose = false

    func close(
        client: any RemoteConnectionLeaseClient,
        ownership: RemoteConnectionLeaseOwnership
    ) async {
        guard !didClose else { return }
        didClose = true

        guard ownership == .owned else { return }
        await client.disconnect()
    }
}
