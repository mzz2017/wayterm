//
//  VVTermApp.swift
//  VVTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct VVTermApp: App {
    init() {
        TerminalDefaults.applyIfNeeded()
        ServerManager.shared.configureDeletionTeardown(Self.disconnectServerBeforeDeletion)
    }

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    #if os(iOS)
    @StateObject private var ghosttyApp = Ghostty.App(autoStart: false)
    #else
    @StateObject private var ghosttyApp = Ghostty.App()
    #endif
    @StateObject private var appLockManager = AppLockManager.shared
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var remoteFileTabManager = RemoteFileTabManager(
        isProProvider: { StoreManager.shared.isPro }
    )
    @StateObject private var remoteFileBrowserStore = VVTermApp.makeRemoteFileBrowserStore()
    @StateObject private var terminalThemeManager = TerminalThemeManager.shared
    @StateObject private var terminalAccessoryPreferencesManager = TerminalAccessoryPreferencesManager.shared
    private let serverConnectionLifecycleCoordinator = ServerConnectionLifecycleCoordinator.shared

    // Welcome screen flag
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    // App language
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false

    // Terminal settings to watch for changes
    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = TerminalDefaults.defaultFontName
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.cursorStyleKey) private var terminalCursorStyle = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var terminalCursorBlink = TerminalDefaults.defaultCursorBlink
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    private var activeCustomThemeVersionToken: String {
        let activeThemes = terminalThemeManager.customThemes.filter { !$0.isDeleted }
        let byName = Dictionary(
            activeThemes.map { ($0.name, $0) },
            uniquingKeysWith: { current, candidate in
                current.updatedAt >= candidate.updatedAt ? current : candidate
            }
        )

        let darkVersion = byName[terminalThemeName]?.updatedAt.timeIntervalSince1970 ?? 0
        let lightVersion = byName[terminalThemeNameLight]?.updatedAt.timeIntervalSince1970 ?? 0

        if usePerAppearanceTheme {
            return "\(darkVersion):\(lightVersion)"
        }

        return "\(darkVersion)"
    }

    var body: some Scene {
        WindowGroup("", id: "main") {
            let appLocale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
            AppLockContainer {
                NoticeAppHost {
                    Group {
                        #if os(iOS)
                        iOSContentView(
                            fileTabs: remoteFileTabManager,
                            fileBrowser: remoteFileBrowserStore,
                            appLockManager: appLockManager,
                            disconnectCoordinator: serverConnectionLifecycleCoordinator
                        )
                            .environmentObject(ghosttyApp)
                            .environmentObject(terminalThemeManager)
                            .environmentObject(terminalAccessoryPreferencesManager)
                            .modifier(AppearanceModifier())
                            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)\(activeCustomThemeVersionToken)") {
                                ghosttyApp.reloadConfig()
                            }
                            .sheet(isPresented: .init(
                                get: { !hasSeenWelcome },
                                set: { if !$0 { hasSeenWelcome = true } }
                            )) {
                                WelcomeView(hasSeenWelcome: $hasSeenWelcome)
                            }
                        #else
                        ContentView(
                            fileTabs: remoteFileTabManager,
                            fileBrowser: remoteFileBrowserStore,
                            appLockManager: appLockManager,
                            disconnectCoordinator: serverConnectionLifecycleCoordinator,
                            onShowSettings: {
                                SettingsWindowManager.shared.show()
                            }
                        )
                            .environmentObject(ghosttyApp)
                            .environmentObject(terminalThemeManager)
                            .environmentObject(terminalAccessoryPreferencesManager)
                            .modifier(AppearanceModifier())
                            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)\(activeCustomThemeVersionToken)") {
                                ghosttyApp.reloadConfig()
                            }
                            .sheet(isPresented: .init(
                                get: { !hasSeenWelcome },
                                set: { if !$0 { hasSeenWelcome = true } }
                            )) {
                                WelcomeView(hasSeenWelcome: $hasSeenWelcome)
                            }
                        #endif
                    }
                    .environment(\.locale, appLocale)
                    .environment(\.privacyModeEnabled, privacyModeEnabled)
                    .onAppear {
                        AppLanguage.applySelection(appLanguage)
                        AppLifecycleCoordinator.shared.handleAppLanguageChange(appLanguage)
                    }
                    .onChange(of: appLanguage) { newValue in
                        AppLanguage.applySelection(newValue)
                        AppLifecycleCoordinator.shared.handleAppLanguageChange(newValue)
                    }
                }
            }
            .environmentObject(appLockManager)
            .environmentObject(storeManager)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            VVTermCommands()
        }
        #endif
    }
}

private extension VVTermApp {
    @MainActor
    static func disconnectServerBeforeDeletion(_ server: Server) async {
        await ConnectionSessionManager.shared.disconnectServerAndWait(server.id)
        await TerminalTabManager.shared.disconnectServerAndWait(server.id)
    }

    static func makeRemoteFileBrowserStore() -> RemoteFileBrowserStore {
        let adapter = SSHSFTPAdapter(
            remoteConnectionLeaseProvider: RemoteConnectionLeaseProvider { serverId in
                ConnectionSessionManager.shared.sharedStatsLease(for: serverId)
                    ?? TerminalTabManager.shared.sharedStatsLease(for: serverId)
            },
            credentialsProvider: { server in
                try KeychainManager.shared.getCredentials(for: server)
            }
        )

        return RemoteFileBrowserStore(
            remoteFileServiceAdapter: adapter,
            serverProvider: { serverId in
                ServerManager.shared.servers.first { $0.id == serverId }
            },
            workingDirectoryProvider: { serverId in
                if let selectedSessionId = ConnectionSessionManager.shared.selectedSessionByServer[serverId],
                   let path = ConnectionSessionManager.shared.workingDirectory(for: selectedSessionId) {
                    return path
                }

                if let anySession = ConnectionSessionManager.shared.sessions.first(where: { $0.serverId == serverId }),
                   let path = ConnectionSessionManager.shared.workingDirectory(for: anySession.id) {
                    return path
                }

                if let selectedTab = TerminalTabManager.shared.selectedTab(for: serverId),
                   let path = TerminalTabManager.shared.workingDirectory(for: selectedTab.focusedPaneId) {
                    return path
                }

                if let anyPane = TerminalTabManager.shared.paneStates.values.first(where: { $0.serverId == serverId }),
                   let path = TerminalTabManager.shared.workingDirectory(for: anyPane.paneId) {
                    return path
                }

                return nil
            }
        )
    }
}

// MARK: - macOS App Delegate

#if os(macOS)
struct VVTermCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.serverViewTabActions) private var serverViewTabActions
    @FocusedValue(\.openLocalSSHDiscovery) private var openLocalSSHDiscovery
    @FocusedValue(\.terminalSplitActions) private var terminalSplitActions

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About VVTerm") {
                AboutWindowPresenter.shared.show {
                    AboutView()
                }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("New Tab") {
                serverViewTabActions?.openNew()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(serverViewTabActions == nil)

            Button(String(localized: "Discover Local Devices...")) {
                openLocalSSHDiscovery?()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(openLocalSSHDiscovery == nil)

            Button("Close Tab") {
                serverViewTabActions?.closeSelected()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(serverViewTabActions == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                SettingsWindowManager.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Previous Tab") {
                serverViewTabActions?.selectPrevious()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(serverViewTabActions == nil)

            Button("Next Tab") {
                serverViewTabActions?.selectNext()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(serverViewTabActions == nil)
        }

        // Split commands (Pro feature)
        SplitCommands()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLifecycleCoordinator.shared.requestLaunch()
        NSApplication.shared.registerForRemoteNotifications()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppLifecycleCoordinator.shared.requestForegroundRefresh()
    }

    func applicationDidResignActive(_ notification: Notification) {
        AppLifecycleCoordinator.shared.requestBackgroundLock()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycleCoordinator.shared.requestTerminationTeardown {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running in menu bar
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        AppLifecycleCoordinator.shared.requestRemoteNotificationRefresh()
    }
}
#else
// MARK: - iOS App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLifecycleCoordinator.shared.requestLaunch()
        application.registerForRemoteNotifications()

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AppLifecycleCoordinator.shared.requestForegroundRefresh()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        AppLifecycleCoordinator.shared.requestRemoteNotificationRefresh { didRefresh in
            completionHandler(didRefresh ? .newData : .noData)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppLifecycleCoordinator.shared.requestTerminationTeardown()
    }

    // Handle app going to background - suspend connections to save resources
    func applicationDidEnterBackground(_ application: UIApplication) {
        AppLifecycleCoordinator.shared.requestBackgroundSuspension()
    }
}
#endif
