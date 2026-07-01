import Foundation

nonisolated enum ServerPortValidator {
    static let validRange = 1...65535

    static func normalizedPort(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), validRange.contains(port) else {
            return nil
        }
        return port
    }
}
