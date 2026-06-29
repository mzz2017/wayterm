#if os(iOS)
import Foundation

nonisolated enum TerminalViewportTextSanitizer {
    static func sanitizedLine(_ rawLine: String, columns: Int) -> String {
        guard columns > 0 else { return "" }

        var line = rawLine
        while let scalar = line.unicodeScalars.last,
              CharacterSet.newlines.contains(scalar) {
            line.removeLast()
        }

        while let scalar = line.unicodeScalars.last,
              CharacterSet.whitespaces.contains(scalar) {
            line.removeLast()
        }

        let lineNSString = line as NSString
        if lineNSString.length > columns {
            return lineNSString.substring(to: columns)
        }

        return line
    }
}
#endif
