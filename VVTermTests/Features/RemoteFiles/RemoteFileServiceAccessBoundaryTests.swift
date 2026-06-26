import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFiles service-access ownership.
// RemoteFileBrowserStore may coordinate browser state and user intent, but the
// SFTP adapter and pending-disconnect gate should live behind an Application
// coordinator so reconnect/disconnect ordering has one stable service owner.
// Update these tests only when the service-access owner intentionally changes.

struct RemoteFileServiceAccessBoundaryTests {
    @Test
    func browserStoreDoesNotOwnPendingDisconnectGate() throws {
        let root = try sourceRoot()
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let coordinatorSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileServiceAccessCoordinator.swift")
        )

        // Given RemoteFiles needs to wait for dropped same-server disconnects
        // before starting fresh SFTP work.
        #expect(!storeSource.contains("private var pendingDisconnects"))
        #expect(!storeSource.contains("private struct PendingDisconnect"))
        #expect(!storeSource.contains("func waitForPendingDisconnect"))

        // Then one Application service owner holds the SFTP adapter and gate.
        #expect(coordinatorSource.contains("final class RemoteFileServiceAccessCoordinator"))
        #expect(coordinatorSource.contains("private let remoteFileServiceAdapter"))
        #expect(coordinatorSource.contains("private var pendingDisconnects"))
        #expect(coordinatorSource.contains("func withRemoteFileService"))
        #expect(coordinatorSource.contains("func disconnect(serverId"))
    }

    @Test
    func browserStoreReceivesServerLookupFromAppBoundary() throws {
        let root = try sourceRoot()
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let appSource = try source(
            at: root.appendingPathComponent("VVTerm/App/VVTermApp.swift")
        )

        // Given RemoteFiles needs server metadata to start browser work.
        #expect(storeSource.contains("typealias ServerProvider"))
        #expect(storeSource.contains("let serverProvider: ServerProvider"))
        #expect(storeSource.contains("serverProvider: @escaping ServerProvider,"))

        // Then the RemoteFiles feature must not reach across into Servers'
        // shared manager; App composition wires that dependency explicitly.
        #expect(!storeSource.contains("ServerManager.shared"))
        #expect(!storeSource.contains("serverProvider: @escaping ServerProvider ="))
        #expect(appSource.contains("serverProvider: { serverId in"))
        #expect(appSource.contains("ServerManager.shared.servers.first { $0.id == serverId }"))
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

    private enum SourceRootError: Error {
        case notFound
    }
}
