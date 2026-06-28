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

actor CloudflareWebAuthenticationSessionActor: OAuthWebSession {
    private let completionTasks = CloudflareOAuthCompletionTaskRegistry()
    private var currentSession: ASWebAuthenticationSession?
    private var currentSessionID: UUID?
    private var ignoredCompletionSessionIDs: Set<UUID> = []
    private var userDidCancel = false
    private var presentationContextProvider: CloudflarePresentationContextProvider?

    func start(url: URL) async throws {
        if currentSession != nil {
            await resetForRestart()
        }

        userDidCancel = false

        let provider = await ensurePresentationContextProvider()
        let sessionID = UUID()
        let completionTasks = completionTasks
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [self] _, error in
            completionTasks.track {
                await self.handleCompletion(sessionID: sessionID, error: error)
            }
        }

        await MainActor.run {
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
        }

        currentSession = session
        currentSessionID = sessionID
        let didStart = await MainActor.run { session.start() }
        if !didStart {
            currentSession = nil
            currentSessionID = nil
            throw Failure.auth("Failed to start Cloudflare login session")
        }
    }

    func stop() async {
        guard let session = currentSession else { return }
        if let currentSessionID {
            ignoredCompletionSessionIDs.insert(currentSessionID)
        }
        await MainActor.run {
            session.cancel()
        }
        currentSession = nil
        currentSessionID = nil
        await waitForCompletionTasks()
    }

    func didCancelLogin() async -> Bool {
        userDidCancel
    }

    private func resetForRestart() async {
        if let currentSessionID {
            ignoredCompletionSessionIDs.insert(currentSessionID)
        }
        if let session = currentSession {
            await MainActor.run {
                session.cancel()
            }
        }
        currentSession = nil
        currentSessionID = nil
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
        defer {
            if currentSessionID == sessionID {
                currentSession = nil
                currentSessionID = nil
            }
        }

        if ignoredCompletionSessionIDs.remove(sessionID) != nil {
            return
        }

        guard currentSessionID == sessionID else {
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

private final class CloudflareOAuthCompletionTaskRegistry: @unchecked Sendable {
    private final class Record {
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    @discardableResult
    func track(_ operation: @escaping @Sendable () async -> Void) -> UUID {
        let requestID = UUID()
        let record = Record()

        lock.lock()
        records[requestID] = record
        let task = Task {
            await operation()
            self.remove(requestID)
        }
        record.task = task
        lock.unlock()

        return requestID
    }

    func tasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.compactMap(\.task)
    }

    private func remove(_ requestID: UUID) {
        lock.lock()
        records.removeValue(forKey: requestID)
        lock.unlock()
    }
}

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
