import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Active Connection open ownership.
// The invariant is that SwiftUI sends biometric unlock intent and then
// manager-owned active-connection open intent; it must not own the reconnect,
// session selection, or selected terminal-view update task. Update these tests
// only if that orchestration intentionally moves to another non-UI owner.
@Suite(.serialized)
struct IOSActiveConnectionOpenIntentBoundaryTests {
    @Test
    func iosActiveConnectionOpenUsesManagerRequestAfterUnlock() throws {
        let root = try sourceRoot()
        let source = try source(at: root.appendingPathComponent("VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift"))
        let helper = try slice(
            startingAt: "private func openActiveConnection(_ connection: ActiveConnection)",
            endingBefore: "\n    private func disconnectActiveConnection",
            in: source
        )

        // Given the iOS Active Connections open action.
        #expect(
            helper.contains("appLockManager.requestServerUnlock"),
            "Active Connection open should keep sending server-unlock intent before opening."
        )
        #expect(
            !source.contains("AppLockManager.shared"),
            "iOS Active Connection open UI should use the injected AppLockManager."
        )
        #expect(
            helper.contains("sessionManager.requestActiveConnectionOpen"),
            "Active Connection open should send reconnect/select intent to ConnectionSessionManager."
        )

        // Then SwiftUI must not own the reconnect/select async sequence.
        #expect(helper.range(of: #"Task\s*\{"#, options: .regularExpression) == nil)
        #expect(!helper.contains("reconnectSessionIfRuntimeInactive"))
    }

    @Test
    func iosActiveConnectionOpenUsesInjectedViewTabConfiguration() throws {
        let root = try sourceRoot()
        let listSource = try source(at: root.appendingPathComponent("VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift"))
        let appSource = try source(at: root.appendingPathComponent("VVTerm/App/iOS/iOSContentView.swift"))

        // Given iOS server list open intent chooses the preferred connection view.
        #expect(
            listSource.contains("@ObservedObject var viewTabConfig: ViewTabConfigurationManager"),
            "iOSServerListView should receive view tab configuration from iOS app composition."
        )
        #expect(
            !listSource.contains("ViewTabConfigurationManager.shared"),
            "iOSServerListView should not resolve ViewTabConfigurationManager.shared from Servers UI."
        )
        #expect(
            appSource.contains("viewTabConfig: viewTabConfig"),
            "iOSContentView should pass the app-owned view tab configuration into iOSServerListView."
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
