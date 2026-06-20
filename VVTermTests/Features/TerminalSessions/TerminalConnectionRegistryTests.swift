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

    func testClosedEntityRejectsLateShellRegistrationFromSameClient() {
        // Given an entity that began starting a shell and then closed before
        // the runner registered its shell.
        var registry = SSHShellRegistry(staleThreshold: 120)
        let entityId = UUID()
        let serverId = UUID()
        let client = SSHClient()
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

    func testOlderGenerationCannotReplaceNewerShellForSameEntity() {
        // Given one entity that closed an old start and began a new start.
        var registry = SSHShellRegistry(staleThreshold: 120)
        let entityId = UUID()
        let serverId = UUID()
        let oldClient = SSHClient()
        let newClient = SSHClient()
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
