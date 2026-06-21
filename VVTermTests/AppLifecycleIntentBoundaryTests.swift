import Foundation
import Testing

// Test Context:
// These tests protect App root and platform delegate lifecycle boundaries.
// `VVTermApp.swift` may receive platform callbacks and SwiftUI lifecycle
// events, but lifecycle-critical terminal teardown, background suspension,
// sync refresh, app-lock, and language-change orchestration must be delegated
// to an App/Application owner. The tests inspect source placement only; update
// this context only when app lifecycle intent intentionally moves to a
// different application-layer coordinator.
@Suite
struct AppLifecycleIntentBoundaryTests {
    @Test
    func vvtermAppDelegatesLifecycleWorkToAppLifecycleCoordinator() throws {
        // Given the root app and platform delegate source.
        let root = try sourceRoot()
        let source = try source(at: root.appendingPathComponent("VVTerm/App/VVTermApp.swift"))

        // Then VVTermApp should not own the termination semaphore bridge or
        // directly orchestrate app lifecycle singleton work.
        #expect(
            !source.contains("awaitTerminalManagersTeardownBeforeExit"),
            "VVTermApp.swift should delegate termination teardown bridging to AppLifecycleCoordinator."
        )
        #expect(
            !source.contains("ConnectionSessionManager.shared.disconnectAllAndWait"),
            "VVTermApp.swift should not directly tear down connection sessions on termination."
        )
        #expect(
            !source.contains("TerminalTabManager.shared.disconnectAllAndWait"),
            "VVTermApp.swift should not directly tear down terminal tabs on termination."
        )
        #expect(
            !source.contains("ConnectionSessionManager.shared.suspendAllForBackground"),
            "VVTermApp.swift should not directly own background terminal suspension."
        )
        #expect(
            !source.contains("AppLockManager.shared.lockIfNeededForBackground"),
            "VVTermApp.swift should delegate background lock orchestration."
        )
        #expect(
            !source.contains("AppSyncCoordinator.shared"),
            "VVTermApp.swift should send app-sync lifecycle intent through AppLifecycleCoordinator."
        )
        #expect(
            !source.contains("ServerManager.shared.handleAppLanguageChange"),
            "VVTermApp.swift should delegate app-language side effects to AppLifecycleCoordinator."
        )
        #expect(
            source.contains("AppLifecycleCoordinator.shared"),
            "VVTermApp.swift should use AppLifecycleCoordinator as the app lifecycle intent boundary."
        )
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

    private enum SourceRootError: Error {
        case notFound
    }
}
