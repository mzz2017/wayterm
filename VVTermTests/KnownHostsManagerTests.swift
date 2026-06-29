import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the known-host trust store used during SSH host key
// verification and the settings UI's trusted-host cleanup actions. The target
// invariant is that seeing a new host key is only a verification result; it must
// not persist trust until an explicit trust policy approves it. Tests use an
// isolated in-memory/user-defaults store and no network I/O. Update this context
// only when VVTerm intentionally changes host trust onboarding or storage
// semantics.
@Suite(.serialized)
@MainActor
struct KnownHostsManagerTests {
    @Test
    func newHostVerificationDoesNotSaveUntilPolicyApproves() async throws {
        let store = KnownHostsStore(defaults: Self.makeIsolatedDefaults())
        let verifier = KnownHostVerificationService(store: store)

        let result = try await verifier.verify(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 1
        )

        guard case .newHost(let fingerprint) = result else {
            Issue.record("Expected new-host verification result, got \(result)")
            return
        }
        #expect(!fingerprint.isEmpty, "A new-host result must carry the presented fingerprint for policy/UI decisions")

        let saved = await store.entry(for: "example.com", port: 22)
        #expect(saved == nil, "New host verification must not persist trust until policy approval")
    }

    @Test
    func removeDeletesOnlyRequestedHostAndPort() {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        manager.save(entry: KnownHostsManager.Entry(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:first",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))
        manager.save(entry: KnownHostsManager.Entry(
            host: "example.com",
            port: 2222,
            fingerprint: "SHA256:second",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))

        manager.remove(host: "example.com", port: 22)

        #expect(manager.entry(for: "example.com", port: 22) == nil)
        #expect(manager.entry(for: "example.com", port: 2222)?.fingerprint == "SHA256:second")
    }

    @Test
    func removeAllClearsSavedHosts() {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        manager.save(entry: KnownHostsManager.Entry(
            host: "host.local",
            port: 22,
            fingerprint: "SHA256:host",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))

        #expect(manager.entries().count == 1)

        manager.removeAll()

        #expect(manager.entries().isEmpty)
    }

    nonisolated private static func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "KnownHostsManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
