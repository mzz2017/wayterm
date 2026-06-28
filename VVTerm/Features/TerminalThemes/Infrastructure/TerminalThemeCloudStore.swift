import Foundation

@MainActor
final class TerminalThemeCloudKitStore: TerminalThemeCloudStoring {
    private enum TerminalThemeRecordType {
        static let theme = "TerminalTheme"
    }

    private let cloudKit: CloudKitManager

    init(cloudKit: CloudKitManager) {
        self.cloudKit = cloudKit
    }

    func fetchTerminalThemes() async throws -> [TerminalTheme] {
        let records = try await cloudKit.fetchRecords(matchingRecordTypes: [TerminalThemeRecordType.theme])
        return records.compactMap(TerminalTheme.init(from:))
    }

    func fetchTerminalThemePreference() async throws -> TerminalThemePreference? {
        guard let record = try await cloudKit.fetchRecord(named: TerminalThemePreference.recordName) else {
            return nil
        }
        return TerminalThemePreference(from: record)
    }
}
