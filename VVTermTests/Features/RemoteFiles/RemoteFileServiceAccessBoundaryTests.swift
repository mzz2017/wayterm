import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFiles Application ownership.
// RemoteFiles may coordinate browser/tab state and user intent, but service
// access, pending-disconnect gates, and cross-feature policy inputs should be
// owned behind explicit Application or App-composition boundaries.
// Update these tests only when those owners intentionally change.

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

    @Test
    func tabManagerReceivesEntitlementPolicyFromAppBoundary() throws {
        let root = try sourceRoot()
        let tabManagerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileTabManager.swift")
        )
        let appSource = try source(
            at: root.appendingPathComponent("VVTerm/App/VVTermApp.swift")
        )

        // Given RemoteFiles must enforce file-tab limits.
        #expect(tabManagerSource.contains("typealias IsProProvider"))
        #expect(tabManagerSource.contains("private let isProProvider"))
        #expect(tabManagerSource.contains("isProProvider: @escaping IsProProvider"))

        // Then Store entitlement state stays outside the RemoteFiles feature
        // and is wired from App composition.
        #expect(!tabManagerSource.contains("StoreManager.shared"))
        #expect(appSource.contains("RemoteFileTabManager("))
        #expect(appSource.contains("isProProvider: { StoreManager.shared.isPro }"))
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
