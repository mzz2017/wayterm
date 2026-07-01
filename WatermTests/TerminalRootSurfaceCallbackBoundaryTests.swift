import Foundation
import Testing

// Test Context:
// Protected behavior: root terminal surface callbacks report runtime, metadata,
// input, attach, and teardown intent through the injected TerminalSessions
// application manager instead of resolving ConnectionSessionManager.shared from
// representable/coordinator instance methods.
// Target invariant: macOS and iOS root wrapper instance callbacks plus shared
// coordinator helpers must use the injected sessionManager; static teardown in
// dismantleNSView and dismantleUIView remains the only root-wrapper singleton
// exemption in this slice because static representable teardown has no instance
// injection point.
// Fake assumptions: these are source-boundary tests, so they intentionally check
// call-site ownership text rather than creating Ghostty/AppKit/UIKit surfaces.
// Update guidance: update these tests only if root terminal surface callback
// ownership intentionally moves to a different injected application owner or
// static teardown is redesigned in a later lifetime task.
@Suite(.serialized)
struct TerminalRootSurfaceCallbackBoundaryTests {
    @Test
    func terminalContainerInjectsSessionManagerIntoRootWrapper() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )

        // Given TerminalContainerView constructs root terminal wrappers.
        #expect(
            source.contains("private let sessionManager: ConnectionSessionManager"),
            "TerminalContainerView should retain an injectable app-owned session manager dependency at the screen boundary."
        )
        #expect(
            !source.contains("ConnectionSessionManager.shared"),
            "TerminalContainerView should receive the app-owned session manager from its caller, not resolve the shared manager."
        )
        #expect(
            source.contains("sessionManager: ConnectionSessionManager,"),
            "TerminalContainerView should keep an explicit initializer for injected session manager ownership."
        )

        // When every root wrapper is constructed for the current terminal session.
        let wrapperConstructions = source.components(separatedBy: "SSHTerminalWrapper(").count - 1

        // Then each construction should inject the same manager instead of forcing wrappers to resolve a singleton.
        #expect(wrapperConstructions == 2, "Expected the macOS and iOS root terminal wrapper construction sites.")
        #expect(
            source.components(separatedBy: "sessionManager: sessionManager").count - 1 == wrapperConstructions,
            "Every SSHTerminalWrapper construction should pass sessionManager through."
        )
    }

    @Test
    func macRootWrapperUsesInjectedManagerForSurfaceCallbacks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        let wrapper = try slice(
            startingAt: "struct SSHTerminalWrapper: NSViewRepresentable",
            endingBefore: "static func dismantleNSView",
            in: source
        )

        // Given the macOS root terminal representable receives Ghostty surface callbacks.
        #expect(
            wrapper.contains("let sessionManager: ConnectionSessionManager"),
            "macOS SSHTerminalWrapper should receive its application manager from TerminalContainerView."
        )

        // When callbacks report session runtime and metadata events.
        for expectedCall in [
            "sessionManager.configureRuntime",
            "sessionManager.getTerminal",
            "sessionManager.requestSessionResize",
            "sessionManager.updateSessionWorkingDirectory",
            "sessionManager.updateSessionTitle",
            "sessionManager.handleTerminalZoom",
            "sessionManager.presentationOverrides",
            "sessionManager.registerTerminal",
            "sessionManager.prepareSurfaceForUpdate"
        ] {
            #expect(
                wrapper.contains(expectedCall),
                "macOS root surface callbacks should use injected manager call \(expectedCall)."
            )
        }

        // Then instance callbacks must not bypass injection through the singleton.
        #expect(!wrapper.contains("sessionManager.sessions"))
        #expect(!wrapper.contains("sessionManager.handleClosedSessionSurfaceTeardown"))
        #expect(!wrapper.contains("ConnectionSessionManager.shared"))
    }

    @Test
    func iosRootRepresentableUsesInjectedManagerForSurfaceCallbacks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        let representable = try slice(
            startingAt: "private struct SSHTerminalRepresentable",
            endingBefore: "static func dismantleUIView",
            in: source
        )

        // Given the iOS root terminal representable receives Ghostty surface callbacks.
        #expect(
            representable.contains("let sessionManager: ConnectionSessionManager"),
            "iOS SSHTerminalRepresentable should receive its application manager from SSHTerminalWrapper."
        )

        // When callbacks report session runtime and metadata events.
        for expectedCall in [
            "sessionManager.configureRuntime",
            "sessionManager.peekTerminal",
            "sessionManager.markTerminalUsed",
            "sessionManager.requestSessionResize",
            "sessionManager.updateSessionWorkingDirectory",
            "sessionManager.updateSessionTitle",
            "sessionManager.handleTerminalZoom",
            "sessionManager.presentationOverrides",
            "sessionManager.registerTerminal",
            "sessionManager.prepareSurfaceForUpdate"
        ] {
            #expect(
                representable.contains(expectedCall),
                "iOS root surface callbacks should use injected manager call \(expectedCall)."
            )
        }

        // Then instance callbacks must not bypass injection through the singleton.
        #expect(!representable.contains("sessionManager.sessions"))
        #expect(!representable.contains("sessionManager.handleClosedSessionSurfaceTeardown"))
        #expect(!representable.contains("ConnectionSessionManager.shared"))
    }

    @Test
    func rootCoordinatorUsesInjectedManagerForInputAndAttach() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        let coordinator = try slice(
            startingAt: "protocol SSHTerminalCoordinator",
            endingBefore: "#if os(macOS)",
            in: source
        )

        // Given shared root terminal coordinator helpers route input and surface attach callbacks.
        #expect(
            coordinator.contains("var sessionManager: ConnectionSessionManager { get }"),
            "SSHTerminalCoordinator should require the injected manager used by shared helper methods."
        )

        // When helper callbacks are invoked by macOS or iOS coordinators.
        #expect(
            coordinator.contains("sessionManager.requestSessionInput"),
            "Root coordinator input should be routed through the injected manager."
        )
        #expect(
            coordinator.contains("sessionManager.requestSurfaceAttach"),
            "Root coordinator surface attach should be routed through the injected manager."
        )

        // Then shared helpers must not bypass injection through the singleton.
        #expect(!coordinator.contains("ConnectionSessionManager.shared"))
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
