import Foundation

extension CloudKitManager: TerminalThemeCloudStoring {}

extension CloudKitManager {
    private enum TerminalThemeRecordType {
        static let theme = "TerminalTheme"
    }

    func fetchTerminalThemes() async throws -> [TerminalTheme] {
        let records = try await fetchRecords(matchingRecordTypes: [TerminalThemeRecordType.theme])
        return records.compactMap(TerminalTheme.init(from:))
    }

    func fetchTerminalThemePreference() async throws -> TerminalThemePreference? {
        guard let record = try await fetchRecord(named: TerminalThemePreference.recordName) else {
            return nil
        }
        return TerminalThemePreference(from: record)
    }
}
