import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect LocalDiscovery scan lifecycle ownership. The service owns
// NetServiceBrowser, timeout, and port-probe task lifetimes; UI may start/stop
// scans, but stale asynchronous callbacks from a stopped scan must not publish
// into a newer scan stream. Fakes avoid Bonjour and real network probes.
// Update only when LocalDiscovery scanning intentionally moves to another
// Application/Infrastructure owner.
@Suite(.serialized)
@MainActor
struct LocalSSHDiscoveryServiceLifecycleTests {
    @Test
    func reachabilityCompletionPublishesOnlyTheFirstCallback() {
        let recorder = LocalDiscoveryReachabilityCompletionRecorder()
        let completion = LocalSSHDiscoveryReachabilityCompletion { isReachable in
            recorder.record(isReachable)
        }

        // Given Network and timeout callbacks may race to finish the same
        // reachability probe from different queues.
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            completion.complete(index == 0)
        }

        // Then only the first callback publishes completion, preventing a
        // double continuation resume at the NWConnection/timeout boundary.
        #expect(
            recorder.recordedCount == 1,
            "LocalDiscovery reachability completion must be idempotent across racing Network callbacks."
        )
    }

    @Test
    func stoppedScanProbeResultsDoNotPublishIntoNextScan() async throws {
        let candidates = LocalDiscoveryCandidateBatches([["192.0.2.10"], []])
        let probe = LocalDiscoveryProbeGate()
        let service = LocalSSHDiscoveryService(
            dependencies: LocalSSHDiscoveryServiceDependencies(
                bonjourTypes: [],
                scanDuration: 60,
                serviceResolveTimeout: 1,
                portScanTimeout: 0.01,
                portScanConcurrency: 1,
                localSubnetCandidates: {
                    candidates.next()
                },
                probeSSHHost: { host, _ in
                    await probe.probe(host)
                }
            )
        )

        // Given the first scan has queued a port probe that has not completed.
        _ = service.startScan()
        await probe.waitForProbeStart()

        // When a new scan starts before the old probe exits.
        let nextStream = service.startScan()
        let collector = LocalDiscoveryEventCollector()
        let collectTask = Task {
            for await event in nextStream {
                await collector.record(event)
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        await probe.release()
        try await Task.sleep(for: .milliseconds(50))
        service.stopScan()
        collectTask.cancel()

        // Then late probe output from the stopped scan is ignored instead of
        // being delivered to the newer scan stream.
        let events = await collector.events()
        #expect(
            !events.containsHost("192.0.2.10"),
            "Stopped LocalDiscovery probe results must not publish into a newer scan stream."
        )
    }
}

@MainActor
private final class LocalDiscoveryCandidateBatches {
    private var batches: [[String]]

    init(_ batches: [[String]]) {
        self.batches = batches
    }

    func next() -> [String] {
        guard !batches.isEmpty else { return [] }
        return batches.removeFirst()
    }
}

private actor LocalDiscoveryProbeGate {
    private var didStart = false
    private var isReleased = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func probe(_ host: String) async -> LocalSSHDiscoveryProbeResult? {
        didStart = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }

        return LocalSSHDiscoveryProbeResult(host: host, latencyMs: 1)
    }

    func waitForProbeStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuations.forEach { $0.resume() }
        releaseContinuations.removeAll()
    }
}

private actor LocalDiscoveryEventCollector {
    private var recordedEvents: [LocalSSHDiscoveryEvent] = []

    func record(_ event: LocalSSHDiscoveryEvent) {
        recordedEvents.append(event)
    }

    func events() -> [LocalSSHDiscoveryEvent] {
        recordedEvents
    }
}

private final class LocalDiscoveryReachabilityCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Bool] = []

    var recordedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues.count
    }

    func record(_ value: Bool) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

private extension [LocalSSHDiscoveryEvent] {
    func containsHost(_ host: String) -> Bool {
        contains { event in
            guard case .hostFound(let discovered) = event else { return false }
            return discovered.host == host
        }
    }
}
