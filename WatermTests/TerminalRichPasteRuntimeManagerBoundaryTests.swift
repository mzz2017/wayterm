import Foundation
import Testing

// Test Context:
// Protected behavior: rich-paste UI/runtime may create upload and clipboard
// paste closures, but manager ownership must come from the terminal
// coordinator's injected TerminalSessions application owner.
// Target invariant: TerminalRichPasteRuntime factories must not resolve manager
// singletons; they must receive root/split managers from the representable
// coordinator.
// Fake assumptions: these are source-boundary tests because the protected
// behavior is dependency ownership at the SwiftUI/coordinator/application
// boundary, while upload lifecycle ordering is covered by
// TerminalRichPasteUploadRequestTests.
// Update guidance: update these tests only if rich-paste runtime construction
// intentionally moves to a different injected application owner or out of
// terminal representable coordinators.
@Suite(.serialized)
struct TerminalRichPasteRuntimeManagerBoundaryTests {
    @Test
    func richPasteRuntimeFactoriesUseInjectedManagers() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift")
        )
        let sessionFactory = try slice(
            startingAt: "static func connectionSession",
            endingBefore: "static func terminalPane",
            in: source
        )
        let paneFactory = try slice(
            startingAt: "static func terminalPane",
            endingBefore: "func install",
            in: source
        )

        // Given root rich paste runtime construction receives the root application owner.
        for expectedCall in [
            "sessionManager: ConnectionSessionManager",
            "sessionManager.requestSessionRichPasteUpload",
            "sessionManager.peekTerminal"
        ] {
            #expect(
                sessionFactory.contains(expectedCall),
                "Root rich-paste runtime factory should use injected manager call \(expectedCall)."
            )
        }
        #expect(!sessionFactory.contains("ConnectionSessionManager.shared"))

        // Given split rich paste runtime construction receives the pane application owner.
        for expectedCall in [
            "tabManager: TerminalTabManager",
            "tabManager.requestPaneRichPasteUpload",
            "tabManager.getTerminal"
        ] {
            #expect(
                paneFactory.contains(expectedCall),
                "Split rich-paste runtime factory should use injected manager call \(expectedCall)."
            )
        }
        #expect(!paneFactory.contains("TerminalTabManager.shared"))

        // Then the shared rich-paste support file must not resolve manager singletons.
        #expect(!source.contains("ConnectionSessionManager.shared"))
        #expect(!source.contains("TerminalTabManager.shared"))
    }

    @Test
    func rootTerminalCoordinatorsPassInjectedSessionManagerToRichPasteRuntime() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )
        // Given both macOS and iOS root coordinators already store an injected session manager.
        #expect(source.contains("let sessionManager: ConnectionSessionManager"))
        #expect(
            occurrenceCount(of: "self.richPasteRuntime = .connectionSession(", in: source) == 2,
            "Root wrapper should have one rich-paste runtime construction per platform coordinator."
        )

        // Then each root runtime construction should pass that injected manager through.
        let constructions = slices(
            startingAt: "self.richPasteRuntime = .connectionSession(",
            endingBefore: ")",
            in: source
        )
        #expect(constructions.count == 2)
        for construction in constructions {
            for expectedCall in [
                "sessionId: sessionId",
                "uiModel: richPasteUIModel",
                "sessionManager: sessionManager"
            ] {
                #expect(
                    construction.contains(expectedCall),
                    "Root rich-paste runtime construction should include \(expectedCall)."
                )
            }
        }
    }

    @Test
    func splitTerminalCoordinatorPassesInjectedTabManagerToRichPasteRuntime() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Splits/SSHTerminalPaneWrapper.swift")
        )
        let coordinator = try slice(
            startingAt: "class Coordinator",
            endingBefore: "func installRichPasteInterception",
            in: source
        )
        let construction = try slice(
            startingAt: "self.richPasteRuntime = .terminalPane(",
            endingBefore: ")",
            in: coordinator
        )

        // Given the split pane coordinator stores the injected tab manager.
        #expect(coordinator.contains("let tabManager: TerminalTabManager"))

        // Then rich-paste runtime construction should pass that same manager through.
        for expectedCall in [
            "paneId: paneId",
            "uiModel: richPasteUIModel",
            "tabManager: tabManager"
        ] {
            #expect(
                construction.contains(expectedCall),
                "Split rich-paste runtime construction should include \(expectedCall)."
            )
        }
    }

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func occurrenceCount(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private func slices(startingAt marker: String, endingBefore endMarker: String, in source: String) -> [String] {
        var slices: [String] = []
        var searchRange = source.startIndex..<source.endIndex
        while let start = source.range(of: marker, range: searchRange),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex) {
            slices.append(String(source[start.lowerBound..<end.lowerBound]))
            searchRange = end.upperBound..<source.endIndex
        }
        return slices
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
