#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacOSRemoteFileDragSessionStore {
    static let shared = MacOSRemoteFileDragSessionStore()

    var payload: RemoteFileDragPayload?

    private init() {}
}

struct MacOSRemoteFileTableView: NSViewRepresentable {
    let entries: [RemoteFileEntry]
    let currentPath: String
    let selectedPaths: Set<String>
    let sort: RemoteFileSort
    let sortDirection: RemoteFileSortDirection
    let inlineCreateFolderParentPath: String?
    let inlineRenamePath: String?
    let inlineProposedName: String
    let isInlineSubmitting: Bool
    let onSelectionChange: @MainActor (Set<String>, NSEvent.ModifierFlags) -> Void
    let onActivate: @MainActor (RemoteFileEntry) -> Void
    let onSortChange: @MainActor (RemoteFileSort, RemoteFileSortDirection) -> Void
    let onUploadDroppedURLs: @MainActor ([URL], String) -> Void
    let onDropRemotePayload: @MainActor (RemoteFileDragPayload, String) -> Void
    let menuForEntry: @MainActor (RemoteFileEntry) -> NSMenu
    let menuForBackground: @MainActor () -> NSMenu
    let exportEntry: @MainActor (RemoteFileEntry, URL, @escaping (Error?) -> Void) -> Void
    let fileTypeIdentifier: (RemoteFileEntry) -> String
    let kindLabel: (RemoteFileEntry) -> String
    let onSubmitInlineEdit: @MainActor (String) -> Void
    let onCancelInlineEdit: @MainActor () -> Void
    let serverId: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(scrollView: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum RowKind {
            case inlineCreatePlaceholder
            case entry(index: Int)
        }

        struct TableRenderState: Equatable {
            let entries: [RemoteFileEntry]
            let currentPath: String
            let sort: RemoteFileSort
            let sortDirection: RemoteFileSortDirection
            let inlineCreateFolderParentPath: String?
            let inlineRenamePath: String?
            let inlineProposedName: String
            let isInlineSubmitting: Bool

            init(parent: MacOSRemoteFileTableView) {
                entries = parent.entries
                currentPath = parent.currentPath
                sort = parent.sort
                sortDirection = parent.sortDirection
                inlineCreateFolderParentPath = parent.inlineCreateFolderParentPath
                inlineRenamePath = parent.inlineRenamePath
                inlineProposedName = parent.inlineProposedName
                isInlineSubmitting = parent.isInlineSubmitting
            }
        }

        var parent: MacOSRemoteFileTableView
        private let tableView = RemoteFileBrowserMacNativeTableView()
        private let scrollView = NSScrollView()
        private var isUpdatingSelection = false
        private var promiseDelegates: [UUID: FilePromiseDelegate] = [:]
        private var currentDropRow: Int = -1
        private var currentDropOperation: NSTableView.DropOperation = .on
        private var activeInlineEditorIdentity: String?
        private var lastRenderedState: TableRenderState?

        init(_ parent: MacOSRemoteFileTableView) {
            self.parent = parent
        }

        func makeScrollView() -> NSScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.documentView = tableView

            tableView.headerView = NSTableHeaderView()
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnReordering = false
            tableView.allowsColumnResizing = true
            tableView.allowsTypeSelect = true
            tableView.focusRingType = .none
            tableView.style = .inset
            tableView.rowHeight = 32
            tableView.intercellSpacing = NSSize(width: 8, height: 0)
            tableView.backgroundColor = .clear
            tableView.selectionHighlightStyle = .regular
            tableView.draggingDestinationFeedbackStyle = .regular
            tableView.delegate = self
            tableView.dataSource = self
            tableView.menuProvider = { [weak self] row in
                guard let self else { return nil }
                if let row, let rowKind = self.rowKind(for: row) {
                    switch rowKind {
                    case .inlineCreatePlaceholder:
                        return self.parent.menuForBackground()
                    case .entry(let index):
                        let entry = self.parent.entries[index]
                        self.selectRowIfNeeded(row)
                        return self.parent.menuForEntry(entry)
                    }
                }
                return self.parent.menuForBackground()
            }
            tableView.onSelectAll = { [weak self] in
                guard let self else { return }
                let allPaths = Set(self.parent.entries.map(\.id))
                self.parent.onSelectionChange(allPaths, [])
            }
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleAction(_:))
            let draggedTypes = Array(
                Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
            )
            tableView.registerForDraggedTypes(draggedTypes)
            tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
            tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

            configureColumns()
            applySortDescriptors()

            return scrollView
        }

        func update(scrollView: NSScrollView) {
            let renderState = TableRenderState(parent: parent)
            let shouldReloadData = lastRenderedState != renderState
            lastRenderedState = renderState

            if shouldReloadData {
                tableView.reloadData()
                applySortDescriptors()
            }

            syncSelection()
            if shouldReloadData || inlineEditorIdentity != nil {
                tableView.layoutSubtreeIfNeeded()
            }
            syncInlineEditorFocus()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.entries.count + (inlineCreateRowIndex == nil ? 0 : 1)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rowKind(for: row) {
            case .inlineCreatePlaceholder:
                return 30
            case .entry(let index):
                let entry = parent.entries[index]
                return entry.type == .symlink && entry.symlinkTarget != nil ? 38 : 30
            case .none:
                return 30
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let rowKind = rowKind(for: row) else { return nil }

            switch RemoteFileBrowserMacColumnID(rawValue: tableColumn.identifier.rawValue) {
            case .name:
                let view = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? RemoteFileBrowserMacNameCellView
                    ?? RemoteFileBrowserMacNameCellView()
                view.identifier = tableColumn.identifier
                switch rowKind {
                case .inlineCreatePlaceholder:
                    view.configureInlineEditing(
                        iconName: "folder.fill",
                        iconTintColor: .systemBlue,
                        title: parent.inlineProposedName.isEmpty ? String(localized: "New Folder") : parent.inlineProposedName,
                        subtitle: "",
                        proposedName: parent.inlineProposedName,
                        isSubmitting: parent.isInlineSubmitting,
                        onSubmit: parent.onSubmitInlineEdit,
                        onCancel: parent.onCancelInlineEdit
                    )
                case .entry(let index):
                    let entry = parent.entries[index]
                    if parent.inlineRenamePath == entry.path {
                        view.configureInlineEditing(
                            iconName: entry.iconName,
                            iconTintColor: entry.type == .directory ? .systemBlue : .secondaryLabelColor,
                            title: entry.name,
                            subtitle: entry.type == .symlink ? (entry.symlinkTarget ?? "") : "",
                            proposedName: parent.inlineProposedName,
                            isSubmitting: parent.isInlineSubmitting,
                            onSubmit: parent.onSubmitInlineEdit,
                            onCancel: parent.onCancelInlineEdit
                        )
                    } else {
                        view.configure(entry: entry)
                    }
                }
                return view
            case .modifiedAt:
                guard case .entry(let index) = rowKind else {
                    return makeTextCell(
                        tableView: tableView,
                        identifier: tableColumn.identifier,
                        text: "",
                        alignment: .left
                    )
                }
                let entry = parent.entries[index]
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                    alignment: .left
                )
            case .size:
                guard case .entry(let index) = rowKind else {
                    return makeTextCell(
                        tableView: tableView,
                        identifier: tableColumn.identifier,
                        text: "",
                        alignment: .right
                    )
                }
                let entry = parent.entries[index]
                let sizeText = entry.type == .directory || entry.size == nil
                    ? "—"
                    : ByteCountFormatter.string(fromByteCount: Int64(entry.size ?? 0), countStyle: .file)
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: sizeText,
                    alignment: .right
                )
            case .kind:
                guard case .entry(let index) = rowKind else {
                    return makeTextCell(
                        tableView: tableView,
                        identifier: tableColumn.identifier,
                        text: "",
                        alignment: .left
                    )
                }
                let entry = parent.entries[index]
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: parent.kindLabel(entry),
                    alignment: .left
                )
            case .none:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection else { return }
            let selectedPaths: [String] = tableView.selectedRowIndexes.compactMap { index in
                guard case .entry(let entryIndex) = rowKind(for: index) else { return nil }
                return parent.entries[entryIndex].id
            }
            let selected = Set(selectedPaths)
            parent.onSelectionChange(selected, NSApp.currentEvent?.modifierFlags ?? [])
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = RemoteFileBrowserMacColumnID(rawValue: descriptor.key ?? "") else { return }
            let direction: RemoteFileSortDirection = descriptor.ascending ? .ascending : .descending
            switch column {
            case .name:
                parent.onSortChange(.name, direction)
            case .modifiedAt:
                parent.onSortChange(.modifiedAt, direction)
            case .size:
                parent.onSortChange(.size, direction)
            case .kind:
                return
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard case .entry(let index) = rowKind(for: row) else { return nil }
            let entry = parent.entries[index]
            let delegate = FilePromiseDelegate(
                entry: entry,
                fileTypeIdentifier: parent.fileTypeIdentifier(entry),
                export: parent.exportEntry
            )
            promiseDelegates[delegate.id] = delegate
            return delegate.makeProvider()
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            let draggedEntries = rowIndexes.compactMap { index -> RemoteFileEntry? in
                guard case .entry(let entryIndex) = rowKind(for: index) else { return nil }
                return parent.entries[entryIndex]
            }
            MacOSRemoteFileDragSessionStore.shared.payload = RemoteFileDragPayload(
                serverId: parent.serverId,
                entries: draggedEntries
            )
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            MacOSRemoteFileDragSessionStore.shared.payload = nil
            promiseDelegates.removeAll()
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            retargetDrop(on: tableView, proposedRow: row, dropOperation: dropOperation)
            let destinationPath = destinationPath(
                for: currentDropRow,
                dropOperation: currentDropOperation
            )
            guard destinationPath != nil else { return [] }

            if let source = MacOSRemoteFileDragSessionStore.shared.payload, !source.entries.isEmpty {
                return source.serverId == parent.serverId ? .move : .copy
            }

            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            return fileURLs.isEmpty ? [] : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let destinationPath = destinationPath(
                for: currentDropRow,
                dropOperation: currentDropOperation
            ) else { return false }

            if let payload = MacOSRemoteFileDragSessionStore.shared.payload, !payload.entries.isEmpty {
                parent.onDropRemotePayload(payload, destinationPath)
                return true
            }

            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            guard !fileURLs.isEmpty else { return false }
            parent.onUploadDroppedURLs(fileURLs, destinationPath)
            return true
        }

        @objc
        private func handleDoubleAction(_ sender: Any?) {
            let row = tableView.clickedRow
            guard case .entry(let index) = rowKind(for: row) else { return }
            parent.onActivate(parent.entries[index])
        }

        private func destinationPath(for row: Int, dropOperation: NSTableView.DropOperation) -> String? {
            if row == -1 {
                return parent.currentPath
            }

            if dropOperation == .on, case .entry(let index) = rowKind(for: row) {
                let entry = parent.entries[index]
                return entry.type == .directory ? entry.path : nil
            }

            return parent.currentPath
        }

        private func retargetDrop(
            on tableView: NSTableView,
            proposedRow row: Int,
            dropOperation: NSTableView.DropOperation
        ) {
            guard let rowKind = rowKind(for: row) else {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
                return
            }

            guard case .entry(let index) = rowKind else {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
                return
            }

            let entry = parent.entries[index]
            if entry.type == .directory {
                currentDropRow = row
                currentDropOperation = .on
                tableView.setDropRow(row, dropOperation: .on)
            } else if dropOperation == .above {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
            } else {
                currentDropRow = row
                currentDropOperation = dropOperation
            }
        }

        private func syncSelection() {
            let rowIndexes: IndexSet
            if let inlineCreateRowIndex {
                rowIndexes = IndexSet(integer: inlineCreateRowIndex)
            } else {
                rowIndexes = IndexSet(
                    parent.entries.enumerated().compactMap { index, entry in
                        guard parent.selectedPaths.contains(entry.id) else { return nil }
                        return displayRow(forEntryIndex: index)
                    }
                )
            }
            guard tableView.selectedRowIndexes != rowIndexes else { return }
            isUpdatingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isUpdatingSelection = false
        }

        private func syncInlineEditorFocus() {
            let identity = inlineEditorIdentity
            guard let identity else {
                activeInlineEditorIdentity = nil
                return
            }

            guard let editRow = inlineEditingDisplayRow,
                  let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(RemoteFileBrowserMacColumnID.name.rawValue)) else {
                activeInlineEditorIdentity = identity
                return
            }

            tableView.scrollRowToVisible(editRow)
            tableView.layoutSubtreeIfNeeded()

            let columnIndex = tableView.column(withIdentifier: nameColumn.identifier)
            guard columnIndex >= 0,
                  let cell = tableView.view(atColumn: columnIndex, row: editRow, makeIfNecessary: true) as? RemoteFileBrowserMacNameCellView else {
                activeInlineEditorIdentity = identity
                return
            }

            let shouldRestoreFocus = activeInlineEditorIdentity != identity || !cell.isEditingActive
            activeInlineEditorIdentity = identity

            if shouldRestoreFocus {
                cell.requestEditingFocus()
            }
        }

        private func configureColumns() {
            tableView.tableColumns.forEach(tableView.removeTableColumn)

            tableView.addTableColumn(makeColumn(id: .name, title: String(localized: "Name"), width: 280, minWidth: 140))
            tableView.addTableColumn(makeColumn(id: .modifiedAt, title: String(localized: "Date Modified"), width: 200, minWidth: 120))
            tableView.addTableColumn(makeColumn(id: .size, title: String(localized: "Size"), width: 90, minWidth: 60))
            tableView.addTableColumn(makeColumn(id: .kind, title: String(localized: "Kind"), width: 150, minWidth: 90))
        }

        private func makeColumn(id: RemoteFileBrowserMacColumnID, title: String, width: CGFloat, minWidth: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.resizingMask = .autoresizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: sortAscending(for: id))
            return column
        }

        private func sortAscending(for column: RemoteFileBrowserMacColumnID) -> Bool {
            switch column {
            case .name:
                return parent.sort == .name ? parent.sortDirection == .ascending : true
            case .modifiedAt:
                return parent.sort == .modifiedAt ? parent.sortDirection == .ascending : false
            case .size:
                return parent.sort == .size ? parent.sortDirection == .ascending : false
            case .kind:
                return true
            }
        }

        private func applySortDescriptors() {
            guard let targetColumn = RemoteFileBrowserMacColumnID(sort: parent.sort),
                  let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(targetColumn.rawValue)) else {
                return
            }

            let targetDescriptor = NSSortDescriptor(
                key: targetColumn.rawValue,
                ascending: parent.sortDirection == .ascending
            )
            if tableView.sortDescriptors != [targetDescriptor] {
                tableView.sortDescriptors = [targetDescriptor]
            }
            column.sortDescriptorPrototype = targetDescriptor
        }

        private func makeTextCell(
            tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            text: String,
            alignment: NSTextAlignment
        ) -> NSView {
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? RemoteFileBrowserMacTextCellView ?? RemoteFileBrowserMacTextCellView()
            cell.identifier = identifier
            cell.configure(text: text, alignment: alignment)
            return cell
        }

        private func selectRowIfNeeded(_ row: Int) {
            guard row >= 0 else { return }
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        private var inlineEditorIdentity: String? {
            if let parentPath = parent.inlineCreateFolderParentPath, parent.currentPath == parentPath {
                return "create:\(parentPath)"
            }
            if let inlineRenamePath = parent.inlineRenamePath {
                return "rename:\(inlineRenamePath)"
            }
            return nil
        }

        private var inlineCreateRowIndex: Int? {
            guard let parentPath = parent.inlineCreateFolderParentPath,
                  parent.currentPath == parentPath else { return nil }

            let placeholder = RemoteFileEntry(
                name: parent.inlineProposedName,
                path: RemoteFilePath.appending(parent.inlineProposedName, to: parent.currentPath),
                type: .directory,
                size: nil,
                modifiedAt: nil,
                permissions: nil,
                symlinkTarget: nil
            )

            for (index, entry) in parent.entries.enumerated() where sortsBefore(placeholder, entry) {
                return index
            }
            return parent.entries.count
        }

        private var inlineEditingDisplayRow: Int? {
            if let inlineCreateRowIndex {
                return inlineCreateRowIndex
            }

            guard let inlineRenamePath = parent.inlineRenamePath,
                  let entryIndex = parent.entries.firstIndex(where: { $0.path == inlineRenamePath }) else {
                return nil
            }

            return displayRow(forEntryIndex: entryIndex)
        }

        private func rowKind(for row: Int) -> RowKind? {
            guard row >= 0, row < numberOfRows(in: tableView) else { return nil }

            if let inlineCreateRowIndex {
                if row == inlineCreateRowIndex {
                    return .inlineCreatePlaceholder
                }
                return .entry(index: row > inlineCreateRowIndex ? row - 1 : row)
            }

            guard parent.entries.indices.contains(row) else { return nil }
            return .entry(index: row)
        }

        private func displayRow(forEntryIndex entryIndex: Int) -> Int {
            if let inlineCreateRowIndex, entryIndex >= inlineCreateRowIndex {
                return entryIndex + 1
            }
            return entryIndex
        }

        private func sortsBefore(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> Bool {
            let lhsDirectoryRank = lhs.type == .directory ? 0 : 1
            let rhsDirectoryRank = rhs.type == .directory ? 0 : 1
            if lhsDirectoryRank != rhsDirectoryRank {
                return lhsDirectoryRank < rhsDirectoryRank
            }

            switch parent.sort {
            case .name:
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison != .orderedSame {
                    return parent.sortDirection == .ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            case .modifiedAt:
                let lhsDate = lhs.modifiedAt ?? .distantPast
                let rhsDate = rhs.modifiedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return parent.sortDirection == .ascending ? lhsDate < rhsDate : lhsDate > rhsDate
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                let lhsSize = lhs.size ?? 0
                let rhsSize = rhs.size ?? 0
                if lhsSize != rhsSize {
                    return parent.sortDirection == .ascending ? lhsSize < rhsSize : lhsSize > rhsSize
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

}
#endif
