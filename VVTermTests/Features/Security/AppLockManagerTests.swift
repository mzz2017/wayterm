import XCTest
@testable import VVTerm

// Test Context:
// These tests protect app-lock and server-unlock state transitions, request
// ownership, coalescing, and timeout behavior. Fakes use controllable time/auth
// assumptions and no biometric hardware; update only when app-lock product
// behavior or the application-layer owner intentionally changes.

@MainActor
final class AppLockManagerTests: XCTestCase {
    private final class StubBiometricAuthService: BiometricAuthServing {
        var availabilityResult: BiometricAvailability
        var authenticateError: Error?
        var delayAuthentication = false
        private(set) var authenticateReasons: [String] = []
        private var authenticationStartedWaiters: [CheckedContinuation<Void, Never>] = []
        private var authenticationContinuation: CheckedContinuation<Void, Never>?

        init(availabilityResult: BiometricAvailability) {
            self.availabilityResult = availabilityResult
        }

        func availability() -> BiometricAvailability {
            availabilityResult
        }

        func authenticate(localizedReason: String, allowPasscodeFallback: Bool) async throws {
            authenticateReasons.append(localizedReason)
            let waiters = authenticationStartedWaiters
            authenticationStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }

            if delayAuthentication {
                await withCheckedContinuation { continuation in
                    authenticationContinuation = continuation
                }
            }

            if let authenticateError {
                throw authenticateError
            }
        }

        func waitUntilAuthenticationStarted() async {
            if !authenticateReasons.isEmpty {
                return
            }

            await withCheckedContinuation { continuation in
                authenticationStartedWaiters.append(continuation)
            }
        }

        func finishAuthentication() {
            authenticationContinuation?.resume()
            authenticationContinuation = nil
        }
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "VVTermTests.AppLockManager.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeLockedServer(
        id: UUID = UUID(),
        name: String = "Protected Server"
    ) -> Server {
        Server(
            id: id,
            workspaceId: UUID(),
            name: name,
            host: "example.test",
            username: "user",
            requiresBiometricUnlock: true
        )
    }

    func testEnableFullAppLockRequiresAvailableBiometry() async {
        // Given a device where biometric authentication is unavailable.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .unavailable("Biometry unavailable")
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        // When the user requests full app lock.
        await manager.requestSetFullAppLockEnabled(true)

        // Then the manager rejects enablement without starting authentication
        // and preserves the availability message for UI.
        XCTAssertFalse(
            manager.fullAppLockEnabled,
            "Full app lock should remain disabled when biometry is unavailable."
        )
        XCTAssertEqual(
            manager.lastErrorMessage,
            "Biometry unavailable",
            "Unavailable biometry should surface the preflight message."
        )
        XCTAssertTrue(
            authService.authenticateReasons.isEmpty,
            "Unavailable biometry should not start an authentication prompt."
        )
    }

    func testEnableFullAppLockAuthenticatesAndUnlocksApp() async {
        // Given a device where biometric authentication is available.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        // When the user enables full app lock.
        await manager.requestSetFullAppLockEnabled(true)

        // Then the manager authenticates once, enables the lock setting, and
        // leaves the current app session unlocked.
        XCTAssertTrue(
            manager.fullAppLockEnabled,
            "Successful authentication should enable full app lock."
        )
        XCTAssertFalse(
            manager.isAppLocked,
            "Enabling full app lock should not immediately lock an authenticated session."
        )
        XCTAssertEqual(
            authService.authenticateReasons.count,
            1,
            "Enabling full app lock should perform exactly one authentication prompt."
        )
    }

    func testGraceSecondsClampToUpperBound() {
        // Given an app-lock manager with an out-of-range grace value.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        // When the grace period is set above the supported upper bound.
        manager.authGraceSeconds = 900

        // Then the manager clamps the persisted value to the product maximum.
        XCTAssertEqual(manager.authGraceSeconds, 300, "App-lock grace seconds should clamp to the 300 second maximum.")
    }

    func testFullAppLockChangeRequestTracksAuthenticationUntilCompletion() async {
        // Given a manager whose biometric authentication is delayed.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)

        // When UI sends intent to enable full app lock.
        let requestID = manager.requestFullAppLockChange(true)
        await authService.waitUntilAuthenticationStarted()

        // Then the application owner tracks the authentication request until
        // the existing async enable flow finishes.
        XCTAssertTrue(
            manager.pendingAppLockRequestIDs.contains(requestID),
            "Full app-lock enablement should stay tracked while biometric auth is in flight."
        )
        XCTAssertFalse(manager.fullAppLockEnabled)

        authService.finishAuthentication()
        await manager.waitForAppLockRequest(requestID)

        XCTAssertFalse(
            manager.pendingAppLockRequestIDs.contains(requestID),
            "Full app-lock request tracking should clear only after authentication completes."
        )
        XCTAssertTrue(manager.fullAppLockEnabled)
        XCTAssertFalse(manager.isAppLocked)
    }

    func testAppUnlockRequestTracksAuthenticationUntilCompletion() async {
        // Given a manager initialized with full app lock enabled and currently
        // locked.
        let defaults = makeDefaults()
        defaults.set(true, forKey: "security.fullAppLockEnabled")
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)

        // When UI sends app-unlock intent.
        let requestID = manager.requestAppUnlock()
        await authService.waitUntilAuthenticationStarted()

        // Then the manager owns and tracks the unlock authentication work until
        // the existing async unlock flow finishes.
        XCTAssertTrue(
            manager.pendingAppLockRequestIDs.contains(requestID),
            "App unlock should stay tracked while biometric auth is in flight."
        )
        XCTAssertTrue(manager.isAppLocked)

        authService.finishAuthentication()
        await manager.waitForAppLockRequest(requestID)

        XCTAssertFalse(
            manager.pendingAppLockRequestIDs.contains(requestID),
            "App unlock request tracking should clear only after authentication completes."
        )
        XCTAssertFalse(manager.isAppLocked)
    }

    func testAppUnlockRequestTreatsCancellationAsLifecycleCompletion() async {
        // Given a locked app whose biometric service reports cooperative task
        // cancellation.
        let defaults = makeDefaults()
        defaults.set(true, forKey: "security.fullAppLockEnabled")
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.authenticateError = CancellationError()
        let manager = AppLockManager(defaults: defaults, authService: authService)

        // When UI sends app-unlock intent through the application owner.
        let requestID = manager.requestAppUnlock()
        await manager.waitForAppLockRequest(requestID)

        // Then cancellation clears request tracking without surfacing a user
        // error or unlocking the app.
        XCTAssertFalse(
            manager.pendingAppLockRequestIDs.contains(requestID),
            "Cancelled app-unlock requests should clear request tracking."
        )
        XCTAssertNil(
            manager.lastErrorMessage,
            "Cancellation should be lifecycle state, not a user-facing app-lock failure."
        )
        XCTAssertTrue(manager.isAppLocked)
    }

    func testServerUnlockRequestTracksAuthenticationUntilCompletion() async {
        // Given a server requiring biometric unlock and a delayed fake
        // authentication prompt.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)
        let server = makeLockedServer(name: "Production")
        var didUnlock = false
        var didDeny = false

        // When UI sends server-unlock intent through AppLockManager.
        let requestID = manager.requestServerUnlock(
            server,
            onUnlocked: { didUnlock = true },
            onDenied: { didDeny = true }
        )
        await authService.waitUntilAuthenticationStarted()

        // Then AppLockManager tracks the server-unlock request until the
        // biometric auth flow finishes.
        XCTAssertTrue(
            manager.pendingAppLockRequestIDs.contains(requestID),
            "Server unlock should be visible in generic app-lock pending requests while auth is in flight."
        )
        XCTAssertTrue(
            manager.pendingServerUnlockRequestIDs.contains(requestID),
            "Server unlock should be visible in server-specific pending requests while auth is in flight."
        )
        XCTAssertFalse(didUnlock)
        XCTAssertFalse(didDeny)

        authService.finishAuthentication()
        await manager.waitForAppLockRequest(requestID)

        XCTAssertFalse(
            manager.pendingAppLockRequestIDs.contains(requestID),
            "Server-unlock request tracking should clear only after auth completion."
        )
        XCTAssertFalse(
            manager.pendingServerUnlockRequestIDs.contains(requestID),
            "Server-specific request tracking should clear after auth completion."
        )
        XCTAssertTrue(didUnlock, "Successful server unlock should run the unlocked callback.")
        XCTAssertFalse(didDeny, "Successful server unlock should not run the denied callback.")
        XCTAssertTrue(
            manager.canAccessServerWithoutPrompt(server),
            "Successful server unlock should grant prompt-free server access for the grace period."
        )
    }

    func testDuplicateServerUnlockRequestsCoalesceUntilCompletion() async {
        // Given a delayed server-unlock authentication request is already in
        // flight for a biometric-protected server.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)
        let server = makeLockedServer()
        var unlockedCallbacks: [String] = []
        var deniedCallbacks: [String] = []

        // When the same server-unlock intent arrives twice before auth exits.
        let firstID = manager.requestServerUnlock(
            server,
            onUnlocked: { unlockedCallbacks.append("first") },
            onDenied: { deniedCallbacks.append("first") }
        )
        let secondID = manager.requestServerUnlock(
            server,
            onUnlocked: { unlockedCallbacks.append("second") },
            onDenied: { deniedCallbacks.append("second") }
        )
        await authService.waitUntilAuthenticationStarted()

        // Then the duplicate request joins the existing manager-owned task
        // instead of starting a second auth call that would be denied by the
        // in-progress authentication guard.
        XCTAssertEqual(
            firstID,
            secondID,
            "Duplicate same-server unlock intent should coalesce to the existing request ID."
        )
        XCTAssertEqual(
            authService.authenticateReasons.count,
            1,
            "Duplicate same-server unlock intent should not start a second biometric prompt."
        )
        XCTAssertEqual(
            manager.pendingServerUnlockRequestIDs,
            [firstID],
            "Only the coalesced server-unlock request should be visible as pending."
        )

        authService.finishAuthentication()
        await manager.waitForAppLockRequest(firstID)

        XCTAssertEqual(
            unlockedCallbacks,
            ["first", "second"],
            "Every coalesced server-unlock caller should receive the unlocked callback after auth exits."
        )
        XCTAssertTrue(
            deniedCallbacks.isEmpty,
            "Duplicate same-server unlock intent must not be reported as denied while auth is already in progress."
        )
    }

    func testServerUnlockCancellationDoesNotRunCallbacksOrSetError() async {
        // Given lifecycle teardown cancels a pending server-unlock request.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)
        let server = makeLockedServer()
        var didUnlock = false
        var didDeny = false

        let requestID = manager.requestServerUnlock(
            server,
            onUnlocked: { didUnlock = true },
            onDenied: { didDeny = true }
        )
        await authService.waitUntilAuthenticationStarted()

        manager.cancelServerUnlockRequestForTesting(requestID)
        authService.finishAuthentication()
        await manager.waitForAppLockRequest(requestID)

        // Then cancellation is lifecycle completion: callbacks and user-facing
        // auth errors stay silent, pending state clears, and no unlock grant is
        // recorded after cancellation.
        XCTAssertFalse(didUnlock, "Canceled server-unlock requests should not run unlocked callbacks.")
        XCTAssertFalse(didDeny, "Canceled server-unlock requests should not run denied callbacks.")
        XCTAssertFalse(
            manager.pendingServerUnlockRequestIDs.contains(requestID),
            "Canceled server-unlock requests should clear pending state after the task exits."
        )
        XCTAssertNil(
            manager.lastErrorMessage,
            "Server-unlock cancellation should not surface as a user-facing auth failure."
        )
        XCTAssertFalse(
            manager.canAccessServerWithoutPrompt(server),
            "Canceled server-unlock requests should not leave a prompt-free access grant."
        )
    }

    func testServerUnlockCancellationDuringFullAppUnlockDoesNotGrantAppAccess() async {
        // Given full app lock is enabled and a server-unlock request must first
        // unlock the app through delayed biometric authentication.
        let defaults = makeDefaults()
        defaults.set(true, forKey: "security.fullAppLockEnabled")
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)
        let server = makeLockedServer()
        var didUnlock = false
        var didDeny = false

        let requestID = manager.requestServerUnlock(
            server,
            onUnlocked: { didUnlock = true },
            onDenied: { didDeny = true }
        )
        await authService.waitUntilAuthenticationStarted()

        manager.cancelServerUnlockRequestForTesting(requestID)
        authService.finishAuthentication()
        await manager.waitForAppLockRequest(requestID)

        // Then cancellation during the nested app-unlock phase must not leave
        // an app-level unlock grant or unlock the server.
        XCTAssertTrue(
            manager.isAppLocked,
            "Canceled server-unlock requests should not unlock the app during nested full-app-lock authentication."
        )
        XCTAssertFalse(didUnlock, "Canceled nested app-unlock work should not run server unlocked callbacks.")
        XCTAssertFalse(didDeny, "Canceled nested app-unlock work should not run server denied callbacks.")
        XCTAssertFalse(
            manager.canAccessServerWithoutPrompt(server),
            "Canceled nested app-unlock work should not grant prompt-free server access."
        )
        XCTAssertNil(
            manager.lastErrorMessage,
            "Cancellation during nested app unlock should not surface a user-facing auth error."
        )
    }

    func testCancelAllAndWaitCancelsFullLockEnableWithoutApplyingLateAuthSuccess() async {
        // Given full-lock enablement is blocked in biometric authentication.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)

        let requestID = manager.requestFullAppLockChange(true)
        await authService.waitUntilAuthenticationStarted()

        // When app-level teardown cancels all auth work.
        let cleanupTask = Task {
            await manager.cancelAllAndWait()
        }
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(
            manager.pendingAppLockRequestIDs.isEmpty,
            "Auth cleanup should clear visible pending app-lock requests immediately."
        )

        authService.finishAuthentication()
        await cleanupTask.value
        await manager.waitForAppLockRequest(requestID)

        // Then a late auth success from the canceled request must not enable
        // full app lock.
        XCTAssertFalse(
            manager.fullAppLockEnabled,
            "Canceled full-lock enablement must not apply a late successful authentication result."
        )
        XCTAssertFalse(
            manager.isAppLocked,
            "Canceled full-lock enablement should not change app lock state."
        )
    }

    func testCancelAllAndWaitCancelsServerUnlockCallbacksAndWaitsForAuthExit() async {
        // Given a server-unlock request is blocked in biometric authentication.
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.delayAuthentication = true
        let manager = AppLockManager(defaults: defaults, authService: authService)
        let server = makeLockedServer()
        var didUnlock = false
        var didDeny = false

        let requestID = manager.requestServerUnlock(
            server,
            onUnlocked: { didUnlock = true },
            onDenied: { didDeny = true }
        )
        await authService.waitUntilAuthenticationStarted()

        // When app-level teardown cancels all auth work.
        let cleanupCompleted = AuthCleanupProbe()
        let cleanupTask = Task {
            await manager.cancelAllAndWait()
            await cleanupCompleted.mark()
        }
        try? await Task.sleep(for: .milliseconds(20))

        // Then cleanup remains awaitable until the in-flight auth request
        // exits, while visible pending state is cleared immediately.
        let cleanupDidCompleteBeforeAuthExit = await cleanupCompleted.isMarked()
        XCTAssertFalse(
            cleanupDidCompleteBeforeAuthExit,
            "Auth cleanup must remain awaitable until the in-flight authentication exits."
        )
        XCTAssertFalse(
            manager.pendingServerUnlockRequestIDs.contains(requestID),
            "Auth cleanup should clear visible server-unlock requests immediately."
        )

        authService.finishAuthentication()
        await cleanupTask.value

        let cleanupDidCompleteAfterAuthExit = await cleanupCompleted.isMarked()
        XCTAssertTrue(cleanupDidCompleteAfterAuthExit)
        XCTAssertFalse(didUnlock, "Canceled server unlock cleanup must not run unlocked callbacks.")
        XCTAssertFalse(didDeny, "Canceled server unlock cleanup must not run denied callbacks.")
        XCTAssertFalse(
            manager.canAccessServerWithoutPrompt(server),
            "Canceled server unlock cleanup must not leave a server access grant."
        )
    }
}

private actor AuthCleanupProbe {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
