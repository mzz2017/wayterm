import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect the shared lifecycle primitive used by synchronous
// callback boundaries that must publish async cleanup work before returning.
// Fakes use gates only; update this file only if callback cleanup ownership
// intentionally moves to a different awaitable registry contract.

@MainActor
struct AsyncCallbackTaskRegistryTests {
    @Test
    func detachedCleanupIsPublishedBeforeTrackReturnsAndWaitable() async {
        let registry = AsyncCallbackTaskRegistry()
        let gate = CallbackCleanupGate()

        // When a nonisolated callback registers detached cleanup work.
        registry.trackDetached {
            await gate.wait()
        }

        // Then the task is visible before track returns, so teardown callers
        // cannot observe an empty registry while cleanup is already scheduled.
        #expect(registry.tasks().count == 1, "Detached callback cleanup should be published before track returns.")

        // And waitForAll waits until the cleanup operation finishes and removes itself.
        let completion = CallbackCompletionProbe()
        let waitTask = Task {
            await registry.waitForAll()
            await completion.markFinished()
        }
        await Task.yield()
        #expect(await !completion.isFinished, "waitForAll must not finish before pending detached cleanup completes.")

        await gate.open()
        await waitTask.value
        #expect(registry.tasks().isEmpty, "Completed callback cleanup should be removed from the registry.")
    }

    @Test
    func mainActorCleanupIsPublishedBeforeTrackReturnsAndWaitable() async {
        let registry = AsyncCallbackTaskRegistry()
        let gate = CallbackCleanupGate()

        // When an off-actor callback queues main-actor cleanup work.
        registry.trackMainActor {
            await gate.wait()
        }

        // Then the task is visible before track returns and can be awaited by
        // the lifecycle owner before it reports teardown complete.
        #expect(registry.tasks().count == 1, "Main-actor callback cleanup should be published before track returns.")

        let completion = CallbackCompletionProbe()
        let waitTask = Task {
            await registry.waitForAll()
            await completion.markFinished()
        }
        await Task.yield()
        #expect(await !completion.isFinished, "waitForAll must not finish before pending main-actor cleanup completes.")

        await gate.open()
        await waitTask.value
        #expect(registry.tasks().isEmpty, "Completed main-actor cleanup should be removed from the registry.")
    }
}

private actor CallbackCleanupGate {
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

private actor CallbackCompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
