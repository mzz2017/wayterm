import Foundation
import Testing
@testable import Waterm

// Test Context:
// Protects Servers' known-host cleanup boundary. ServerManager decides which
// host entries should be removed when servers disappear, while this service owns
// forwarding those removals to the injected store. Fakes record removals only;
// update these tests when server deletion no longer clears trusted-host entries.
@MainActor
struct ServerKnownHostRemovalServiceTests {
    @Test
    func removesEachKnownHostCandidateThroughInjectedStore() async {
        let store = RecordingKnownHostStore()
        let service = ServerKnownHostRemovalService(store: store)
        let candidates = [
            ServerKnownHostRemovalCandidate(host: "one.example.com", port: 22),
            ServerKnownHostRemovalCandidate(host: "two.example.com", port: 2200)
        ]

        await service.removeKnownHosts(for: candidates)

        #expect(await store.removals() == [
            .init(host: "one.example.com", port: 22),
            .init(host: "two.example.com", port: 2200)
        ])
    }
}

private actor RecordingKnownHostStore: ServerKnownHostRemovingStore {
    struct Removal: Equatable {
        let host: String
        let port: Int
    }

    private var recordedRemovals: [Removal] = []

    func remove(host: String, port: Int) async {
        recordedRemovals.append(Removal(host: host, port: port))
    }

    func removals() -> [Removal] {
        recordedRemovals
    }
}
