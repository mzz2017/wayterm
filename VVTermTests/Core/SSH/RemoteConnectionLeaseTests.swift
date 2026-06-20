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
