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
    func channelCleanupRegistryPublishesTaskBeforeTrackReturns() async {
        let registry = SSHChannelCleanupTaskRegistry()
        let gate = TeardownGate()

        // When a channel cleanup operation is tracked from a synchronous
        // stream-termination callback.
        registry.track {
            await gate.wait()
        }

        // Then the pending task is visible immediately, so a concurrent
        // disconnect wait cannot incorrectly observe no registered cleanup.
        #expect(registry.tasks().count == 1, "Channel cleanup task should be published before track returns.")

        // And completing the operation removes it from the registry.
        await gate.open()
        for _ in 0..<20 where !registry.tasks().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(registry.tasks().isEmpty, "Registry should remove completed cleanup tasks.")
    }

    @Test
    func moshTeardownRegistryPublishesTaskBeforeTrackReturns() async {
        let registry = SSHMoshTeardownTaskRegistry()
        let gate = TeardownGate()

        // When a mosh teardown operation is tracked from a synchronous
        // stream-termination callback.
        registry.track {
            await gate.wait()
        }

        // Then the pending task is visible immediately, so disconnect cannot
        // incorrectly observe no registered teardown.
        #expect(registry.tasks().count == 1, "Mosh teardown task should be published before track returns.")

        // And completing the operation removes it from the registry.
        await gate.open()
        for _ in 0..<20 where !registry.tasks().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(registry.tasks().isEmpty, "Registry should remove completed teardown tasks.")
    }

    @Test
    func moshShellStreamTerminationIsOwnedByClientTeardownRegistry() throws {
        let source = try source(at: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift"))
        let moshShellSource = try slice(
            startingAt: "private func startMoshShell(",
            endingBefore: "    nonisolated static func runWithTimeout",
            in: source
        )

        #expect(
            moshShellSource.contains("runtime.setStreamTask(streamTask)"),
            "Mosh host streams should publish their stream task through the runtime owner."
        )
        #expect(
            moshShellSource.contains("trackMoshTeardownTask"),
            "Mosh stream termination should register closeShell cleanup with SSHClient."
        )
        #expect(
            moshShellSource.contains("await self.closeShell(shellId)"),
            "Mosh stream completion should retain the SSHClient owner long enough to close the shell."
        )
        #expect(
            !moshShellSource.contains("Task { [weak self]"),
            "Mosh stream completion must not rely on weak self to perform lifecycle cleanup."
        )
        #expect(
            !moshShellSource.contains("await self?.closeShell(shellId)"),
            "Mosh closeShell cleanup must not silently disappear when a weak capture is nil."
        )
    }

    @Test
    func teardownRegistriesUseSharedCallbackTaskRegistryWithDetachedCleanup() throws {
        for path in [
            "VVTerm/Core/SSH/SSHChannelCleanupTaskRegistry.swift",
            "VVTerm/Core/SSH/SSHMoshTeardownTaskRegistry.swift"
        ] {
            let source = try source(at: sourceRoot().appendingPathComponent(path))

            #expect(
                source.contains("AsyncCallbackTaskRegistry"),
                "\(path) should delegate callback task bookkeeping to the shared lifecycle registry."
            )
            #expect(
                source.contains("trackDetached(operation)"),
                "\(path) should keep SSH cleanup detached from caller cancellation context."
            )
        }
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

private func source(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func sourceRoot() throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "VVTermTests" {
        let next = url.deletingLastPathComponent()
        if next.path == url.path {
            throw SourceRootError.notFound
        }
        url = next
    }
    return url.deletingLastPathComponent()
}

private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker),
          let end = source[start.upperBound...].range(of: endMarker) else {
        throw SourceRootError.markerNotFound(marker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum SourceRootError: Error {
    case notFound
    case markerNotFound(String)
}
