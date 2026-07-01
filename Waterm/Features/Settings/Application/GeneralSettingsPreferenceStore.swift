import Combine
import Foundation

struct GeneralSettingsPreferenceSnapshot: Equatable {
    var appearanceMode: String
    var appLanguage: String
    var isPrivacyModeEnabled: Bool
    var isAnalyticsEnabled: Bool
}

@MainActor
protocol GeneralSettingsPersisting: AnyObject {
    func loadGeneralSettings() -> GeneralSettingsPreferenceSnapshot
    func setAppearanceMode(_ value: String)
    func setAppLanguage(_ value: String)
    func setPrivacyModeEnabled(_ value: Bool)
    func setAnalyticsEnabled(_ value: Bool)
}

@MainActor
final class GeneralSettingsPreferenceStore: ObservableObject {
    typealias LanguageApplyAction = @MainActor (String) -> Void

    @Published var appearanceMode: String {
        didSet { persistence.setAppearanceMode(appearanceMode) }
    }

    @Published var appLanguage: String {
        didSet {
            persistence.setAppLanguage(appLanguage)
            applyLanguageSelection(appLanguage)
        }
    }

    @Published var isPrivacyModeEnabled: Bool {
        didSet { persistence.setPrivacyModeEnabled(isPrivacyModeEnabled) }
    }

    @Published var isAnalyticsEnabled: Bool {
        didSet { persistence.setAnalyticsEnabled(isAnalyticsEnabled) }
    }

    private let persistence: any GeneralSettingsPersisting
    private let applyLanguageSelection: LanguageApplyAction

    init(
        persistence: any GeneralSettingsPersisting,
        applyLanguageSelection: @escaping LanguageApplyAction
    ) {
        self.persistence = persistence
        self.applyLanguageSelection = applyLanguageSelection
        let snapshot = persistence.loadGeneralSettings()
        appearanceMode = snapshot.appearanceMode
        appLanguage = snapshot.appLanguage
        isPrivacyModeEnabled = snapshot.isPrivacyModeEnabled
        isAnalyticsEnabled = snapshot.isAnalyticsEnabled
    }
}
