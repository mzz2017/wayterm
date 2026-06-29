#if os(iOS)
import CoreGraphics
import Foundation

nonisolated struct TerminalNativeTextSearchOptions: Sendable {
    nonisolated enum WordMatchMethod: Sendable {
        case contains
        case startsWith
        case fullWord
    }

    let compareOptions: NSString.CompareOptions
    let wordMatchMethod: WordMatchMethod

    init(
        compareOptions: NSString.CompareOptions = [],
        wordMatchMethod: WordMatchMethod = .contains
    ) {
        self.compareOptions = compareOptions
        self.wordMatchMethod = wordMatchMethod
    }
}

nonisolated struct TerminalNativeSelectionRectFrame: Equatable, Sendable {
    let rect: CGRect
    let containsStart: Bool
    let containsEnd: Bool
}

nonisolated struct TerminalNativeTextSnapshot: Sendable {
    nonisolated struct Line: Sendable {
        let text: String
        let startOffset: Int
        let utf16Length: Int
    }

    static let empty = TerminalNativeTextSnapshot(lines: [], cellSize: CGSize(width: 1, height: 1), columns: 1)

    let lines: [Line]
    let text: String
    let cellSize: CGSize
    let columns: Int

    init(lines rawLines: [String], cellSize: CGSize, columns: Int) {
        let sanitizedCellSize = CGSize(width: max(cellSize.width, 1), height: max(cellSize.height, 1))
        self.cellSize = sanitizedCellSize
        self.columns = max(columns, 1)

        var runningOffset = 0
        var builtLines: [Line] = []
        for (index, line) in rawLines.enumerated() {
            let utf16Length = (line as NSString).length
            builtLines.append(Line(text: line, startOffset: runningOffset, utf16Length: utf16Length))
            runningOffset += utf16Length
            if index < rawLines.count - 1 {
                runningOffset += 1
            }
        }

        self.lines = builtLines
        self.text = rawLines.joined(separator: "\n")
    }

    var length: Int {
        nsText.length
    }

    private var nsText: NSString {
        text as NSString
    }

    func clampedOffset(_ offset: Int) -> Int {
        min(max(offset, 0), length)
    }

    func clampedRange(_ range: NSRange) -> NSRange {
        let location = clampedOffset(range.location)
        let upperBound = clampedOffset(range.location + range.length)
        return NSRange(location: location, length: max(upperBound - location, 0))
    }

    func text(in range: NSRange) -> String? {
        guard length > 0 else { return nil }
        let clamped = clampedRange(range)
        guard clamped.length > 0 else { return "" }
        return nsText.substring(with: clamped)
    }

    func offset(for point: CGPoint) -> Int {
        guard !lines.isEmpty else { return 0 }
        let row = min(max(Int(floor(point.y / cellSize.height)), 0), lines.count - 1)
        let column = min(max(Int(floor(point.x / cellSize.width)), 0), columns)
        let line = lines[row]
        return clampedOffset(line.startOffset + min(column, line.utf16Length))
    }

    func characterRange(at point: CGPoint) -> NSRange? {
        guard length > 0, !lines.isEmpty else { return nil }
        let offset = offset(for: point)
        let (lineIndex, column) = lineAndColumn(for: offset)
        let line = lines[lineIndex]
        guard line.utf16Length > 0 else { return nil }
        let clampedColumn = min(column, max(line.utf16Length - 1, 0))
        return NSRange(location: line.startOffset + clampedColumn, length: 1)
    }

    func caretRect(for offset: Int) -> CGRect {
        let (lineIndex, column) = lineAndColumn(for: offset)
        let caretWidth = max(2, cellSize.width * 0.08)
        return CGRect(
            x: CGFloat(min(column, columns)) * cellSize.width,
            y: CGFloat(lineIndex) * cellSize.height,
            width: caretWidth,
            height: cellSize.height
        ).integral
    }

    func firstRect(for range: NSRange) -> CGRect {
        let frames = selectionRectFrames(for: range)
        if let firstRect = frames.first?.rect {
            return firstRect
        }
        return caretRect(for: range.location)
    }

    func selectionRectFrames(for range: NSRange) -> [TerminalNativeSelectionRectFrame] {
        let clamped = clampedRange(range)
        guard clamped.length > 0, !lines.isEmpty else { return [] }

        let lowerBound = clamped.location
        let upperBound = clamped.location + clamped.length
        var frames: [TerminalNativeSelectionRectFrame] = []

        for (lineIndex, line) in lines.enumerated() {
            let lineStart = line.startOffset
            let lineEnd = line.startOffset + line.utf16Length
            let selectionStart = max(lowerBound, lineStart)
            let selectionEnd = min(upperBound, lineEnd)
            guard selectionEnd > selectionStart else { continue }

            let startColumn = min(selectionStart - lineStart, columns)
            let endColumn = min(selectionEnd - lineStart, columns)
            let width = max(CGFloat(endColumn - startColumn) * cellSize.width, cellSize.width)
            let rect = CGRect(
                x: CGFloat(startColumn) * cellSize.width,
                y: CGFloat(lineIndex) * cellSize.height,
                width: width,
                height: cellSize.height
            ).integral
            frames.append(
                TerminalNativeSelectionRectFrame(
                    rect: rect,
                    containsStart: selectionStart == lowerBound,
                    containsEnd: selectionEnd == upperBound
                )
            )
        }

        return frames
    }

    func searchRanges(query: String, options: TerminalNativeTextSearchOptions = .init()) -> [NSRange] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, length > 0 else { return [] }

        let queryLength = (normalizedQuery as NSString).length
        guard queryLength > 0 else { return [] }

        var results: [NSRange] = []
        var searchRange = NSRange(location: 0, length: length)

        while searchRange.length > 0 {
            let foundRange = nsText.range(of: normalizedQuery, options: options.compareOptions, range: searchRange)
            guard foundRange.location != NSNotFound else { break }

            if matchesWordMethod(foundRange, method: options.wordMatchMethod) {
                results.append(foundRange)
            }

            let nextLocation = foundRange.location + max(foundRange.length, 1)
            guard nextLocation < length else { break }
            searchRange = NSRange(location: nextLocation, length: length - nextLocation)
        }

        return results
    }

    func lineAndColumn(for offset: Int) -> (line: Int, column: Int) {
        guard !lines.isEmpty else { return (0, 0) }

        let clamped = clampedOffset(offset)
        for (index, line) in lines.enumerated() {
            let lineStart = line.startOffset
            let lineEnd = line.startOffset + line.utf16Length

            if clamped < lineEnd {
                return (index, clamped - lineStart)
            }

            if clamped == lineEnd {
                return (index, line.utf16Length)
            }
        }

        let lastLine = lines[lines.count - 1]
        return (lines.count - 1, lastLine.utf16Length)
    }

    private func matchesWordMethod(_ range: NSRange, method: TerminalNativeTextSearchOptions.WordMatchMethod) -> Bool {
        switch method {
        case .contains:
            return true
        case .startsWith:
            return isWordBoundaryBeforeUTF16Offset(range.location)
        case .fullWord:
            return isWordBoundaryBeforeUTF16Offset(range.location)
                && isWordBoundaryAfterUTF16Offset(range.location + range.length)
        }
    }

    private func isWordBoundaryBeforeUTF16Offset(_ offset: Int) -> Bool {
        guard offset > 0, offset <= length else { return true }
        let previousCodeUnit = nsText.character(at: offset - 1)
        guard let scalar = UnicodeScalar(previousCodeUnit) else { return true }
        return !Self.wordScalars.contains(scalar)
    }

    private func isWordBoundaryAfterUTF16Offset(_ offset: Int) -> Bool {
        guard offset >= 0, offset < length else { return true }
        let nextCodeUnit = nsText.character(at: offset)
        guard let scalar = UnicodeScalar(nextCodeUnit) else { return true }
        return !Self.wordScalars.contains(scalar)
    }

    private static let wordScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
}
#endif
