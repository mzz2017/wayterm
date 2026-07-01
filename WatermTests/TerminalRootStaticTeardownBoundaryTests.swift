import Foundation
import Testing

// Test Context:
// Protected behavior: root representable static teardown reports disappeared
// terminal surfaces to the injected TerminalSessions application owner.
// Target invariant: static teardown may resign platform focus locally, but it
// must not inspect session collections or decide whether a surface should be
// detached or cleaned up.
// Fake assumptions: these are source-boundary tests because constructing
// NSViewRepresentable / UIViewRepresentable teardown inputs would require
// platform UI surfaces and Ghostty.
// Update guidance: update these tests only if disappeared-surface policy moves
// to another non-UI owner or representable static teardown goes away entirely.
@Suite(.serialized)
struct TerminalRootStaticTeardownBoundaryTests {
    @Test
    func macStaticTeardownUsesCoordinatorManager() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        let teardown = try slice(
            startingAt: "static func dismantleNSView",
            endingBefore: "// MARK: - Coordinator",
            in: source
        )

        // Given macOS static representable teardown receives a coordinator with the injected manager.
        #expect(
            teardown.contains("coordinator.sessionManager.handleSurfaceViewDisappeared"),
            "macOS static teardown should send one disappeared-surface intent to the application manager."
        )

        // Then teardown must not read application state or select detach/cleanup branches itself.
        #expect(!teardown.contains("coordinator.sessionManager.sessions"))
        #expect(!teardown.contains("coordinator.sessionManager.detachSurfaceForViewDisappeared"))
        #expect(!teardown.contains("coordinator.sessionManager.handleClosedSessionSurfaceTeardown"))
        #expect(!teardown.contains("pauseRendering()"))
        #expect(!teardown.contains("ConnectionSessionManager.shared"))
    }

    @Test
    func iosStaticTeardownUsesCoordinatorManager() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        let teardown = try slice(
            startingAt: "static func dismantleUIView",
            endingBefore: "private func terminalHostView",
            in: source
        )

        // Given iOS static representable teardown receives a coordinator with the injected manager.
        #expect(
            teardown.contains("coordinator.sessionManager.handleSurfaceViewDisappeared"),
            "iOS static teardown should send one disappeared-surface intent to the application manager."
        )

        // Then teardown must not read application state or select detach/cleanup branches itself.
        #expect(!teardown.contains("coordinator.sessionManager.sessions"))
        #expect(!teardown.contains("coordinator.sessionManager.detachSurfaceForViewDisappeared"))
        #expect(!teardown.contains("coordinator.sessionManager.handleClosedSessionSurfaceTeardown"))
        #expect(!teardown.contains("pauseRendering()"))
        #expect(!teardown.contains("ConnectionSessionManager.shared"))
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

    private enum SourceSliceError: Error {
        case notFound
    }
}
