import SwiftUI

enum PrivacyModeSettings {
    static let enabledKey = "security.privacyModeEnabled"
}

enum SensitiveContentMask {
    static let placeholder = "••••••••"

    static func value(_ value: String, privacyModeEnabled: Bool) -> String {
        privacyModeEnabled ? placeholder : value
    }
}

private struct PrivacyModeEnabledEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var privacyModeEnabled: Bool {
        get { self[PrivacyModeEnabledEnvironmentKey.self] }
        set { self[PrivacyModeEnabledEnvironmentKey.self] = newValue }
    }
}

extension DiscoveredSSHHost {
    var displayEndpoint: String {
        "\(host):\(port)"
    }

    func visibleDisplayName(privacyModeEnabled _: Bool) -> String {
        return displayName
    }

    func visibleEndpoint(privacyModeEnabled _: Bool) -> String {
        displayEndpoint
    }
}
