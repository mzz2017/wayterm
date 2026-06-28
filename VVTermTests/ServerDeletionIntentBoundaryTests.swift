import Foundation
import Testing

// Test Context:
// These tests protect user-initiated server/workspace/environment deletion
// ownership at the UI/Application boundary. Server, workspace, and environment
// delete operations mutate local data and sync state, and some paths also tear
// down live runtime state, credentials, and known hosts, so UI files must send
// intent to the application-layer deletion request API instead of launching
// untracked tasks that swallow errors with try?. The tests inspect source
// placement only; update them only when destructive delete intent ownership
// intentionally moves to a different application-layer owner.
@Suite
struct ServerDeletionIntentBoundaryTests {
    @Test
    func destructiveDeletionUIUsesApplicationIntentRequests() throws {
        // Given server, workspace, and environment deletion entry points in
        // shared, macOS, and iOS UI.
        let root = try sourceRoot()
        let sources = try [
            "VVTerm/Core/UI/SidebarComponents.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerComponents.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift",
            "VVTerm/Features/Servers/UI/Workspace/WorkspaceSwitcherSheet.swift",
            "VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Then UI must not drop deletion errors by calling async delete methods
        // inside fire-and-forget try? tasks.
        #expect(
            !sources.contains("try? await ServerManager.shared.deleteServer"),
            "Server row deletion should call ServerManager.requestServerDeletion instead of swallowing deleteServer failures."
        )
        #expect(
            !sources.contains("try? await serverManager.deleteWorkspace"),
            "Workspace deletion UI should call ServerManager.requestWorkspaceDeletion instead of swallowing deleteWorkspace failures."
        )
        #expect(
            !sources.contains("try? await serverManager.deleteEnvironment"),
            "Environment deletion UI should call ServerManager.requestEnvironmentDeletion instead of swallowing deleteEnvironment failures."
        )
    }

    @Test
    func iosServerRowsUseInjectedServerManagerForDeletionIntent() throws {
        // Given iOS server rows own the destructive delete control surface.
        let root = try sourceRoot()
        let rowSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/iOS/iOSServerComponents.swift")
        )
        let listSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift")
        )

        // Then leaf row UI must use the app-owned ServerManager injected by the
        // list boundary instead of resolving shared state directly.
        #expect(
            rowSource.contains("@ObservedObject var serverManager: ServerManager"),
            "iOSServerRow should receive the Servers application manager from the list boundary."
        )
        #expect(
            listSource.contains("serverManager: serverManager"),
            "iOSServerListView should inject its app-owned ServerManager into iOSServerRow."
        )
        #expect(
            !rowSource.contains("ServerManager.shared"),
            "iOSServerRow should not resolve ServerManager.shared from leaf row UI."
        )
        #expect(
            rowSource.contains("serverManager.requestServerDeletion(server)"),
            "iOSServerRow should keep destructive delete actions routed through ServerManager's request API."
        )
    }

    @Test
    func appConfiguresDeletionTeardownThroughServerConnectionLifecycleOwner() throws {
        // Given the app root composes application-layer deletion dependencies.
        let root = try sourceRoot()
        let appSource = try source(at: root.appendingPathComponent("VVTerm/App/VVTermApp.swift"))

        // Then the app should configure deletion teardown through the server
        // lifecycle owner instead of implementing ad hoc terminal cleanup.
        #expect(
            appSource.contains("ServerConnectionLifecycleCoordinator.shared.disconnectServerBeforeDeletion"),
            "VVTermApp should configure ServerManager deletion teardown through the App/Application lifecycle owner."
        )
        #expect(
            appSource.contains("serverConnectionLifecycleCoordinator.configureResourceDisconnects"),
            "VVTermApp should configure live server-scoped resource teardown on the App/Application lifecycle owner."
        )
        #expect(
            appSource.contains("disconnectRemoteFiles: remoteFileBrowserStore.disconnect"),
            "Server deletion teardown should use the app-owned RemoteFiles browser store."
        )
        #expect(
            appSource.contains("disconnectStats: statsRegistry.disconnect"),
            "Server deletion teardown should use the app-owned Stats registry."
        )
        #expect(
            appSource.contains("disconnectFileTabs: remoteFileTabManager.disconnect"),
            "Server deletion teardown should use the app-owned RemoteFiles tab manager."
        )
        #expect(
            !appSource.contains("static func disconnectServerBeforeDeletion"),
            "VVTermApp should not own the server deletion teardown implementation."
        )
        #expect(
            !appSource.contains("ConnectionSessionManager.shared.disconnectServerAndWait(server.id)"),
            "VVTermApp should not directly disconnect connection sessions before server deletion."
        )
        #expect(
            !appSource.contains("TerminalTabManager.shared.disconnectServerAndWait(server.id)"),
            "VVTermApp should not directly disconnect terminal tabs before server deletion."
        )
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
