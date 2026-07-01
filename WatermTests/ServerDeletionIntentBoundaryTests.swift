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
            "Waterm/Features/Servers/UI/Sidebar/ServerSidebarRow.swift",
            "Waterm/Features/Servers/UI/iOS/iOSServerComponents.swift",
            "Waterm/Features/Servers/UI/iOS/iOSServerListView.swift",
            "Waterm/Features/Servers/UI/Workspace/WorkspaceSwitcherSheet.swift",
            "Waterm/Features/Servers/UI/Sidebar/ServerSidebarView.swift"
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
            at: root.appendingPathComponent("Waterm/Features/Servers/UI/iOS/iOSServerComponents.swift")
        )
        let listSource = try source(
            at: root.appendingPathComponent("Waterm/Features/Servers/UI/iOS/iOSServerListView.swift")
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
    func serverSidebarRowBelongsToServersFeatureAndUsesInjectedIntentClosures() throws {
        // Given server sidebar rows render Servers feature state and expose
        // actions used by the Servers feature sidebar.
        let root = try sourceRoot()
        let coreSidebarSource = try source(at: root.appendingPathComponent("Waterm/Core/UI/SidebarComponents.swift"))
        let rowSource = try source(at: root.appendingPathComponent("Waterm/Features/Servers/UI/Sidebar/ServerSidebarRow.swift"))
        let sidebarSource = try source(
            at: root.appendingPathComponent("Waterm/Features/Servers/UI/Sidebar/ServerSidebarView.swift")
        )

        // Then Core UI must not own server-specific sidebar presentation, and
        // the Servers feature row must receive derived state and intent
        // closures from the feature boundary instead of resolving application
        // managers directly.
        #expect(
            !coreSidebarSource.contains("struct ServerRow"),
            "Core/UI should not own server-specific sidebar rows."
        )
        #expect(
            !coreSidebarSource.contains("struct ServerRowDisplayModel"),
            "Core/UI should not own server-specific sidebar row display models."
        )
        #expect(
            !rowSource.contains("ServerManager.shared"),
            "ServerRow should not resolve the Servers application manager singleton."
        )
        #expect(
            !rowSource.contains("TerminalTabManager.shared"),
            "ServerRow should not resolve the TerminalSessions application manager singleton."
        )
        #expect(
            rowSource.contains("let isLocked: Bool"),
            "ServerRow should receive lock state as view data from the Servers feature boundary."
        )
        #expect(
            rowSource.contains("let tabCount: Int"),
            "ServerRow should receive tab count as view data from the TerminalSessions feature boundary."
        )
        #expect(
            !rowSource.contains("let server: Server"),
            "ServerRow should not store Servers feature domain models."
        )
        #expect(
            !rowSource.contains("(Server) -> Void"),
            "ServerRow intent closures should not expose Servers feature domain models."
        )
        #expect(
            rowSource.contains("struct ServerRowDisplayModel"),
            "ServerRow should render a neutral display model adapted by the Servers feature boundary."
        )
        #expect(
            sidebarSource.contains("isLocked: serverManager.isServerLocked(server)"),
            "ServerSidebarView should adapt ServerManager lock state before composing Core ServerRow."
        )
        #expect(
            sidebarSource.contains("tabCount: tabManager.tabs(for: server.id).count"),
            "ServerSidebarView should adapt TerminalTabManager tab state before composing Core ServerRow."
        )
        #expect(
            sidebarSource.contains("model: ServerRowDisplayModel("),
            "ServerSidebarView should adapt Server domain data into Core ServerRow display data."
        )
        #expect(
            sidebarSource.contains("onDelete: { serverManager.requestServerDeletion(server) }"),
            "ServerSidebarView should keep server deletion intent at the Servers feature boundary."
        )
    }

    @Test
    func appConfiguresDeletionTeardownThroughServerConnectionLifecycleOwner() throws {
        // Given the app root composes application-layer deletion dependencies.
        let root = try sourceRoot()
        let appSource = try source(at: root.appendingPathComponent("Waterm/App/WatermApp.swift"))

        // Then the app should configure deletion teardown through the server
        // lifecycle owner instead of implementing ad hoc terminal cleanup.
        #expect(
            appSource.contains("ServerConnectionLifecycleCoordinator.shared.disconnectServerBeforeDeletion"),
            "WatermApp should configure ServerManager deletion teardown through the App/Application lifecycle owner."
        )
        #expect(
            appSource.contains("serverConnectionLifecycleCoordinator.configureResourceDisconnects"),
            "WatermApp should configure live server-scoped resource teardown on the App/Application lifecycle owner."
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
            "WatermApp should not own the server deletion teardown implementation."
        )
        #expect(
            !appSource.contains("ConnectionSessionManager.shared.disconnectServerAndWait(server.id)"),
            "WatermApp should not directly disconnect connection sessions before server deletion."
        )
        #expect(
            !appSource.contains("TerminalTabManager.shared.disconnectServerAndWait(server.id)"),
            "WatermApp should not directly disconnect terminal tabs before server deletion."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
