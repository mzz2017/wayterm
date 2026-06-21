import Foundation
import Testing

// Test Context:
// Protected behavior: root representable static teardown delegates session
// liveness, surface detach, and closed-session surface cleanup to the injected
// TerminalSessions application owner available through the coordinator.
// Target invariant: static teardown may pause or resign UI surfaces locally, but
// it must not resolve ConnectionSessionManager.shared; it must use
// coordinator.sessionManager.
// Fake assumptions: these are source-boundary tests because constructing
// NSViewRepresentable / UIViewRepresentable teardown inputs would require
// platform UI surfaces and Ghostty.
// Update guidance: update these tests only if static teardown is redesigned to
// call a different injected application owner or moves out of representable
// static lifecycle methods entirely.
@Suite(.serialized)
struct TerminalRootStaticTeardownBoundaryTests {
    @Test
    func macStaticTeardownUsesCoordinatorManager() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        let teardown = try slice(
            startingAt: "static func dismantleNSView",
            endingBefore: "// MARK: - Coordinator",
            in: source
        )

        // Given macOS static representable teardown receives a coordinator with the injected manager.
        for expectedCall in [
            "coordinator.sessionManager.sessions",
            "coordinator.sessionManager.detachSurfaceForViewDisappeared",
            "coordinator.sessionManager.handleClosedSessionSurfaceTeardown"
        ] {
            #expect(
                teardown.contains(expectedCall),
                "macOS static teardown should use injected manager call \(expectedCall)."
            )
        }

        // Then teardown must not bypass the coordinator dependency through the singleton.
        #expect(!teardown.contains("ConnectionSessionManager.shared"))
    }

    @Test
    func iosStaticTeardownUsesCoordinatorManager() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        let teardown = try slice(
            startingAt: "static func dismantleUIView",
            endingBefore: "private func terminalHostView",
            in: source
        )

        // Given iOS static representable teardown receives a coordinator with the injected manager.
        for expectedCall in [
            "coordinator.sessionManager.sessions",
            "coordinator.sessionManager.detachSurfaceForViewDisappeared",
            "coordinator.sessionManager.handleClosedSessionSurfaceTeardown"
        ] {
            #expect(
                teardown.contains(expectedCall),
                "iOS static teardown should use injected manager call \(expectedCall)."
            )
        }

        // Then teardown must not bypass the coordinator dependency through the singleton.
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
