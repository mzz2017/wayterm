import XCTest
@testable import VVTerm

// Test Context:
// These tests protect cancellation while waiting for SSHAuthenticationGate.
// A canceled authentication waiter must be removed before the current holder
// releases the key, otherwise a user-initiated close/retry can still run stale
// public-key authentication work. Fakes here are small actors that model task
// ordering only; they do not create SSH clients or touch Keychain material.
// Update these tests only if queued SSH authentication waiters intentionally
// become non-cancelable.

final class SSHAuthenticationGateCancellationTests: XCTestCase {
    func testExplicitLeaseSerializesUntilReleased() async throws {
        let gate = SSHAuthenticationGate()
        let firstLease = try await gate.acquireLease(for: "server:user")
        let secondAcquired = AsyncFlag()

        // Given one caller owns the authentication slot through an explicit
        // lease while the libssh2 auth call stays on its original owner.
        let second = Task {
            let lease = try await gate.acquireLease(for: "server:user")
            await secondAcquired.setTrue()
            await lease.release()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then a second caller cannot enter the key-specific auth slot before
        // the first owner releases it.
        let acquiredBeforeRelease = await secondAcquired.value
        XCTAssertFalse(
            acquiredBeforeRelease,
            "A live auth lease must hold the key-specific slot until release"
        )

        // When the first owner releases the lease.
        await firstLease.release()
        try await second.value

        // Then the next waiter can acquire the slot.
        let acquiredAfterRelease = await secondAcquired.value
        XCTAssertTrue(
            acquiredAfterRelease,
            "Releasing an auth lease should resume the next waiter"
        )
    }

    func testCancelledWaiterDoesNotRunOperation() async {
        // Given a holder occupying a key and a second operation waiting for it.
        let gate = SSHAuthenticationGate()
        let holderStarted = AsyncProbe()
        let releaseHolder = AsyncGate()
        let ranCancelledOperation = AsyncFlag()

        let holder = Task {
            try? await gate.withExclusiveAccess(for: "server:user") {
                await holderStarted.mark()
                await releaseHolder.wait()
            }
        }
        await holderStarted.wait()

        let waiter = Task { () -> Error? in
            do {
                try await gate.withExclusiveAccess(for: "server:user") {
                    await ranCancelledOperation.setTrue()
                }
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(20))

        // When the waiting task is canceled before the holder releases.
        waiter.cancel()
        await releaseHolder.open()
        await holder.value
        let waiterError = await waiter.value

        // Then the waiter observes cancellation and its operation never runs
        // after release.
        XCTAssertTrue(
            waiterError is CancellationError,
            "A canceled auth waiter should throw CancellationError"
        )
        let ranOperation = await ranCancelledOperation.value
        XCTAssertFalse(
            ranOperation,
            "A canceled auth waiter ran after the holder released the key"
        )
    }

    func testCancelledWaiterDoesNotBlockNextLiveWaiter() async {
        // Given a holder, then a canceled waiter, then a live waiter for the
        // same authentication key.
        let gate = SSHAuthenticationGate()
        let holderStarted = AsyncProbe()
        let releaseHolder = AsyncGate()
        let liveWaiterRan = AsyncFlag()

        let holder = Task {
            try? await gate.withExclusiveAccess(for: "server:user") {
                await holderStarted.mark()
                await releaseHolder.wait()
            }
        }
        await holderStarted.wait()

        let canceledWaiter = Task {
            try? await gate.withExclusiveAccess(for: "server:user") {}
        }
        try? await Task.sleep(for: .milliseconds(20))
        canceledWaiter.cancel()

        let liveWaiter = Task {
            try? await gate.withExclusiveAccess(for: "server:user") {
                await liveWaiterRan.setTrue()
            }
        }

        // When the holder releases.
        await releaseHolder.open()
        await holder.value
        await canceledWaiter.value
        await liveWaiter.value

        // Then the live waiter is not blocked behind the canceled waiter.
        let didRun = await liveWaiterRan.value
        XCTAssertTrue(
            didRun,
            "A canceled auth waiter should not block the next live waiter"
        )
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

private actor AsyncFlag {
    private var storage = false

    var value: Bool {
        storage
    }

    func setTrue() {
        storage = true
    }
}
