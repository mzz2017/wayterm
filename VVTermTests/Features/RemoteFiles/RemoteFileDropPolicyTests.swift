import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote-file drag/drop planning. The policy is pure: it
// deduplicates payload entries, chooses move for same-server drops, chooses copy
// for cross-server drops, and prevents moving a folder into itself. Update only
// when remote drag/drop semantics intentionally change.

struct RemoteFileDropPolicyTests {
    @Test
    func uniquePayloadsDeduplicateEntriesAcrossPayloads() throws {
        let serverId = UUID()
        let first = makeEntry(name: "a.txt", path: "/root/a.txt")
        let duplicate = makeEntry(name: "a.txt", path: "/root/a.txt")
        let second = makeEntry(name: "b.txt", path: "/root/b.txt")

        // Given drag payloads with duplicate remote paths.
        let payloads = try RemoteFileDropPolicy.uniquePayloads(from: [
            RemoteFileDragPayload(serverId: serverId, entries: [first, second]),
            RemoteFileDragPayload(serverId: serverId, entries: [duplicate])
        ])

        // Then the first occurrence is retained and empty payloads are removed.
        #expect(payloads.count == 1)
        #expect(payloads[0].entries.map(\.path) == ["/root/a.txt", "/root/b.txt"])
    }

    @Test
    func planMovesSameServerEntriesToDestinationDirectory() throws {
        let serverId = UUID()
        let entry = makeEntry(name: "a.txt", path: "/root/a.txt")

        let plan = try RemoteFileDropPolicy.plan(
            payloads: [RemoteFileDragPayload(serverId: serverId, entries: [entry])],
            to: "/dest",
            destinationServerId: serverId
        )

        guard case .move(let moves) = plan else {
            Issue.record("Same-server remote drops should plan moves.")
            return
        }
        #expect(moves.map(\.sourcePath) == ["/root/a.txt"])
        #expect(moves.map(\.destinationPath) == ["/dest/a.txt"])
    }

    @Test
    func planCopiesCrossServerEntriesFromSingleSourceServer() throws {
        let sourceServerId = UUID()
        let destinationServerId = UUID()
        let entry = makeEntry(name: "a.txt", path: "/root/a.txt")

        let plan = try RemoteFileDropPolicy.plan(
            payloads: [RemoteFileDragPayload(serverId: sourceServerId, entries: [entry])],
            to: "/dest",
            destinationServerId: destinationServerId
        )

        guard case .copy(let source, let entries) = plan else {
            Issue.record("Cross-server remote drops should plan copies.")
            return
        }
        #expect(source == sourceServerId)
        #expect(entries.map(\.path) == ["/root/a.txt"])
    }

    @Test
    func planRejectsMixedSourceServers() {
        let destinationServerId = UUID()

        #expect(throws: RemoteFileBrowserError.self) {
            try RemoteFileDropPolicy.plan(
                payloads: [
                    RemoteFileDragPayload(
                        serverId: UUID(),
                        entries: [makeEntry(name: "a.txt", path: "/root/a.txt")]
                    ),
                    RemoteFileDragPayload(
                        serverId: UUID(),
                        entries: [makeEntry(name: "b.txt", path: "/root/b.txt")]
                    )
                ],
                to: "/dest",
                destinationServerId: destinationServerId
            )
        }
    }

    @Test
    func planRejectsMovingDirectoryIntoDescendant() {
        let serverId = UUID()

        #expect(throws: RemoteFileBrowserError.self) {
            try RemoteFileDropPolicy.plan(
                payloads: [
                    RemoteFileDragPayload(
                        serverId: serverId,
                        entries: [makeEntry(name: "project", path: "/root/project", type: .directory)]
                    )
                ],
                to: "/root/project/archive",
                destinationServerId: serverId
            )
        }
    }

    private func makeEntry(
        name: String,
        path: String,
        type: RemoteFileType = .file
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}
