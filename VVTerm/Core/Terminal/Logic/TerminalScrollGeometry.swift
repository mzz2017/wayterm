struct TerminalScrollGeometry: Equatable {
    let totalRows: Int
    let visibleRows: Int
    let cellHeight: Double

    var maxScrollableRow: Int {
        max(sanitizedTotalRows - sanitizedVisibleRows, 0)
    }

    func contentHeight(viewportHeight: Double) -> Double {
        let viewportHeight = max(viewportHeight, 0)
        guard sanitizedCellHeight > 0, sanitizedTotalRows > 0 else {
            return viewportHeight
        }

        let gridHeight = Double(sanitizedTotalRows) * sanitizedCellHeight
        let visibleGridHeight = Double(sanitizedVisibleRows) * sanitizedCellHeight
        let bottomPadding = max(viewportHeight - visibleGridHeight, 0)
        return max(viewportHeight, gridHeight + bottomPadding)
    }

    func row(forContentOffsetY offsetY: Double) -> Int {
        guard sanitizedCellHeight > 0 else { return 0 }
        let unclampedRow = Int(max(offsetY, 0) / sanitizedCellHeight)
        return clampedRow(unclampedRow)
    }

    func contentOffsetY(forRow row: Int) -> Double {
        Double(clampedRow(row)) * sanitizedCellHeight
    }

    private var sanitizedTotalRows: Int {
        max(totalRows, 0)
    }

    private var sanitizedVisibleRows: Int {
        max(visibleRows, 0)
    }

    private var sanitizedCellHeight: Double {
        cellHeight > 0 ? cellHeight : 0
    }

    private func clampedRow(_ row: Int) -> Int {
        min(max(row, 0), maxScrollableRow)
    }
}

enum TerminalScrollOwner: Equatable {
    case hostScrollback
    case remoteMouseApplication
    case selection
    case pinchZoom
}

struct TerminalScrollContext: Equatable {
    var remoteScrollOwnerActive: Bool
    var hasHostScrollableRows: Bool
    var isSelecting: Bool
    var isPinching: Bool
}

enum TerminalScrollRoutingPolicy {
    static func owner(for context: TerminalScrollContext) -> TerminalScrollOwner {
        if context.isSelecting { return .selection }
        if context.isPinching { return .pinchZoom }
        if context.remoteScrollOwnerActive { return .remoteMouseApplication }
        if !context.hasHostScrollableRows { return .remoteMouseApplication }
        return .hostScrollback
    }
}
