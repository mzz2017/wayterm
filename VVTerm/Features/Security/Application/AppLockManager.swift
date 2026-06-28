import Foundation
import Combine
import SwiftUI

@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    private enum Keys {
        static let fullAppLockEnabled = "security.fullAppLockEnabled"
        static let lockOnBackground = "security.lockOnBackground"
        static let authGraceSeconds = "security.authGraceSeconds"
    }

    private struct ServerUnlockRequest {
        let requestID: UUID
        var task: Task<Void, Never>?
        var onUnlockedCallbacks: [@MainActor () -> Void]
        var onDeniedCallbacks: [@MainActor () -> Void]
    }

    @Published private(set) var isAppLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isBiometryAvailable = false
    @Published private(set) var biometryKind: BiometryKind = .none
    @Published private(set) var biometryAvailabilityMessage: String?

    @Published var fullAppLockEnabled: Bool {
        didSet {
            defaults.set(fullAppLockEnabled, forKey: Keys.fullAppLockEnabled)
            if !fullAppLockEnabled {
                clearUnlockState()
                isAppLocked = false
            }
        }
    }

    @Published var lockOnBackground: Bool {
        didSet {
            defaults.set(lockOnBackground, forKey: Keys.lockOnBackground)
        }
    }

    @Published var authGraceSeconds: Int {
        didSet {
            let clamped = max(0, min(authGraceSeconds, 300))
            if clamped != authGraceSeconds {
                authGraceSeconds = clamped
                return
            }
            defaults.set(authGraceSeconds, forKey: Keys.authGraceSeconds)
        }
    }

    var biometryDisplayName: String {
        biometryKind.displayName
    }

    private let defaults: UserDefaults
    private let authService: any BiometricAuthServing
    private var lastAppUnlockAt: Date?
    private var unlockedServers: [UUID: Date] = [:]
    private var appLockRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var serverUnlockRequestsByServerID: [UUID: ServerUnlockRequest] = [:]

    var pendingAppLockRequestIDs: Set<UUID> {
        Set(appLockRequestTasks.keys)
    }

    var pendingServerUnlockRequestIDs: Set<UUID> {
        Set(serverUnlockRequestsByServerID.values.map(\.requestID))
    }

    init(defaults: UserDefaults, authService: any BiometricAuthServing) {
        self.defaults = defaults
        self.authService = authService

        let fullLockEnabled = defaults.object(forKey: Keys.fullAppLockEnabled) as? Bool ?? false
        self.fullAppLockEnabled = fullLockEnabled
        self.lockOnBackground = defaults.object(forKey: Keys.lockOnBackground) as? Bool ?? true
        let storedGrace = defaults.object(forKey: Keys.authGraceSeconds) as? Int ?? 30
        self.authGraceSeconds = max(0, min(storedGrace, 300))
        self.isAppLocked = fullLockEnabled

        refreshBiometryAvailability()
    }

    convenience init() {
        self.init(defaults: .standard, authService: BiometricAuthService.shared)
    }

    deinit {
        appLockRequestTasks.values.forEach { $0.cancel() }
        serverUnlockRequestsByServerID.values.compactMap(\.task).forEach { $0.cancel() }
    }

    func refreshBiometryAvailability() {
        switch authService.availability() {
        case .available(let kind):
            isBiometryAvailable = true
            biometryKind = kind
            biometryAvailabilityMessage = nil
        case .unavailable(let message):
            isBiometryAvailable = false
            biometryKind = .none
            biometryAvailabilityMessage = message
        }
    }

    @discardableResult
    func requestFullAppLockChange(_ enabled: Bool) -> UUID {
        trackAppLockRequest { manager in
            await manager.requestSetFullAppLockEnabled(enabled)
        }
    }

    @discardableResult
    func requestAppUnlock() -> UUID {
        trackAppLockRequest { manager in
            _ = await manager.ensureAppUnlocked()
        }
    }

    @discardableResult
    func requestServerUnlock(
        _ server: Server,
        onUnlocked: @escaping @MainActor () -> Void = {},
        onDenied: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        if var request = serverUnlockRequestsByServerID[server.id] {
            request.onUnlockedCallbacks.append(onUnlocked)
            request.onDeniedCallbacks.append(onDenied)
            serverUnlockRequestsByServerID[server.id] = request
            return request.requestID
        }

        let requestID = UUID()
        serverUnlockRequestsByServerID[server.id] = ServerUnlockRequest(
            requestID: requestID,
            task: nil,
            onUnlockedCallbacks: [onUnlocked],
            onDeniedCallbacks: [onDenied]
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.serverUnlockRequestsByServerID[server.id]?.requestID == requestID {
                    self.serverUnlockRequestsByServerID.removeValue(forKey: server.id)
                }
                self.appLockRequestTasks.removeValue(forKey: requestID)
            }

            let unlocked = await self.ensureServerUnlocked(server)
            guard !Task.isCancelled else { return }
            guard let request = self.serverUnlockRequestsByServerID[server.id],
                  request.requestID == requestID
            else { return }

            let callbacks = unlocked ? request.onUnlockedCallbacks : request.onDeniedCallbacks
            callbacks.forEach { $0() }
        }

        if serverUnlockRequestsByServerID[server.id]?.requestID == requestID {
            serverUnlockRequestsByServerID[server.id]?.task = task
            appLockRequestTasks[requestID] = task
        }

        return requestID
    }

    func waitForAppLockRequest(_ requestID: UUID) async {
        await appLockRequestTasks[requestID]?.value
    }

    func cancelAllAndWait() async {
        let tasks = Array(appLockRequestTasks.values)

        appLockRequestTasks.values.forEach { $0.cancel() }
        serverUnlockRequestsByServerID.values.compactMap(\.task).forEach { $0.cancel() }
        appLockRequestTasks.removeAll()
        serverUnlockRequestsByServerID.removeAll()

        for task in tasks {
            await task.value
        }
    }

    func requestSetFullAppLockEnabled(_ enabled: Bool) async {
        lastErrorMessage = nil

        guard enabled != fullAppLockEnabled else { return }

        if !enabled {
            fullAppLockEnabled = false
            return
        }

        refreshBiometryAvailability()
        guard isBiometryAvailable else {
            lastErrorMessage = biometryAvailabilityMessage
            return
        }

        let reason = String(format: String(localized: "Enable %@ for VVTerm"), biometryDisplayName)
        guard await authenticate(reason: reason) else { return }
        guard !Task.isCancelled else { return }

        fullAppLockEnabled = true
        isAppLocked = false
        lastAppUnlockAt = Date()
    }

    func ensureAppUnlocked() async -> Bool {
        guard fullAppLockEnabled else { return true }
        guard isAppLocked else { return true }

        let reason = String(format: String(localized: "Unlock VVTerm with %@"), biometryDisplayName)
        guard await authenticate(reason: reason) else { return false }
        guard !Task.isCancelled else { return false }

        isAppLocked = false
        lastAppUnlockAt = Date()
        lastErrorMessage = nil
        return true
    }

    func canAccessServerWithoutPrompt(_ server: Server) -> Bool {
        guard server.requiresBiometricUnlock else { return true }
        purgeExpiredUnlocks()

        if hasValidGrant(lastAppUnlockAt) {
            return true
        }

        return hasValidGrant(unlockedServers[server.id])
    }

    func ensureServerUnlocked(_ server: Server) async -> Bool {
        guard server.requiresBiometricUnlock else { return true }
        guard !Task.isCancelled else { return false }

        if fullAppLockEnabled, isAppLocked {
            guard await ensureAppUnlocked() else { return false }
            guard !Task.isCancelled else { return false }
        }

        if canAccessServerWithoutPrompt(server) {
            return true
        }

        let reason = String(format: String(localized: "Unlock server %@"), server.name)
        guard await authenticate(reason: reason) else { return false }
        guard !Task.isCancelled else { return false }

        unlockedServers[server.id] = Date()
        lastErrorMessage = nil
        return true
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            refreshBiometryAvailability()
        case .background:
            lockIfNeededForBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func lockIfNeededForBackground() {
        guard fullAppLockEnabled, lockOnBackground else { return }
        lockAppNow()
    }

    func lockAppNow() {
        guard fullAppLockEnabled else { return }
        isAppLocked = true
        clearUnlockState()
    }

    private func clearUnlockState() {
        lastAppUnlockAt = nil
        unlockedServers.removeAll()
    }

    private func hasValidGrant(_ date: Date?) -> Bool {
        guard let date else { return false }
        guard authGraceSeconds > 0 else { return false }
        return Date().timeIntervalSince(date) <= TimeInterval(authGraceSeconds)
    }

    private func purgeExpiredUnlocks() {
        guard authGraceSeconds > 0 else {
            unlockedServers.removeAll()
            return
        }

        let threshold = Date().addingTimeInterval(-TimeInterval(authGraceSeconds))
        unlockedServers = unlockedServers.filter { $0.value >= threshold }
    }

    private func trackAppLockRequest(_ operation: @escaping @MainActor (AppLockManager) async -> Void) -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                appLockRequestTasks.removeValue(forKey: requestID)
            }

            await operation(self)
        }
        appLockRequestTasks[requestID] = task
        return requestID
    }

    private func authenticate(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            try await authService.authenticate(localizedReason: reason, allowPasscodeFallback: true)
            return true
        } catch is CancellationError {
            return false
        } catch let error as BiometricAuthError {
            if !error.isCancellation {
                lastErrorMessage = error.localizedDescription
            }
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }
}

#if DEBUG
extension AppLockManager {
    func cancelServerUnlockRequestForTesting(_ requestID: UUID) {
        guard let request = serverUnlockRequestsByServerID.values.first(where: { $0.requestID == requestID }) else {
            return
        }
        request.task?.cancel()
    }
}
#endif
