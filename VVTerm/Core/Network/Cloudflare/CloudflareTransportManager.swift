import Foundation
import Cloudflared
import os.log

nonisolated protocol CloudflareTransportSession: AnyObject, Sendable {
    func connect(hostname: String, method: Cloudflared.AuthMethod) async throws -> UInt16
    func disconnect() async
}

extension SessionActor: CloudflareTransportSession {}

nonisolated protocol CloudflareTransportManaging: Sendable {
    func connect(target: SSHConnectionTarget, credentials: ServerCredentials) async throws -> UInt16
    func disconnect() async
}

actor CloudflareTransportManager: CloudflareTransportManaging {
    private typealias SessionFactory = @Sendable (any AuthProviding) -> any CloudflareTransportSession

    private struct AccessMetadata: Sendable {
        let teamDomain: String
        let appDomain: String
    }
    private struct ConnectingSession: Sendable {
        let requestID: UUID
        let session: any CloudflareTransportSession
    }
    private struct PersistedAccessMetadata: Codable {
        let teamDomain: String
        let appDomain: String
    }
    private actor TimeoutContinuation<T: Sendable> {
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }

        func resume(throwing error: any Error) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }
    private final class TimeoutTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []
        private var isCancelled = false

        func store(_ tasks: [Task<Void, Never>]) {
            lock.lock()
            let shouldCancel = isCancelled
            if !shouldCancel {
                self.tasks = tasks
            }
            lock.unlock()

            if shouldCancel {
                tasks.forEach { $0.cancel() }
            }
        }

        func cancelAll() {
            lock.lock()
            isCancelled = true
            let tasks = self.tasks
            self.tasks = []
            lock.unlock()

            tasks.forEach { $0.cancel() }
        }
    }
    private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let callbackScheme = "vvterm-cfaccess"
    private let userAgent = "VVTerm"
    private let discoveryTimeout: TimeInterval = 12
    private let disconnectTimeout: Duration
    private let metadataKeychain = KeychainStore(service: "app.vivy.vvterm.cloudflare.metadata")
    private let metadataStorageKey = "cache.v1"
    private let makeSession: SessionFactory
    private var activeSession: (any CloudflareTransportSession)?
    private var connectingSession: ConnectingSession?
    private var activeConnectRequestID: UUID?
    private var cleanedConnectRequestIDs: Set<UUID> = []
    private var metadataCache: [String: AccessMetadata] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "CloudflareTransport")

    init(
        disconnectTimeout: Duration = .seconds(4),
        makeSession: @escaping @Sendable (any AuthProviding) -> any CloudflareTransportSession = { authProvider in
            SessionActor(
                authProvider: authProvider,
                tunnelProvider: CloudflareTunnelProvider(),
                retryPolicy: RetryPolicy(maxReconnectAttempts: 1, baseDelayNanoseconds: 500_000_000),
                oauthFallback: nil,
                sleep: { delay in
                    try? await Task.sleep(nanoseconds: delay)
                }
            )
        }
    ) {
        self.disconnectTimeout = disconnectTimeout
        self.makeSession = makeSession
    }

    func connect(target: SSHConnectionTarget, credentials: ServerCredentials) async throws -> UInt16 {
        let requestID = UUID()
        activeConnectRequestID = requestID
        defer {
            clearConnectRequestIfCurrent(requestID)
            clearConnectingSessionIfCurrent(requestID)
            cleanedConnectRequestIDs.remove(requestID)
        }
        await disconnectOwnedSessions()
        try checkConnectRequestIsCurrent(requestID)

        let hostname = target.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            throw SSHError.cloudflareConfigurationRequired(
                String(localized: "Cloudflare transport requires a valid hostname.")
            )
        }

        let accessMode = target.cloudflareAccessMode ?? .oauth
        let metadata = try await resolveAccessMetadata(for: hostname, target: target, mode: accessMode)
        try checkConnectRequestIsCurrent(requestID)

        let authProvider: any AuthProviding
        let authMethod: Cloudflared.AuthMethod

        switch accessMode {
        case .oauth:
            authProvider = OAuthProvider(
                flow: CloudflareOAuthFlow(userAgent: userAgent),
                tokenStore: CloudflareTokenStoreAdapter()
            )
            authMethod = .oauth(
                teamDomain: metadata.teamDomain,
                appDomain: metadata.appDomain,
                callbackScheme: callbackScheme
            )

        case .serviceToken:
            let clientID = credentials.cloudflareClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clientSecret = credentials.cloudflareClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !clientID.isEmpty else {
                throw SSHError.cloudflareConfigurationRequired(
                    String(localized: "Cloudflare service token client ID is required.")
                )
            }
            guard !clientSecret.isEmpty else {
                throw SSHError.cloudflareConfigurationRequired(
                    String(localized: "Cloudflare service token client secret is required.")
                )
            }

            authProvider = ServiceTokenProvider()
            authMethod = .serviceToken(
                teamDomain: metadata.teamDomain,
                clientID: clientID,
                clientSecret: clientSecret
            )
        }

        let session = makeSession(authProvider)
        connectingSession = ConnectingSession(requestID: requestID, session: session)
        var shouldCleanupSession = true

        do {
            let localPort = try await session.connect(hostname: hostname, method: authMethod)
            guard isCurrentConnectingSession(requestID), activeConnectRequestID == requestID else {
                await cleanupConnectingSessionIfNeeded(session, requestID: requestID)
                shouldCleanupSession = false
                throw CancellationError()
            }
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            activeSession = session
            clearConnectingSessionIfCurrent(requestID)
            shouldCleanupSession = false
            return localPort
        } catch is CancellationError {
            if shouldCleanupSession {
                await cleanupConnectingSessionIfNeeded(session, requestID: requestID)
            }
            throw CancellationError()
        } catch let failure as Failure {
            if shouldCleanupSession {
                await cleanupConnectingSessionIfNeeded(session, requestID: requestID)
            }
            throw mapFailure(failure)
        } catch {
            if shouldCleanupSession {
                await cleanupConnectingSessionIfNeeded(session, requestID: requestID)
            }
            throw SSHError.cloudflareTunnelFailed(error.localizedDescription)
        }
    }

    func disconnect() async {
        activeConnectRequestID = nil
        await disconnectOwnedSessions()
    }

    private func disconnectOwnedSessions() async {
        let activeSession = activeSession
        let connectingSession = connectingSession
        self.activeSession = nil
        self.connectingSession = nil
        if let connectingSession {
            cleanedConnectRequestIDs.insert(connectingSession.requestID)
        }

        if let activeSession {
            await disconnect(session: activeSession)
        }
        if let connectingSession {
            await disconnect(session: connectingSession.session)
        }
    }

    private func clearConnectRequestIfCurrent(_ requestID: UUID) {
        if activeConnectRequestID == requestID {
            activeConnectRequestID = nil
        }
    }

    private func clearConnectingSessionIfCurrent(_ requestID: UUID) {
        guard connectingSession?.requestID == requestID else { return }
        connectingSession = nil
    }

    private func isCurrentConnectingSession(_ requestID: UUID) -> Bool {
        connectingSession?.requestID == requestID
    }

    private func checkConnectRequestIsCurrent(_ requestID: UUID) throws {
        guard activeConnectRequestID == requestID, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func cleanupConnectingSessionIfNeeded(
        _ session: any CloudflareTransportSession,
        requestID: UUID
    ) async {
        guard cleanedConnectRequestIDs.insert(requestID).inserted else { return }
        clearConnectingSessionIfCurrent(requestID)
        await disconnect(session: session)
    }

    private func disconnect(session: any CloudflareTransportSession) async {
        do {
            try await disconnectWithTimeout(session)
        } catch {
            logger.warning("Timed out while disconnecting Cloudflare transport session")
        }
    }

    private func disconnectWithTimeout(_ session: any CloudflareTransportSession) async throws {
        try await CloudflareTransportManager.runWithTimeout(disconnectTimeout) {
            await session.disconnect()
        }
    }

    private nonisolated static func runWithTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let taskBox = TimeoutTaskBox()
        return try await withTaskCancellationHandler {
            defer { taskBox.cancelAll() }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let gate = TimeoutContinuation(continuation)
                let operationTask = Task {
                    do {
                        let value = try await operation()
                        await gate.resume(returning: value)
                    } catch {
                        await gate.resume(throwing: error)
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        await gate.resume(throwing: SSHError.timeout)
                    } catch is CancellationError {
                        // The operation completed before the timeout fired.
                    } catch {
                        await gate.resume(throwing: error)
                    }
                }
                taskBox.store([operationTask, timeoutTask])
            }
        } onCancel: {
            taskBox.cancelAll()
        }
    }

    private func resolveAccessMetadata(
        for hostname: String,
        target: SSHConnectionTarget,
        mode: CloudflareAccessMode
    ) async throws -> AccessMetadata {
        let cacheKey = metadataCacheKey(for: hostname)
        let teamOverride = target.cloudflareTeamDomainOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedHost = normalizedHostName(from: hostname)
        switch mode {
        case .oauth:
            // OAuth flow can resolve metadata during browser auth.
            // Keep this path host-driven so users only need to provide the SSH host.
            if !teamOverride.isEmpty {
                let metadata = AccessMetadata(teamDomain: teamOverride, appDomain: normalizedHost)
                metadataCache[cacheKey] = metadata
                persistMetadata(metadata, for: cacheKey)
                return metadata
            }
            clearCachedMetadata(for: cacheKey)

            // Last-resort hint for OAuth only (do not persist; may not be a real team domain).
            return AccessMetadata(teamDomain: normalizedHost, appDomain: normalizedHost)

        case .serviceToken:
            if !teamOverride.isEmpty {
                let metadata = AccessMetadata(
                    teamDomain: teamOverride,
                    appDomain: normalizedHost
                )
                metadataCache[cacheKey] = metadata
                persistMetadata(metadata, for: cacheKey)
                return metadata
            }

            if let cached = metadataCache[cacheKey] {
                return cached
            }
            if let persisted = loadPersistedMetadata(for: cacheKey) {
                metadataCache[cacheKey] = persisted
                return persisted
            }

            do {
                let discovered = try await discoverAccessMetadata(hostname: hostname)
                metadataCache[cacheKey] = discovered
                persistMetadata(discovered, for: cacheKey)
                return discovered
            } catch {
                throw SSHError.cloudflareConfigurationRequired(
                    String(
                        localized: "Could not auto-discover Cloudflare Team Domain (\(describeFailure(error))). Add Team Domain override (for example: team.cloudflareaccess.com)."
                    )
                )
            }
        }
    }

    private func normalizedHostName(from hostname: String) -> String {
        if let normalizedURL = try? URLTools.normalizeOriginURL(from: hostname),
           let host = normalizedURL.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }
        return hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metadataCacheKey(for hostname: String) -> String {
        hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func loadPersistedMetadata(for cacheKey: String) -> AccessMetadata? {
        guard
            let data = try? metadataKeychain.get(metadataStorageKey),
            let persistedMap = try? JSONDecoder().decode([String: PersistedAccessMetadata].self, from: data),
            let persisted = persistedMap[cacheKey]
        else {
            return nil
        }
        return AccessMetadata(teamDomain: persisted.teamDomain, appDomain: persisted.appDomain)
    }

    private func persistMetadata(_ metadata: AccessMetadata, for cacheKey: String) {
        var persistedMap: [String: PersistedAccessMetadata] = [:]
        if let existingData = try? metadataKeychain.get(metadataStorageKey),
           let decoded = try? JSONDecoder().decode([String: PersistedAccessMetadata].self, from: existingData) {
            persistedMap = decoded
        }

        persistedMap[cacheKey] = PersistedAccessMetadata(
            teamDomain: metadata.teamDomain,
            appDomain: metadata.appDomain
        )
        if let encoded = try? JSONEncoder().encode(persistedMap) {
            try? metadataKeychain.set(encoded, forKey: metadataStorageKey, iCloudSync: SyncSettings.isEnabled)
        }
    }

    private func clearCachedMetadata(for cacheKey: String) {
        metadataCache.removeValue(forKey: cacheKey)
        guard
            let existingData = try? metadataKeychain.get(metadataStorageKey),
            var persistedMap = try? JSONDecoder().decode([String: PersistedAccessMetadata].self, from: existingData),
            persistedMap.removeValue(forKey: cacheKey) != nil
        else {
            return
        }

        if persistedMap.isEmpty {
            try? metadataKeychain.delete(metadataStorageKey)
            return
        }

        if let encoded = try? JSONEncoder().encode(persistedMap) {
            try? metadataKeychain.set(encoded, forKey: metadataStorageKey, iCloudSync: SyncSettings.isEnabled)
        }
    }

    private func discoverMetadata(hostname: String) async throws -> AccessMetadata {
        let appURL = try URLTools.normalizeOriginURL(from: hostname)
        let appInfo = try await AppInfoResolver(
            client: URLSessionHTTPClient(),
            userAgent: userAgent
        ).resolve(appURL: appURL)
        return AccessMetadata(teamDomain: appInfo.authDomain, appDomain: appInfo.appDomain)
    }

    private func discoverAccessMetadata(hostname: String) async throws -> AccessMetadata {
        let appURL = try URLTools.normalizeOriginURL(from: hostname)
        if let strict = try? await discoverMetadata(hostname: hostname) {
            return strict
        }

        let appHost = appURL.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? hostname
        let normalizedAppDomain = appHost.isEmpty ? hostname : appHost
        var discoveryErrors: [String] = []
        let methods = ["HEAD", "GET"]

        for method in methods {
            do {
                if let followed = try await discoverByFollowingRedirect(appURL: appURL, method: method, appDomainFallback: normalizedAppDomain) {
                    return followed
                }
            } catch {
                discoveryErrors.append("\(method)-follow: \(describeFailure(error))")
            }
        }

        for method in methods {
            do {
                if let fromLocation = try await discoverByLocationHeader(appURL: appURL, method: method, appDomainFallback: normalizedAppDomain) {
                    return fromLocation
                }
            } catch {
                discoveryErrors.append("\(method)-location: \(describeFailure(error))")
            }
        }

        let details = discoveryErrors.isEmpty
            ? "no redirect host or Location header present"
            : discoveryErrors.joined(separator: "; ")
        throw Failure.protocolViolation("unable to derive Cloudflare team domain from Access redirect (\(details))")
    }

    private func discoverByFollowingRedirect(
        appURL: URL,
        method: String,
        appDomainFallback: String
    ) async throws -> AccessMetadata? {
        var request = URLRequest(url: appURL)
        request.httpMethod = method
        request.timeoutInterval = discoveryTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (_, responseRaw) = try await URLSession.shared.data(for: request)
        guard let response = responseRaw as? HTTPURLResponse else {
            return nil
        }

        guard let finalHost = response.url?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !finalHost.isEmpty,
              finalHost != appDomainFallback else {
            return nil
        }

        let discoveredAppDomain = response.value(forHTTPHeaderField: AccessHeader.appDomain)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appDomain = (discoveredAppDomain?.isEmpty == false) ? discoveredAppDomain! : appDomainFallback
        return AccessMetadata(teamDomain: finalHost, appDomain: appDomain)
    }

    private func discoverByLocationHeader(
        appURL: URL,
        method: String,
        appDomainFallback: String
    ) async throws -> AccessMetadata? {
        let config = URLSessionConfiguration.ephemeral
        let delegate = RedirectBlockingDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: appURL)
        request.httpMethod = method
        request.timeoutInterval = discoveryTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (_, responseRaw) = try await session.data(for: request)
        guard let response = responseRaw as? HTTPURLResponse else {
            return nil
        }

        guard let location = response.value(forHTTPHeaderField: "Location"),
              let locationURL = URL(string: location, relativeTo: appURL),
              let teamHost = locationURL.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamHost.isEmpty else {
            return nil
        }

        let discoveredAppDomain = response.value(forHTTPHeaderField: AccessHeader.appDomain)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appDomain = (discoveredAppDomain?.isEmpty == false) ? discoveredAppDomain! : appDomainFallback
        return AccessMetadata(teamDomain: teamHost, appDomain: appDomain)
    }

    private func describeFailure(_ error: Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .invalidState(let message),
                 .auth(let message),
                 .configuration(let message),
                 .protocolViolation(let message),
                 .internalError(let message):
                return message
            case .transport(let message, _):
                return message
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? String(describing: error) : message
    }

    private func mapFailure(_ failure: Failure) -> SSHError {
        switch failure {
        case .auth(let message):
            return .cloudflareAuthenticationFailed(message)
        case .configuration(let message), .protocolViolation(let message):
            return .cloudflareConfigurationRequired(message)
        case .transport(let message, _):
            return .cloudflareTunnelFailed(message)
        case .invalidState(let message), .internalError(let message):
            return .cloudflareTunnelFailed(message)
        }
    }

}
