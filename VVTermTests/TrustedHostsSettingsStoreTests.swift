import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Settings application-layer owner for trusted SSH host
// cleanup. Resetting trusted hosts is a destructive persistence operation, so
// SwiftUI must send intent to a stable store instead of owning the task or
// calling KnownHostsStore directly. Tests use an isolated UserDefaults-backed
// KnownHostsStore and no network I/O. Update this context only when trusted-host
// settings ownership intentionally moves to another application-layer type.
@Suite(.serialized)
@MainActor
struct TrustedHostsSettingsStoreTests {
    @Test
    func resetTrustedHostsTracksTaskAndRefreshesCount() async {
        // Given a Settings application store backed by an isolated known-hosts
        // store with one trusted host.
        let knownHostsStore = KnownHostsStore(defaults: makeIsolatedDefaults())
        await knownHostsStore.save(entry: KnownHostsManager.Entry(
            host: "settings.example.com",
            port: 22,
            fingerprint: "SHA256:settings",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))
        let store = TrustedHostsSettingsStore(knownHostsStore: knownHostsStore)

        // When Settings refreshes the count and then resets trusted hosts.
        let refreshID = store.refreshKnownHostCount()
        await store.waitForKnownHostsTask(refreshID)
        #expect(store.knownHostCount == 1)

        let resetID = store.resetTrustedHosts()
        #expect(
            store.pendingKnownHostsTaskIDs.contains(resetID),
            "Trusted-host reset should be tracked by the Settings application store."
        )
        await store.waitForKnownHostsTask(resetID)

        // Then the destructive operation has completed, count is refreshed, and
        // no trusted hosts remain in the underlying store.
        #expect(!store.pendingKnownHostsTaskIDs.contains(resetID))
        #expect(store.knownHostCount == 0)
        #expect(
            await knownHostsStore.entries().isEmpty,
            "Resetting trusted hosts should remove every saved host fingerprint."
        )
    }

    @Test
    func staleRefreshCannotOverwriteLaterResetCount() async {
        // Given a Settings application store where a stale refresh is still
        // waiting while the user requests a trusted-host reset.
        let entry = KnownHostsManager.Entry(
            host: "stale-refresh.example.com",
            port: 22,
            fingerprint: "SHA256:stale-refresh",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        )
        let knownHostsStore = BlockingKnownHostsStore(entries: [entry])
        let store = TrustedHostsSettingsStore(knownHostsStore: knownHostsStore)

        // When the refresh starts first but the reset is the later user intent.
        let refreshID = store.refreshKnownHostCount()
        await knownHostsStore.waitForFirstEntriesCall()

        let resetID = store.resetTrustedHosts()
        await store.waitForKnownHostsTask(resetID)
        #expect(store.knownHostCount == 0)

        await knownHostsStore.releaseFirstEntriesCall()
        await store.waitForKnownHostsTask(refreshID)

        // Then the stale refresh completion does not overwrite the count from
        // the later destructive reset.
        #expect(store.knownHostCount == 0)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "TrustedHostsSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor BlockingKnownHostsStore: KnownHostsStoring {
    private var storedEntries: [KnownHostsManager.Entry]
    private var entriesCallCount = 0
    private let firstEntriesCalled = AsyncProbe()
    private let firstEntriesGate = AsyncGate()

    init(entries: [KnownHostsManager.Entry]) {
        storedEntries = entries
    }

    func entries() async -> [KnownHostsManager.Entry] {
        entriesCallCount += 1
        if entriesCallCount == 1 {
            await firstEntriesCalled.mark()
            await firstEntriesGate.wait()
            return storedEntries
        }
        return storedEntries
    }

    func removeAll() {
        storedEntries.removeAll()
    }

    func waitForFirstEntriesCall() async {
        await firstEntriesCalled.wait()
    }

    func releaseFirstEntriesCall() async {
        await firstEntriesGate.open()
    }
}

private actor AsyncProbe {
    private var isMarked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        isMarked = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if isMarked {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
