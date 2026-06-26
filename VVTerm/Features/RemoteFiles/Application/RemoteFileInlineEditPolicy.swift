import Foundation

enum RemoteFileInlineEditPolicy {
    static func uniqueFolderName(
        existingNames: some Sequence<String>,
        baseName: String,
        locale: Locale = .current,
        fallbackSuffix: @autoclosure () -> String = String(UUID().uuidString.prefix(4))
    ) -> String {
        let existingFoldedNames = Set(
            existingNames.map { foldedName($0, locale: locale) }
        )
        let foldedBaseName = foldedName(baseName, locale: locale)

        guard existingFoldedNames.contains(foldedBaseName) else {
            return baseName
        }

        for index in 2...10_000 {
            let candidate = "\(baseName) \(index)"
            if !existingFoldedNames.contains(foldedName(candidate, locale: locale)) {
                return candidate
            }
        }

        return "\(baseName) \(fallbackSuffix())"
    }

    private static func foldedName(_ name: String, locale: Locale) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
}
