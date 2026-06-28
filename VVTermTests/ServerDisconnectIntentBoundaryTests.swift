import Foundation
import Testing

// Test Context:
// These source-boundary tests protect server disconnect intent ownership for
// iOS Active Connections, iOS current-server disconnect, and shared tab
// container disconnect actions. The invariant is that SwiftUI sends synchronous
// intent to an injected App/Application owner; it must not own the async
// sequence that waits for RemoteFiles teardown, clears file tabs, disconnects
// terminal managers, and runs navigation completion. Update these tests only if
// that orchestration intentionally moves to another non-UI owner.
@Suite(.serialized)
struct ServerDisconnectIntentBoundaryTests {
    @Test
    func iosActiveConnectionDisconnectUsesApplicationCoordinator() throws {
        let root = try sourceRoot()
        let source = try source(at: root.appendingPathComponent("VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift"))
        let helper = try slice(
            startingAt: "private func disconnectActiveConnection",
            endingBefore: "private func server(for serverId:",
            in: source
        )

        // Given the iOS Active Connections disconnect action.
        #expect(
            source.contains("let disconnectCoordinator: ServerConnectionLifecycleCoordinator"),
            "iOSServerListView should receive the App/Application disconnect coordinator."
        )
        #expect(
            helper.contains("disconnectCoordinator.requestServerDisconnect"),
            "Active Connection disconnect should send intent to the injected App/Application coordinator."
        )
        #expect(
            !source.contains("ServerConnectionLifecycleCoordinator.shared"),
            "iOSServerListView should not resolve the App/Application disconnect coordinator singleton."
        )

        // Then SwiftUI must not own the async teardown sequence.
        #expect(!helper.containsRegex(#"Task\s*\{"#))
        #expect(!helper.contains("await sessionManager.disconnectServerAndWait"))
        #expect(!helper.contains("fileBrowser.disconnect"))
        #expect(!helper.contains("statsRegistry.disconnect"))
        #expect(!helper.contains("disconnectRemoteFiles"))
        #expect(!helper.contains("disconnectStats"))
    }

    @Test
    func iosCurrentServerDisconnectUsesApplicationCoordinator() throws {
        let root = try sourceRoot()
        let source = try source(at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift"))
        let helper = try slice(
            startingAt: "private func disconnectCurrentServerSessions",
            endingBefore: "private func synchronizeRecoveredTerminalState",
            in: source
        )

        // Given the iOS terminal current-server disconnect action.
        #expect(
            source.contains("let disconnectCoordinator: ServerConnectionLifecycleCoordinator"),
            "iOSTerminalView should receive the App/Application disconnect coordinator."
        )
        #expect(
            helper.contains("disconnectCoordinator.requestServerDisconnect"),
            "Current-server disconnect should send intent to the injected App/Application coordinator."
        )
        #expect(
            !source.contains("ServerConnectionLifecycleCoordinator.shared"),
            "iOSTerminalView should not resolve the App/Application disconnect coordinator singleton."
        )

        // Then SwiftUI must not sequence RemoteFiles, file tabs, terminal
        // disconnect, and navigation completion itself.
        #expect(!helper.containsRegex(#"Task\s*\{"#))
        #expect(!helper.contains("await sessionManager.disconnectServerAndWait"))
        #expect(!helper.contains("fileBrowser.disconnect"))
        #expect(!helper.contains("statsRegistry.disconnect"))
        #expect(!helper.contains("fileTabs.disconnect"))
        #expect(!helper.contains("disconnectRemoteFiles"))
        #expect(!helper.contains("disconnectStats"))
        #expect(!helper.contains("disconnectFileTabs"))
    }

    @Test
    func sharedTabContainerDisconnectUsesApplicationCoordinator() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )
        let helper = try slice(
            startingAt: "private func disconnectFromServer",
            endingBefore: "private func splitFocusedPane",
            in: source
        )

        // Given the shared tab-container server disconnect action.
        #expect(
            source.contains("let disconnectCoordinator: ServerConnectionLifecycleCoordinator"),
            "ConnectionTabsView should receive the App/Application disconnect coordinator."
        )
        #expect(
            helper.contains("disconnectCoordinator.requestServerDisconnect"),
            "Tab-container disconnect should send intent to the injected App/Application coordinator."
        )
        #expect(
            !source.contains("ServerConnectionLifecycleCoordinator.shared"),
            "ConnectionTabsView should not resolve the App/Application disconnect coordinator singleton."
        )

        // Then SwiftUI must not own the multi-feature teardown ordering.
        #expect(!helper.containsRegex(#"Task\s*\{"#))
        #expect(!helper.contains("await tabManager.disconnectServerAndWait"))
        #expect(!helper.contains("fileBrowser.disconnect"))
        #expect(!helper.contains("statsRegistry.disconnect"))
        #expect(!helper.contains("fileTabManager.disconnect"))
        #expect(!helper.contains("disconnectRemoteFiles"))
        #expect(!helper.contains("disconnectStats"))
        #expect(!helper.contains("disconnectFileTabs"))
    }

    @Test
    func appRootsInjectSharedDisconnectCoordinatorIntoFeatureUI() throws {
        let root = try sourceRoot()
        let appSource = try source(at: root.appendingPathComponent("VVTerm/App/VVTermApp.swift"))
        let macRootSource = try source(at: root.appendingPathComponent("VVTerm/App/ContentView.swift"))
        let iosRootSource = try source(at: root.appendingPathComponent("VVTerm/App/iOS/iOSContentView.swift"))

        // Given the disconnect coordinator owns multi-feature teardown ordering.
        #expect(
            appSource.contains("ServerConnectionLifecycleCoordinator.shared"),
            "VVTermApp should be the composition boundary that resolves the shared disconnect coordinator."
        )
        #expect(
            macRootSource.contains("disconnectCoordinator: disconnectCoordinator"),
            "ContentView should pass the injected disconnect coordinator into macOS terminal composition."
        )
        #expect(
            iosRootSource.contains("disconnectCoordinator: disconnectCoordinator"),
            "iOSContentView should pass the injected disconnect coordinator into iOS server and terminal composition."
        )
    }

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
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

    private enum SourceSliceError: Error {
        case notFound
    }
}

private extension String {
    func containsRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
