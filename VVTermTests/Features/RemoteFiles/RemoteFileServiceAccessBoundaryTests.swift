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
    func coreSSHDoesNotExposeRemoteFilesDomainTypes() throws {
        let root = try sourceRoot()
        let sshDirectory = root.appendingPathComponent("VVTerm/Core/SSH")
        let forbiddenFeatureDomainNames = [
            "RemoteFileBrowserError",
            "RemoteFileEntry",
            "RemoteFileFilesystemStatus",
            "RemoteFilePath",
            "RemoteFilePermissions",
            "RemoteFileType"
        ]

        for swiftFile in try swiftFiles(in: sshDirectory) {
            let source = try source(at: swiftFile)
            for forbiddenName in forbiddenFeatureDomainNames {
                #expect(
                    !source.contains(forbiddenName),
                    "Core/SSH should expose SSH/SFTP transport types, not RemoteFiles domain type \(forbiddenName), in \(swiftFile.lastPathComponent)."
                )
            }
        }
    }

    @Test
    func browserStoreDoesNotOwnPendingDisconnectGate() throws {
        let root = try sourceRoot()
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let coordinatorSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileServiceAccessCoordinator.swift")
        )
        let serviceAccessSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileServiceAccessing.swift")
        )
        let adapterSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift")
        )

        // Given RemoteFiles needs to wait for dropped same-server disconnects
        // before starting fresh SFTP work.
        #expect(!storeSource.contains("private var pendingDisconnects"))
        #expect(!storeSource.contains("private struct PendingDisconnect"))
        #expect(!storeSource.contains("func waitForPendingDisconnect"))
        #expect(!storeSource.contains("SSHSFTPAdapter"))

        // Then one Application service owner holds the pending-disconnect gate
        // through an explicit service access protocol, while Infrastructure
        // provides the concrete SFTP adapter.
        #expect(serviceAccessSource.contains("protocol RemoteFileServiceAccessing"))
        #expect(serviceAccessSource.contains("func withService"))
        #expect(serviceAccessSource.contains("func disconnect(serverId"))
        #expect(serviceAccessSource.contains("func disconnectAll() async"))
        #expect(coordinatorSource.contains("final class RemoteFileServiceAccessCoordinator"))
        #expect(coordinatorSource.contains("private let remoteFileServiceAccess: any RemoteFileServiceAccessing"))
        #expect(coordinatorSource.contains("private var pendingDisconnects"))
        #expect(coordinatorSource.contains("private var pendingDisconnectAll"))
        #expect(coordinatorSource.contains("func withRemoteFileService"))
        #expect(coordinatorSource.contains("func disconnect("))
        #expect(coordinatorSource.contains("func disconnectAll("))
        #expect(coordinatorSource.contains("waitingFor prerequisiteTasks: [Task<Void, Never>]"))
        #expect(!coordinatorSource.contains("SSHSFTPAdapter"))
        #expect(adapterSource.contains("extension SSHSFTPAdapter: RemoteFileServiceAccessing"))
        #expect(adapterSource.contains("func disconnectAll() async"))
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
    func sftpAdapterReceivesCredentialsFromAppBoundary() throws {
        let root = try sourceRoot()
        let adapterSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let appSource = try source(
            at: root.appendingPathComponent("VVTerm/App/VVTermApp.swift")
        )

        // Given SFTP work needs server credentials but RemoteFiles should not
        // own the Keychain dependency directly.
        #expect(adapterSource.contains("typealias CredentialsProvider"))
        #expect(adapterSource.contains("credentialsProvider: @escaping CredentialsProvider,"))
        #expect(!adapterSource.contains("KeychainManager.shared"))
        #expect(!storeSource.contains("KeychainManager.shared"))

        // Then App composition wires the concrete credential source.
        #expect(appSource.contains("credentialsProvider: { server in"))
        #expect(appSource.contains("try KeychainManager.shared.getCredentials(for: server)"))
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

    private func swiftFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
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
