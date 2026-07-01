import Foundation
import Testing

// Test Context:
// These tests protect app-lock authentication ownership. SwiftUI may react to
// scene changes, toggle settings, select protected servers, open active
// connections, and handle button taps, but biometric authentication tasks must
// be owned by AppLockManager so request ordering can be observed and later
// lifecycle work can wait for completion. The tests inspect source placement
// only; update this context only when app-lock authentication intent
// intentionally moves to another application-layer owner.
@Suite
struct AppLockIntentBoundaryTests {
    @Test
    func appLockGateSendsUnlockIntentWithoutOwningTask() throws {
        // Given the app-lock gate SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/Security/UI/AppLockGateView.swift")
        )

        // Then the gate and container should synchronously send unlock intent
        // instead of owning biometric authentication tasks.
        #expect(
            !source.contains("Task {"),
            "AppLockGateView should not own app-lock authentication Task state."
        )
        #expect(
            !source.contains("ensureAppUnlocked()"),
            "AppLockGateView should not call the async unlock behavior boundary directly."
        )
        #expect(
            source.contains("requestAppUnlock()"),
            "AppLockGateView should send unlock intent to AppLockManager."
        )
    }

    @Test
    func generalSettingsSendsFullLockIntentWithoutOwningTask() throws {
        // Given the general settings SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/Settings/UI/GeneralSettingsView.swift")
        )

        let fullLockToggleSource = try slice(
            startingAt: "String(format: String(localized: \"Require %@ to open Waterm\")",
            endingBefore: "\n                .disabled(appLockManager.isAuthenticating",
            in: source
        )

        // Then the full-app-lock toggle should send intent instead of launching
        // the async authentication behavior itself.
        #expect(
            !fullLockToggleSource.contains("Task {"),
            "GeneralSettingsView should not own full-app-lock authentication Task state."
        )
        #expect(
            !fullLockToggleSource.contains("requestSetFullAppLockEnabled("),
            "GeneralSettingsView should not call the async full-lock behavior boundary directly."
        )
        #expect(
            fullLockToggleSource.contains("requestFullAppLockChange(newValue)"),
            "GeneralSettingsView should send full-lock change intent to AppLockManager."
        )
    }

    @Test
    func serverSelectionSendsServerUnlockIntentWithoutOwningTask() throws {
        // Given the macOS sidebar SwiftUI source that selects saved servers.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/Servers/UI/Sidebar/ServerSidebarView.swift")
        )
        let selectServerSource = try slice(
            startingAt: "private func selectServer(_ server: Server)",
            endingBefore: "\n    private func connectToServer",
            in: source
        )

        // Then the selection path should send server-unlock intent to the
        // injected application owner instead of directly awaiting biometric auth.
        #expect(
            source.contains("@ObservedObject var appLockManager: AppLockManager"),
            "ServerSidebarView should receive AppLockManager from app composition."
        )
        #expect(
            !selectServerSource.contains("ensureServerUnlocked("),
            "ServerSidebarView should not call the async server-unlock behavior boundary directly."
        )
        #expect(
            selectServerSource.contains("appLockManager.requestServerUnlock"),
            "ServerSidebarView should send server-unlock intent to the injected AppLockManager."
        )
        #expect(
            !source.contains("AppLockManager.shared"),
            "ServerSidebarView should not resolve AppLockManager.shared from Servers UI."
        )
    }

    @Test
    func iosActiveConnectionOpenSendsServerUnlockIntentWithoutDirectAuth() throws {
        // Given the iOS server list SwiftUI source that opens active connections.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/Servers/UI/iOS/iOSServerListView.swift")
        )
        let openActiveConnectionSource = try slice(
            startingAt: "private func openActiveConnection(_ connection: ActiveConnection)",
            endingBefore: "\n    private func disconnectActiveConnection",
            in: source
        )

        // Then opening an active connection should not directly own the server
        // biometric-auth await; it should send unlock intent first.
        #expect(
            source.contains("@ObservedObject var appLockManager: AppLockManager"),
            "iOSServerListView should receive AppLockManager from iOS app composition."
        )
        #expect(
            !openActiveConnectionSource.contains("ensureServerUnlocked("),
            "iOSServerListView should not call the async server-unlock behavior boundary directly."
        )
        #expect(
            openActiveConnectionSource.contains("appLockManager.requestServerUnlock"),
            "iOSServerListView should send server-unlock intent to the injected AppLockManager."
        )
        #expect(
            !source.contains("AppLockManager.shared"),
            "iOSServerListView should not resolve AppLockManager.shared from Servers UI."
        )
    }

    @Test
    func appRootsInjectAppLockManagerIntoServerUI() throws {
        let root = try sourceRoot()
        let appSource = try source(at: root.appendingPathComponent("Waterm/App/WatermApp.swift"))
        let macRootSource = try source(at: root.appendingPathComponent("Waterm/App/ContentView.swift"))
        let iosRootSource = try source(at: root.appendingPathComponent("Waterm/App/iOS/iOSContentView.swift"))

        // Given AppLockManager owns tracked biometric-auth request lifecycle.
        #expect(
            appSource.contains("@StateObject private var appLockManager = AppLockManager.shared"),
            "WatermApp should be the composition boundary that owns the shared AppLockManager."
        )
        #expect(
            macRootSource.contains("appLockManager: appLockManager"),
            "ContentView should pass the app-owned AppLockManager into macOS server UI."
        )
        #expect(
            iosRootSource.contains("appLockManager: appLockManager"),
            "iOSContentView should pass the app-owned AppLockManager into iOS server UI."
        )
    }

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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

    private enum SourceSliceError: Error {
        case notFound
    }
}
