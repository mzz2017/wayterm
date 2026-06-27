import Combine
import Foundation

final class SFSymbolsProvider {
    @MainActor
    static let shared = SFSymbolsProvider()

    private(set) var allSymbols: [String] = []
    private(set) var categories: [(key: String, icon: String, name: String)] = []
    private(set) var symbolToCategories: [String: [String]] = [:]

    private let localizedSuffixes = [".ar", ".hi", ".he", ".ja", ".ko", ".th", ".zh", ".rtl"]

    init() {
        loadSymbols()
    }

    private func loadSymbols() {
        guard let bundle = Bundle(path: "/System/Library/CoreServices/CoreGlyphs.bundle") else {
            loadFallbackSymbols()
            return
        }

        if let categoriesPath = bundle.path(forResource: "categories", ofType: "plist"),
           let categoriesData = FileManager.default.contents(atPath: categoriesPath),
           let categoriesList = try? PropertyListSerialization.propertyList(from: categoriesData, format: nil) as? [[String: String]] {
            categories = categoriesList.compactMap { dict in
                guard let key = dict["key"], let icon = dict["icon"] else { return nil }
                return (key: key, icon: icon, name: displayName(for: key))
            }
        }

        if let symbolCategoriesPath = bundle.path(forResource: "symbol_categories", ofType: "plist"),
           let symbolCategoriesData = FileManager.default.contents(atPath: symbolCategoriesPath),
           let symbolCategoriesDict = try? PropertyListSerialization.propertyList(from: symbolCategoriesData, format: nil) as? [String: [String]] {
            symbolToCategories = symbolCategoriesDict

            allSymbols = symbolCategoriesDict.keys
                .filter { symbol in
                    !localizedSuffixes.contains { symbol.hasSuffix($0) }
                }
                .sorted()
        }
    }

    private func loadFallbackSymbols() {
        allSymbols = [
            "brain.head.profile", "cpu", "terminal", "command", "gearshape",
            "bolt", "star", "sparkle", "wand.and.stars", "lightbulb",
            "flame", "cloud", "server.rack", "desktopcomputer", "laptopcomputer",
            "iphone", "atom", "swift", "curlybraces",
            "text.bubble", "message", "envelope", "paperplane", "arrow.up.circle",
            "checkmark.circle", "xmark.circle", "exclamationmark.triangle", "questionmark.circle",
            "person", "person.2", "person.3", "folder", "doc.text"
        ]
        categories = [
            (key: "all", icon: "square.grid.2x2", name: String(localized: "All"))
        ]
    }

    private func displayName(for key: String) -> String {
        switch key {
        case "all": return String(localized: "All")
        case "whatsnew": return String(localized: "What's New")
        case "draw": return String(localized: "Draw")
        case "variable": return String(localized: "Variable")
        case "multicolor": return String(localized: "Multicolor")
        case "communication": return String(localized: "Communication")
        case "weather": return String(localized: "Weather")
        case "maps": return String(localized: "Maps")
        case "objectsandtools": return String(localized: "Objects & Tools")
        case "devices": return String(localized: "Devices")
        case "cameraandphotos": return String(localized: "Camera & Photos")
        case "gaming": return String(localized: "Gaming")
        case "connectivity": return String(localized: "Connectivity")
        case "transportation": return String(localized: "Transportation")
        case "automotive": return String(localized: "Automotive")
        case "accessibility": return String(localized: "Accessibility")
        case "privacyandsecurity": return String(localized: "Privacy & Security")
        case "human": return String(localized: "Human")
        case "home": return String(localized: "Home")
        case "fitness": return String(localized: "Fitness")
        case "nature": return String(localized: "Nature")
        case "editing": return String(localized: "Editing")
        case "textformatting": return String(localized: "Text Formatting")
        case "media": return String(localized: "Media")
        case "keyboard": return String(localized: "Keyboard")
        case "commerce": return String(localized: "Commerce")
        case "time": return String(localized: "Time")
        case "health": return String(localized: "Health")
        case "shapes": return String(localized: "Shapes")
        case "arrows": return String(localized: "Arrows")
        case "indices": return String(localized: "Indices")
        case "math": return String(localized: "Math")
        default: return key.capitalized
        }
    }

    func symbols(for category: String) -> [String] {
        if category == "all" {
            return allSymbols
        }

        return allSymbols.filter { symbol in
            symbolToCategories[symbol]?.contains(category) ?? false
        }
    }

    func search(_ query: String) -> [String] {
        let lowercasedQuery = query.lowercased()
        let queryWords = lowercasedQuery.split(separator: " ").map(String.init)

        return allSymbols.filter { symbol in
            let symbolLower = symbol.lowercased()
            return queryWords.allSatisfy { word in
                symbolLower.contains(word)
            }
        }
    }
}

@MainActor
final class RecentSymbolsManager: ObservableObject {
    @MainActor
    static let shared = RecentSymbolsManager()

    private let defaults: UserDefaults
    private let key = "recentSFSymbols"
    private let maxRecent = 24

    @Published private(set) var recentSymbols: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadRecent()
    }

    private func loadRecent() {
        recentSymbols = defaults.stringArray(forKey: key) ?? []
    }

    func addRecent(_ symbol: String) {
        var recent = recentSymbols
        recent.removeAll { $0 == symbol }
        recent.insert(symbol, at: 0)
        if recent.count > maxRecent {
            recent = Array(recent.prefix(maxRecent))
        }
        recentSymbols = recent
        defaults.set(recent, forKey: key)
    }
}
