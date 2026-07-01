import SwiftUI
import Foundation

nonisolated struct TerminalThemeBackgroundResolution {
    let color: Color
    let storageHex: String
    let usedFallback: Bool
}

nonisolated enum TerminalThemeBackgroundResolver {
    static let cacheKey = "terminalBackgroundColor"

    nonisolated static func resolve(
        themeName: String,
        fallbackHex: String
    ) -> TerminalThemeBackgroundResolution {
        let themeHex = ThemeColorParser.backgroundColorHex(for: themeName)
        let storageHex = themeHex ?? normalizedStorageHex(fallbackHex)
        return TerminalThemeBackgroundResolution(
            color: Color.fromHex(storageHex),
            storageHex: storageHex,
            usedFallback: themeHex == nil
        )
    }

    nonisolated static func initialBackground(
        defaults: UserDefaults = .standard,
        themeName: String,
        fallbackHex: String
    ) -> TerminalThemeBackgroundResolution {
        if let cached = cachedBackground(defaults: defaults) {
            return cached
        }

        return resolve(themeName: themeName, fallbackHex: fallbackHex)
    }

    nonisolated static func cachedBackground(
        defaults: UserDefaults = .standard
    ) -> TerminalThemeBackgroundResolution? {
        guard let cachedHex = defaults.string(forKey: cacheKey) else { return nil }
        let storageHex = normalizedStorageHex(cachedHex)
        return TerminalThemeBackgroundResolution(
            color: Color.fromHex(storageHex),
            storageHex: storageHex,
            usedFallback: false
        )
    }

    nonisolated static func cacheResolvedBackground(
        _ resolution: TerminalThemeBackgroundResolution,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(resolution.storageHex, forKey: cacheKey)
    }

    nonisolated static func normalizedStorageHex(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return "#\(withoutPrefix.uppercased())"
    }
}
