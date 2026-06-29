//
//  SSHChannelCleanupTaskRegistry.swift
//  VVTerm
//
//  SSH session channel cleanup task tracking.
//

import Foundation

// AsyncStream termination and cancellation handlers are synchronous,
// nonisolated callbacks, so this tiny registry uses a lock to let SSHSession
// own and later await channel cleanup tasks without escaping actor state.
nonisolated final class SSHChannelCleanupTaskRegistry: @unchecked Sendable {
    private let registry = AsyncCallbackTaskRegistry()

    @discardableResult
    func track(_ operation: @escaping @Sendable () async -> Void) -> UUID {
        registry.trackDetached(operation)
    }

    func tasks() -> [Task<Void, Never>] {
        registry.tasks()
    }

    func waitForAll() async {
        await registry.waitForAll()
    }
}
