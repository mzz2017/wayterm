import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect small SSHClient support owners after they were moved out
// of SSHClient.swift. They avoid real SSH/network I/O; registry tests only use
// detached task bookkeeping and should be updated only if teardown tracking
// ownership intentionally changes.

struct SSHClientSupportOwnerTests {
    @Test
    func abortStateTracksAbortAndResetWithoutSession() {
        let state = SSHClientAbortState()

        // Given a fresh abort state.
        #expect(!state.isAborted)

        // When abort is requested without a registered session.
        state.abort()

        // Then the state records abort intent and reset clears it.
        #expect(state.isAborted)
        state.reset()
        #expect(!state.isAborted)
    }

    @Test
    func moshTeardownRegistryTracksTaskUntilOperationCompletes() async {
        let registry = SSHMoshTeardownTaskRegistry()
        let gate = TeardownGate()

        // When a teardown operation is tracked.
        registry.track {
            await gate.wait()
        }

        // Then a task is visible while the operation is still suspended.
        for _ in 0..<20 where registry.tasks().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(registry.tasks().count == 1, "Registry should expose pending teardown tasks.")

        // And completing the operation removes it from the registry.
        await gate.open()
        for _ in 0..<20 where !registry.tasks().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(registry.tasks().isEmpty, "Registry should remove completed teardown tasks.")
    }
}

private actor TeardownGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
