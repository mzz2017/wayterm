import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFiles request lifecycle ownership.
// RemoteFileBrowserStore exposes mutation/transfer intent APIs for UI and
// feature coordinators, but tracked Task dictionaries and cancellation state
// should live in Application lifecycle coordinators. Update only when those
// owners intentionally change.

struct RemoteFileRequestLifecycleBoundaryTests {
    @Test
    func browserStoreDoesNotOwnMutationOrTransferRequestDictionaries() throws {
        let root = try sourceRoot()
        let storeSource = try source(
            at: root.appendingPathComponent("Waterm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let coordinatorSource = try source(
            at: root.appendingPathComponent("Waterm/Features/RemoteFiles/Application/RemoteFileRequestLifecycleCoordinator.swift")
        )
        let transferCoordinatorSource = try source(
            at: root.appendingPathComponent("Waterm/Features/RemoteFiles/Application/RemoteFileTransferRequestLifecycleCoordinator.swift")
        )

        // Given mutation and transfer work may outlive the initiating UI event.
        #expect(!storeSource.contains("private var mutationRequests"))
        #expect(!storeSource.contains("private var transferRequests"))
        #expect(!storeSource.contains("private struct MutationRequest"))
        #expect(!storeSource.contains("private struct TransferRequest"))
        #expect(!storeSource.contains("func isMutationRequestCancelled"))
        #expect(!storeSource.contains("func isTransferRequestCancelled"))

        // Then Application coordinators own tracked tasks and cancellation.
        #expect(coordinatorSource.contains("final class RemoteFileRequestLifecycleCoordinator"))
        #expect(coordinatorSource.contains("private var mutationRequests"))
        #expect(!coordinatorSource.contains("private var transferRequests"))
        #expect(coordinatorSource.contains("private let transferCoordinator"))
        #expect(coordinatorSource.contains("func requestMutation"))
        #expect(coordinatorSource.contains("func requestTransfer"))
        #expect(coordinatorSource.contains("func cancelMutationRequests(for serverId: UUID) -> [Task<Void, Never>]"))
        #expect(coordinatorSource.contains("func cancelTransferRequests(for serverId: UUID) -> [Task<Void, Never>]"))
        #expect(transferCoordinatorSource.contains("final class RemoteFileTransferRequestLifecycleCoordinator"))
        #expect(transferCoordinatorSource.contains("private var transferRequests"))
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
}
