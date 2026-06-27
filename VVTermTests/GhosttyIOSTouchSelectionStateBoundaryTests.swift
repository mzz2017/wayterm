import Foundation
import Testing

@Suite(.serialized)
struct GhosttyIOSTouchSelectionStateBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesTouchSelectionStateToStateOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let stateSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSTouchSelectionState.swift")
        )

        #expect(viewSource.contains("private let touchSelectionState = TerminalIOSTouchSelectionState()"))
        #expect(viewSource.contains("touchSelectionState.begin"))
        #expect(viewSource.contains("touchSelectionState.update"))
        #expect(viewSource.contains("touchSelectionState.updateHandle"))
        #expect(viewSource.contains("touchSelectionState.clear"))

        #expect(!viewSource.contains("private var touchSelectionAnchor"))
        #expect(!viewSource.contains("private var touchSelectionSeed"))
        #expect(!viewSource.contains("private var touchSelection: TerminalGridSelection?"))

        #expect(stateSource.contains("final class TerminalIOSTouchSelectionState"))
        #expect(stateSource.contains("func begin"))
        #expect(stateSource.contains("func update"))
        #expect(stateSource.contains("func updateHandle"))
        #expect(stateSource.contains("func clear"))
        #expect(stateSource.contains("private var anchor"))
        #expect(stateSource.contains("private var seed"))
        #expect(stateSource.contains("private(set) var selection"))
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
