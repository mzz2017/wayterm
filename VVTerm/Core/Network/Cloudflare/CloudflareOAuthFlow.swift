import Foundation
import AuthenticationServices
import Cloudflared
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CloudflareOAuthFlow: OAuthFlow {
    private let flow: TransferOAuthFlow

    init(userAgent: String = "VVTerm") {
        self.flow = TransferOAuthFlow(
            webSession: CloudflareWebAuthenticationSessionActor(),
            userAgent: userAgent
        )
    }

    func fetchToken(
        teamDomain: String,
        appDomain: String,
        callbackScheme: String,
        hostname: String
    ) async throws -> String {
        try await flow.fetchToken(
            teamDomain: teamDomain,
            appDomain: appDomain,
            callbackScheme: callbackScheme,
            hostname: hostname
        )
    }
}

nonisolated struct CloudflareOAuthSessionLifecycleState: Sendable {
    private(set) var currentSessionID: UUID?
    private(set) var ignoredCompletionSessionIDs: Set<UUID> = []

    var hasCurrentSession: Bool {
        currentSessionID != nil
    }

    mutating func beginStart() -> UUID {
        invalidateCurrentSession()
        let sessionID = UUID()
        currentSessionID = sessionID
        return sessionID
    }

    mutating func invalidateCurrentSession() {
        if let currentSessionID {
            ignoredCompletionSessionIDs.insert(currentSessionID)
            self.currentSessionID = nil
        }
    }

    func isCurrent(_ sessionID: UUID) -> Bool {
        currentSessionID == sessionID
    }

    mutating func finishIfCurrent(_ sessionID: UUID) {
        if currentSessionID == sessionID {
            currentSessionID = nil
        }
    }

    mutating func consumeIgnoredCompletion(_ sessionID: UUID) -> Bool {
        ignoredCompletionSessionIDs.remove(sessionID) != nil
    }
}

actor CloudflareWebAuthenticationSessionActor: OAuthWebSession {
    private let completionTasks = CloudflareOAuthCompletionTaskRegistry()
    private var currentSession: CloudflareWebAuthenticationSessionHandle?
    private var sessionState = CloudflareOAuthSessionLifecycleState()
    private var userDidCancel = false
    private var presentationContextProvider: CloudflarePresentationContextProvider?

    func start(url: URL) async throws {
        if currentSession != nil || sessionState.hasCurrentSession {
            await resetForRestart()
        }

        userDidCancel = false

        let sessionID = sessionState.beginStart()
        let provider = await ensurePresentationContextProvider()
        guard sessionState.isCurrent(sessionID) else {
            throw CancellationError()
        }

        let completionTasks = completionTasks
        let session = await MainActor.run {
            CloudflareWebAuthenticationSessionHandle(url: url, callbackURLScheme: nil) { [self] _, error in
                completionTasks.track {
                    await self.handleCompletion(sessionID: sessionID, error: error)
                }
            }
        }

        await session.configure(presentationContextProvider: provider)
        guard sessionState.isCurrent(sessionID) else {
            await session.cancel()
            throw CancellationError()
        }

        currentSession = session
        let didStart = await session.start()
        guard sessionState.isCurrent(sessionID) else {
            await session.cancel()
            throw CancellationError()
        }

        if !didStart {
            currentSession = nil
            sessionState.finishIfCurrent(sessionID)
            throw Failure.auth("Failed to start Cloudflare login session")
        }
    }

    func stop() async {
        guard currentSession != nil || sessionState.hasCurrentSession else { return }
        sessionState.invalidateCurrentSession()
        if let session = currentSession {
            await session.cancel()
        }
        currentSession = nil
        await waitForCompletionTasks()
    }

    func didCancelLogin() async -> Bool {
        userDidCancel
    }

    private func resetForRestart() async {
        sessionState.invalidateCurrentSession()
        if let session = currentSession {
            await session.cancel()
        }
        currentSession = nil
        userDidCancel = false
        await waitForCompletionTasks()
    }

    private func ensurePresentationContextProvider() async -> CloudflarePresentationContextProvider {
        if let presentationContextProvider {
            return presentationContextProvider
        }
        let provider = await MainActor.run {
            CloudflarePresentationContextProvider()
        }
        presentationContextProvider = provider
        return provider
    }

    private func handleCompletion(sessionID: UUID, error: Error?) {
        let isCurrentSession = sessionState.isCurrent(sessionID)
        defer {
            if isCurrentSession {
                currentSession = nil
                sessionState.finishIfCurrent(sessionID)
            }
        }

        if sessionState.consumeIgnoredCompletion(sessionID) {
            return
        }

        guard isCurrentSession else {
            return
        }

        if let authError = error as? ASWebAuthenticationSessionError,
           authError.code == .canceledLogin {
            userDidCancel = true
        } else if error != nil {
            userDidCancel = true
        }
    }

    private func waitForCompletionTasks() async {
        while true {
            let tasks = completionTasks.tasks()
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }
}

private struct CloudflareWebAuthenticationSessionHandle: @unchecked Sendable {
    nonisolated(unsafe) private let session: ASWebAuthenticationSession

    @MainActor
    init(
        url: URL,
        callbackURLScheme: String?,
        completionHandler: @escaping (URL?, Error?) -> Void
    ) {
        session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackURLScheme,
            completionHandler: completionHandler
        )
    }

    @MainActor
    func configure(presentationContextProvider provider: CloudflarePresentationContextProvider) {
        session.presentationContextProvider = provider
        session.prefersEphemeralWebBrowserSession = false
    }

    @MainActor
    func start() -> Bool {
        session.start()
    }

    @MainActor
    func cancel() {
        session.cancel()
    }
}

private typealias CloudflareOAuthCompletionTaskRegistry = AsyncCallbackTaskRegistry

@MainActor
private final class CloudflarePresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
        }
        return scenes.first?.windows.first ?? ASPresentationAnchor()
        #elseif os(macOS)
        if let keyWindow = NSApplication.shared.keyWindow {
            return keyWindow
        }
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
