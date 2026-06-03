struct TerminalGridPoint: Comparable, Equatable {
    var row: Int
    var column: Int

    static func < (lhs: TerminalGridPoint, rhs: TerminalGridPoint) -> Bool {
        if lhs.row == rhs.row {
            return lhs.column < rhs.column
        }
        return lhs.row < rhs.row
    }
}

struct TerminalGridSelection: Equatable {
    var start: TerminalGridPoint
    var end: TerminalGridPoint

    var orderedStart: TerminalGridPoint {
        min(start, end)
    }

    var orderedEnd: TerminalGridPoint {
        max(start, end)
    }

    var normalized: TerminalGridSelection {
        .init(start: orderedStart, end: orderedEnd)
    }
}
