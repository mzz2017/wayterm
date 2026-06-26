import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOSTerminalView superfile control. The
// iOS terminal root owns top-level composition and intent routing; reusable
// floating controls and transient connection chrome should live in sibling UI
// files so the root view does not accumulate presentation subcomponents.
// Update this test only if iOS terminal root composition intentionally changes.
@Suite
struct IOSTerminalViewSuperfileBoundaryTests {
    @Test
    func iosTerminalViewDoesNotOwnFloatingControlOrConnectingChrome() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let componentSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalFloatingControls.swift")
        )

        for typeName in [
            "IOSTerminalFloatingControls",
            "IOSTerminalConnectingStateView"
        ] {
            #expect(
                !rootSource.contains("struct \(typeName)"),
                "iOSTerminalView.swift should not define \(typeName)."
            )
            #expect(
                componentSource.contains("struct \(typeName)"),
                "IOSTerminalFloatingControls.swift should define \(typeName)."
            )
        }

        #expect(
            !rootSource.contains("private func floatingTerminalControlButton"),
            "iOSTerminalView.swift should not own floating control button chrome."
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
