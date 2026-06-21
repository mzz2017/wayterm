import XCTest
@testable import VVTerm

// Test Context:
// These tests protect app-lock state transitions and timeout behavior. Fakes use
// controllable time/auth assumptions and no biometric hardware; update only when
// app-lock product behavior intentionally changes.

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
}
