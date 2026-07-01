import Foundation

nonisolated enum TerminalFontPickerPolicy {
    /// Ensures the current primary font appears in the picker list.
    /// If the stored font name is missing from the system font list
    /// (e.g., a previously-installed font was removed), it is prepended
    /// so the Picker can display the current selection without breaking.
    static func fontListEnsuringCurrentFont(systemFonts: [String], currentFontName: String) -> [String] {
        let trimmed = currentFontName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return systemFonts }
        guard !systemFonts.contains(trimmed) else { return systemFonts }
        return [trimmed] + systemFonts
    }
}
