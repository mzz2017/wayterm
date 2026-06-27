import Combine
import Foundation

struct TerminalRuntimePreferenceSnapshot: Equatable {
    var terminalThemeName: String
    var terminalThemeNameLight: String
    var usePerAppearanceTheme: Bool
    var autoReconnectEnabled: Bool
    var terminalVoiceButtonEnabled: Bool
}

@MainActor
protocol TerminalRuntimePreferencesPersisting: AnyObject {
    var changeNotificationObject: Any? { get }
    func loadTerminalRuntimePreferences() -> TerminalRuntimePreferenceSnapshot
}

@MainActor
final class TerminalRuntimePreferencesStore: ObservableObject {
    @Published private(set) var terminalThemeName: String
    @Published private(set) var terminalThemeNameLight: String
    @Published private(set) var usePerAppearanceTheme: Bool
    @Published private(set) var autoReconnectEnabled: Bool
    @Published private(set) var terminalVoiceButtonEnabled: Bool

    private let persistence: any TerminalRuntimePreferencesPersisting
    private let notificationCenter: NotificationCenter
    private var changeObserver: NSObjectProtocol?

    init(
        persistence: any TerminalRuntimePreferencesPersisting,
        notificationCenter: NotificationCenter = .default
    ) {
        self.persistence = persistence
        self.notificationCenter = notificationCenter

        let snapshot = persistence.loadTerminalRuntimePreferences()
        terminalThemeName = snapshot.terminalThemeName
        terminalThemeNameLight = snapshot.terminalThemeNameLight
        usePerAppearanceTheme = snapshot.usePerAppearanceTheme
        autoReconnectEnabled = snapshot.autoReconnectEnabled
        terminalVoiceButtonEnabled = snapshot.terminalVoiceButtonEnabled

        changeObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: persistence.changeNotificationObject,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFromPersistence()
            }
        }
    }

    deinit {
        if let changeObserver {
            notificationCenter.removeObserver(changeObserver)
        }
    }

    func refreshFromPersistence() {
        apply(persistence.loadTerminalRuntimePreferences())
    }

    private func apply(_ snapshot: TerminalRuntimePreferenceSnapshot) {
        terminalThemeName = snapshot.terminalThemeName
        terminalThemeNameLight = snapshot.terminalThemeNameLight
        usePerAppearanceTheme = snapshot.usePerAppearanceTheme
        autoReconnectEnabled = snapshot.autoReconnectEnabled
        terminalVoiceButtonEnabled = snapshot.terminalVoiceButtonEnabled
    }
}
