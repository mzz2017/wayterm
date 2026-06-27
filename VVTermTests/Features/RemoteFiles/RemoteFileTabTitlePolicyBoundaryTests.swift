import Foundation
import Testing

struct RemoteFileTabTitlePolicyBoundaryTests {
    @Test
    func terminalContainersDoNotOwnRemoteFileTabTitlePolicy() throws {
        let root = try sourceRoot()
        let iOSContainerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let macOSContainerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )
        let policySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileTabTitlePolicy.swift")
        )

        for containerSource in [iOSContainerSource, macOSContainerSource] {
            #expect(
                !containerSource.contains("RemoteFilePath.breadcrumbs"),
                "Terminal containers should not own remote file path title parsing."
            )
            #expect(
                !containerSource.contains("titleCounts"),
                "Terminal containers should not own duplicate file-tab title disambiguation."
            )
        }

        #expect(
            policySource.contains("enum RemoteFileTabTitlePolicy"),
            "RemoteFiles Application should own file-tab title policy."
        )
        #expect(
            policySource.contains("RemoteFilePath.breadcrumbs"),
            "RemoteFiles Application should derive tab labels from remote paths."
        )
        #expect(
            policySource.contains("titleCounts"),
            "RemoteFiles Application should own duplicate title disambiguation."
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
