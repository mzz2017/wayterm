//
//  SSHMoshTeardownTaskRegistry.swift
//  Waterm
//
//  Tracks Mosh stream teardown tasks that begin outside SSHClient actor isolation.
//

import Foundation

// Mosh stream termination is a synchronous callback outside SSHClient actor
// isolation; this registry lets the client own and await teardown tasks without
// exposing actor-isolated mosh runtime state.
nonisolated final class SSHMoshTeardownTaskRegistry: @unchecked Sendable {
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
