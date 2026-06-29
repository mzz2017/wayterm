import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal shell registration ordering for tab and pane
// connection lifecycles. A terminal entity can close and immediately reopen
// while an older SSH runner is still finishing startup; the older runner must
// not publish a shell into the reopened or closed entity.
//
// The target invariant is generation-based ownership: a shell registration is
// accepted only for the currently active start generation of the same entity.
// If VVTerm intentionally changes to support shell handoff across entity
// generations, update this context and the expectations in the same change.
//
// Fakes and assumptions: tests use real SSHClient actor instances only for
// identity. They do not connect to a network, start libssh2, or open shells.
final class TerminalConnectionRegistryTests: XCTestCase {
    // These tests use SSHClient only for ObjectIdentifier identity. Retaining
    // the clients avoids an x86_64 simulator Swift runtime crash while
    // deallocating otherwise unused actor instances during XCTest teardown.
    @MainActor
    private static var retainedIdentityClients: [SSHClient] = []

    @MainActor
    private func makeRetainedSSHClient() -> SSHClient {
        let client = SSHClient()
        Self.retainedIdentityClients.append(client)
        return client
    }

    @MainActor
    func testActiveServerIdsOnlyIncludesStreamingEntities() {
        // Given two entities tracked by the application-layer registry.
        let registry = TerminalConnectionRegistry()
        let streamingServerId = UUID()
        let connectingServerId = UUID()
        let streamingEntityId = TerminalEntityID.session(UUID())
        let connectingEntityId = TerminalEntityID.pane(UUID())

        // When only one entity has reached a streaming terminal state.
        registry.updateState(.streaming, for: streamingEntityId, serverId: streamingServerId)
        registry.updateState(.connecting, for: connectingEntityId, serverId: connectingServerId)

        // Then active server state comes from the registry's runtime state, not
        // from open tabs, restored snapshots, or domain model flags.
        XCTAssertEqual(registry.activeServerIds, [streamingServerId])

        registry.updateState(.disconnected, for: streamingEntityId, serverId: streamingServerId)
        XCTAssertTrue(registry.activeServerIds.isEmpty)
    }

    @MainActor
    func testHasActiveEntityIgnoresExcludedAndNonStreamingEntities() {
        // Given an excluded streaming entity and a non-streaming peer.
        let registry = TerminalConnectionRegistry()
        let serverId = UUID()
        let activeEntityId = TerminalEntityID.session(UUID())
        let excludedEntityId = TerminalEntityID.session(UUID())
        let connectingEntityId = TerminalEntityID.pane(UUID())

        registry.updateState(.streaming, for: excludedEntityId, serverId: serverId)
        registry.updateState(.connecting, for: connectingEntityId, serverId: serverId)

        XCTAssertFalse(registry.hasActiveEntity(for: serverId, excluding: excludedEntityId))

        registry.updateState(.streaming, for: activeEntityId, serverId: serverId)

        XCTAssertTrue(registry.hasActiveEntity(for: serverId, excluding: excludedEntityId))
    }

    @MainActor
    func testIsOpeningOrStreamingIncludesOpeningAndStreamingStates() {
        let registry = TerminalConnectionRegistry()
        let serverId = UUID()
        let entityId = TerminalEntityID.session(UUID())

        XCTAssertFalse(registry.isOpeningOrStreaming(entityId))

        registry.updateState(.connecting, for: entityId, serverId: serverId)
        XCTAssertTrue(registry.isOpeningOrStreaming(entityId))

        registry.updateState(.streaming, for: entityId, serverId: serverId)
        XCTAssertTrue(registry.isOpeningOrStreaming(entityId))

        registry.updateState(.disconnected, for: entityId, serverId: serverId)
        XCTAssertFalse(registry.isOpeningOrStreaming(entityId))
    }

    @MainActor
    func testOpeningOrStreamingEntityIDsOnlyIncludesMatchingLiveServerEntities() {
        let registry = TerminalConnectionRegistry()
        let serverId = UUID()
        let otherServerId = UUID()
        let streamingEntityId = TerminalEntityID.session(UUID())
        let openingEntityId = TerminalEntityID.pane(UUID())
        let disconnectedEntityId = TerminalEntityID.session(UUID())
        let otherServerEntityId = TerminalEntityID.pane(UUID())

        registry.updateState(.streaming, for: streamingEntityId, serverId: serverId)
        registry.updateState(.connecting, for: openingEntityId, serverId: serverId)
        registry.updateState(.disconnected, for: disconnectedEntityId, serverId: serverId)
        registry.updateState(.streaming, for: otherServerEntityId, serverId: otherServerId)

        XCTAssertEqual(
            registry.openingOrStreamingEntityIDs(for: serverId),
            [streamingEntityId, openingEntityId]
        )
    }

    @MainActor
    func testRemoveRuntimeWaitsForTrackedRuntimeTeardown() async {
        // Given a registered runtime whose disconnect path is deliberately
        // blocked after shell close.
        let registry = TerminalConnectionRegistry()
        let serverId = UUID()
        let entityId = TerminalEntityID.session(UUID())
        let client = BlockingTerminalConnectionClient()
        let runtime = TerminalConnectionRuntime(entityId: entityId, clientFactory: { client })

        registry.register(runtime, for: entityId, serverId: serverId)
        await runtime.open(configuration: .testing)

        // When the registry removes the runtime and a caller waits for server
        // teardown completion.
        registry.removeRuntime(for: entityId, mode: .fullDisconnect)
        let waitProbe = RegistryTeardownWaitProbe()
        let waitTask = Task { @MainActor in
            await registry.waitForServerTeardown(serverId)
            await waitProbe.markReturned()
        }

        await client.waitUntilDisconnectStarted()
        let returnedBeforeDisconnectFinished = await waitProbe.hasReturned()
        XCTAssertFalse(
            returnedBeforeDisconnectFinished,
            "waitForServerTeardown must not return before runtime disconnect completes."
        )

        await client.releaseDisconnect()
        await waitTask.value

        // Then the wait completes only after the runtime closes and disconnects
        // through the tracked teardown task.
        let events = await client.events
        XCTAssertEqual(events, ["connect", "startShell", "closeShell", "disconnect-start", "disconnect-finish"])
        let returnedAfterDisconnectFinished = await waitProbe.hasReturned()
        XCTAssertTrue(returnedAfterDisconnectFinished)
    }

    @MainActor
    func testClosedEntityRejectsLateShellRegistrationFromSameClient() {
        // Given an entity that began starting a shell and then closed before
        // the runner registered its shell.
        var registry = SSHShellRegistry(staleThreshold: 120)
        let entityId = UUID()
        let serverId = UUID()
        let client = makeRetainedSSHClient()
        let oldStart = registry.tryBeginStart(for: entityId, serverId: serverId, client: client)

        _ = registry.closeEntity(entityId)

        // When the old runner reports a shell for its stale generation.
        let lateShellId = UUID()
        let result = registry.register(
            client: client,
            shellId: lateShellId,
            for: entityId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil,
            generation: oldStart.generation
        )

        // Then the registry rejects the stale shell and exposes it for cleanup
        // instead of making the entity look connected again.
        XCTAssertFalse(result.accepted, "A closed entity must not accept a late shell registration from an old start generation.")
        XCTAssertNotNil(result.rejectedShellToClose, "Rejected late shells must be returned so the caller can close them explicitly.")
        XCTAssertNil(registry.client(for: entityId), "Rejecting the late shell must leave the entity without a registered SSH client.")
        XCTAssertNil(registry.shellId(for: entityId), "Rejecting the late shell must leave the entity without a registered shell.")
    }

    @MainActor
    func testOlderGenerationCannotReplaceNewerShellForSameEntity() {
        // Given one entity that closed an old start and began a new start.
        var registry = SSHShellRegistry(staleThreshold: 120)
        let entityId = UUID()
        let serverId = UUID()
        let oldClient = makeRetainedSSHClient()
        let newClient = makeRetainedSSHClient()
        let oldStart = registry.tryBeginStart(for: entityId, serverId: serverId, client: oldClient)

        _ = registry.closeEntity(entityId)
        let newStart = registry.tryBeginStart(for: entityId, serverId: serverId, client: newClient)
        let newShellId = UUID()

        let accepted = registry.register(
            client: newClient,
            shellId: newShellId,
            for: entityId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil,
            generation: newStart.generation
        )

        // When the old runner reports a shell after the newer shell registered.
        let rejected = registry.register(
            client: oldClient,
            shellId: UUID(),
            for: entityId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil,
            generation: oldStart.generation
        )

        // Then the stale generation cannot replace the current shell.
        XCTAssertTrue(accepted.accepted, "The current generation should accept the new shell registration.")
        XCTAssertFalse(rejected.accepted, "An older generation must not replace a newer shell for the same entity.")
        XCTAssert(registry.client(for: entityId) === newClient, "The registry must retain the newer client after rejecting an older generation.")
        XCTAssertEqual(registry.shellId(for: entityId), newShellId, "The registry must retain the newer shell after rejecting an older generation.")
    }
}

private actor BlockingTerminalConnectionClient: TerminalConnectionClient {
    private(set) var events: [String] = []
    private let shellId = UUID()
    private var disconnectStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var disconnectReleaseContinuation: CheckedContinuation<Void, Never>?
    private var hasDisconnectStarted = false
    private var isDisconnectReleased = false

    func connect() async throws {
        events.append("connect")
    }

    func startShell() async throws -> UUID {
        events.append("startShell")
        return shellId
    }

    func closeShell(_ shellId: UUID) async {
        events.append("closeShell")
    }

    func disconnect() async {
        events.append("disconnect-start")
        hasDisconnectStarted = true
        disconnectStartedContinuations.forEach { $0.resume() }
        disconnectStartedContinuations.removeAll()

        if !isDisconnectReleased {
            await withCheckedContinuation { continuation in
                disconnectReleaseContinuation = continuation
            }
        }

        events.append("disconnect-finish")
    }

    func write(_ data: Data, to shellId: UUID) async throws {}

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {}

    func waitUntilDisconnectStarted() async {
        guard !hasDisconnectStarted else { return }
        await withCheckedContinuation { continuation in
            disconnectStartedContinuations.append(continuation)
        }
    }

    func releaseDisconnect() {
        isDisconnectReleased = true
        disconnectReleaseContinuation?.resume()
        disconnectReleaseContinuation = nil
    }
}

private actor RegistryTeardownWaitProbe {
    private var didReturn = false

    func markReturned() {
        didReturn = true
    }

    func hasReturned() -> Bool {
        didReturn
    }
}
