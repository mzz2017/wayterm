import Foundation
import Testing

// Test Context:
// These tests protect Stats visibility/retry lifecycle ownership. SwiftUI may
// render cards, show errors, and send visible/hidden/retry/disappear intent,
// but ServerStatsCollector must own the async collection start/stop request
// tasks, cancellation ordering, and pending request visibility. The tests
// inspect source placement only; update them only if Stats request ownership
// intentionally moves to another non-UI application owner with equivalent
// awaitable close/retry ordering.
@Suite
struct ServerStatsIntentBoundaryTests {
    @Test
    func serverStatsViewSendsCollectionIntentInsteadOfOwningTasks() throws {
        // Given the Stats SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/Stats/UI/ServerStatsView.swift")
        )

        // Then visible, hidden, retry, and disappearance flows must send intent
        // to ServerStatsCollector request APIs instead of awaiting low-level
        // collection helpers from SwiftUI lifecycle callbacks.
        #expect(
            source.contains("requestStartCollecting(for: server, using: borrowedLeaseProvider())"),
            "Stats visible/retry intent should route through ServerStatsCollector.requestStartCollecting."
        )
        #expect(
            source.contains("requestStopCollecting()"),
            "Stats hidden/disappear intent should route through ServerStatsCollector.requestStopCollecting."
        )
        #expect(
            !containsRegex(#"Task\s*\{\s*await\s+statsCollector\.startCollecting"#, in: source),
            "ServerStatsView Retry must not own an async start task."
        )
        #expect(
            !containsRegex(#"\.task\s*\(\s*id:\s*makeTaskKey\(\)\s*\)\s*\{[\s\S]*await\s+statsCollector\.(startCollecting|stopCollectingAndWait)"#, in: source),
            "ServerStatsView visibility lifecycle must not directly await Stats start/stop helpers."
        )
        #expect(
            !containsRegex(#"await\s+statsCollector\.(startCollecting|stopCollectingAndWait)"#, in: source),
            "ServerStatsView should not directly await low-level Stats collection lifecycle helpers."
        )
    }

    @Test
    func serverStatsCollectorLifecycleIsOwnedOutsideUI() throws {
        // Given the Stats UI and terminal composition sources.
        let root = try sourceRoot()
        let statsViewSource = try source(
            at: root.appendingPathComponent("Waterm/Features/Stats/UI/ServerStatsView.swift")
        )
        let sharedTabSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )
        let iosLayerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/iOS/IOSTerminalContentLayer.swift")
        )

        // Then UI may observe and send intent, but it must not directly own or
        // construct the remote Stats collection lifecycle.
        #expect(
            statsViewSource.contains("@ObservedObject private var statsCollector: ServerStatsCollector"),
            "ServerStatsView should observe a collector owned by the Application layer."
        )
        #expect(
            !statsViewSource.contains("@StateObject private var statsCollector"),
            "ServerStatsView must not be the lifetime owner of remote Stats collection."
        )
        #expect(
            !containsRegex(#"StateObject\s*\(\s*wrappedValue:\s*statsCollector\s*\)"#, in: statsViewSource),
            "ServerStatsView must not wrap the injected collector in StateObject."
        )
        #expect(
            !sharedTabSource.contains("ServerStatsCollector(connectionProvider:"),
            "Shared terminal UI should not construct Stats collectors directly."
        )
        #expect(
            !iosLayerSource.contains("ServerStatsCollector(connectionProvider:"),
            "iOS terminal UI should not construct Stats collectors directly."
        )
    }

    @Test
    func appRootsInjectStatsRegistryIntoTerminalComposition() throws {
        // Given app composition sources.
        let root = try sourceRoot()
        let appSource = try source(at: root.appendingPathComponent("Waterm/App/WatermApp.swift"))
        let macRootSource = try source(at: root.appendingPathComponent("Waterm/App/ContentView.swift"))
        let iosRootSource = try source(at: root.appendingPathComponent("Waterm/App/iOS/iOSContentView.swift"))

        // Then the app root creates the non-UI Stats lifecycle owner and passes
        // it down as a dependency instead of letting leaf UI construct it.
        #expect(
            appSource.contains("ServerStatsCollectionRegistry"),
            "WatermApp should create the Application owner for Stats collection lifetimes."
        )
        #expect(
            macRootSource.contains("statsRegistry: statsRegistry"),
            "ContentView should inject the Stats registry into macOS terminal composition."
        )
        #expect(
            iosRootSource.contains("statsRegistry: statsRegistry"),
            "iOSContentView should inject the Stats registry into iOS terminal composition."
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

    private func containsRegex(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
