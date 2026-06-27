import SwiftUI

struct RemoteFileInspectorActions {
    let onDownload: ((RemoteFileEntry) -> Void)?
    let onShare: ((RemoteFileEntry) -> Void)?
    let onRename: ((RemoteFileEntry) -> Void)?
    let onMove: ((RemoteFileEntry) -> Void)?
    let onEditPermissions: ((RemoteFileEntry) -> Void)?
    let onDelete: ((RemoteFileEntry) -> Void)?

    func canDownload(_ entry: RemoteFileEntry) -> Bool {
        entry.type != .directory && onDownload != nil
    }

    func canShare(_ entry: RemoteFileEntry) -> Bool {
        entry.type != .directory && onShare != nil
    }

    func canEditPermissions(_ entry: RemoteFileEntry) -> Bool {
        onEditPermissions != nil && RemoteFilePermissionEditPolicy.canEditPermissions(for: entry)
    }

    func showsPrimaryActions(for entry: RemoteFileEntry) -> Bool {
        canDownload(entry) || canShare(entry) || onRename != nil || onMove != nil || canEditPermissions(entry)
    }
}

struct RemoteFileInspectorHeader: View {
    let entry: RemoteFileEntry
    let chrome: RemoteFileInspectorView.Chrome
    let sectionBackgroundColor: Color
    let actions: RemoteFileInspectorActions
    let onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: chrome == .sidebar ? 12 : 14) {
            RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                .fill(sectionBackgroundColor)
                .frame(width: iconSize, height: iconSize)
                .overlay {
                    Image(systemName: entry.iconName)
                        .font(.system(size: symbolSize, weight: .medium))
                        .foregroundStyle(RemoteFileInspectorMetadataPolicy.iconTint(for: entry))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(RemoteFileInspectorMetadataPolicy.subtitle(for: entry))
                    .font(subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if chrome == .sidebar {
                HStack(spacing: 6) {
                    Menu {
                        RemoteFileInspectorActionMenu(entry: entry, actions: actions)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text("File Actions"))

                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Close Preview"))
                    }
                }
            }
        }
    }

    private var iconSize: CGFloat {
        chrome == .sidebar ? 36 : 56
    }

    private var iconCornerRadius: CGFloat {
        chrome == .sidebar ? 9 : 14
    }

    private var symbolSize: CGFloat {
        chrome == .sidebar ? 17 : 26
    }

    private var titleFont: Font {
        chrome == .sidebar ? .headline.weight(.semibold) : .title2.weight(.semibold)
    }

    private var subtitleFont: Font {
        chrome == .sidebar ? .subheadline : .title3
    }
}

struct RemoteFileInspectorMetadataFormSection: View {
    let entry: RemoteFileEntry

    var body: some View {
        Section(String(localized: "Information")) {
            metadataFormRow(String(localized: "Name"), value: entry.name)
            metadataFormRow(String(localized: "Kind"), value: RemoteFileInspectorMetadataPolicy.kindLabel(for: entry))
            metadataFormMultilineRow(String(localized: "Location"), value: entry.path)
            metadataFormRow(String(localized: "Size"), value: RemoteFileInspectorMetadataPolicy.sizeLabel(for: entry))
            metadataFormRow(String(localized: "Modified"), value: RemoteFileInspectorMetadataPolicy.modifiedLabel(for: entry))

            if let permissions = entry.formattedPermissions {
                metadataFormRow(String(localized: "Permissions"), value: permissions)
            }

            if let target = entry.symlinkTarget {
                metadataFormMultilineRow(String(localized: "Symlink"), value: target)
            }
        }
    }

    private func metadataFormRow(_ key: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .textSelection(.enabled)
        } label: {
            Text(key)
        }
    }

    private func metadataFormMultilineRow(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key)
                .foregroundStyle(.primary)

            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

struct RemoteFileInspectorPrimaryActionsFormSection: View {
    let entry: RemoteFileEntry
    let actions: RemoteFileInspectorActions

    var body: some View {
        Section(String(localized: "Actions")) {
            if actions.canDownload(entry) {
                Button {
                    actions.onDownload?(entry)
                } label: {
                    Label(String(localized: "Download"), systemImage: "arrow.down.circle")
                }
            }

            if actions.canShare(entry) {
                Button {
                    actions.onShare?(entry)
                } label: {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
            }

            if actions.onRename != nil {
                Button {
                    actions.onRename?(entry)
                } label: {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
            }

            if actions.onMove != nil {
                Button {
                    actions.onMove?(entry)
                } label: {
                    Label(String(localized: "Move"), systemImage: "arrow.right.circle")
                }
            }

            if actions.canEditPermissions(entry) {
                Button {
                    actions.onEditPermissions?(entry)
                } label: {
                    Label(String(localized: "Permissions"), systemImage: "lock.shield")
                }
            }
        }
    }
}

struct RemoteFileInspectorDeleteFormSection: View {
    let entry: RemoteFileEntry
    let actions: RemoteFileInspectorActions

    var body: some View {
        Section {
            Button(role: .destructive) {
                actions.onDelete?(entry)
            } label: {
                Label {
                    Text(String(localized: "Delete"))
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

struct RemoteFileInspectorActionMenu: View {
    let entry: RemoteFileEntry
    let actions: RemoteFileInspectorActions

    @ViewBuilder
    var body: some View {
        if actions.canDownload(entry) {
            Button {
                actions.onDownload?(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }
        }

        if actions.canShare(entry) {
            Button {
                actions.onShare?(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }
        }

        if actions.canDownload(entry) || actions.canShare(entry) {
            Divider()
        }

        if actions.canEditPermissions(entry) {
            Button {
                actions.onEditPermissions?(entry)
            } label: {
                Label(String(localized: "Permissions…"), systemImage: "lock.shield")
            }
        }

        if actions.onRename != nil {
            Button {
                actions.onRename?(entry)
            } label: {
                Label(String(localized: "Rename…"), systemImage: "pencil")
            }
        }

        if actions.onMove != nil {
            Button {
                actions.onMove?(entry)
            } label: {
                Label(String(localized: "Move…"), systemImage: "arrow.right.circle")
            }
        }

        Divider()

        Button {
            Clipboard.copy(entry.name)
        } label: {
            Label(String(localized: "Copy Name"), systemImage: "textformat")
        }

        Button {
            Clipboard.copy(entry.path)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }

        if actions.onDelete != nil {
            Divider()

            Button(role: .destructive) {
                actions.onDelete?(entry)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }
}

enum RemoteFileInspectorMetadataPolicy {
    static func subtitle(for entry: RemoteFileEntry) -> String {
        let kind = kindLabel(for: entry)
        let size = sizeLabel(for: entry)
        guard size != "—" else { return kind }
        return "\(kind) - \(size)"
    }

    static func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    static func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            return entry.metadataTypeLabel == RemoteFileType.file.displayName
                ? String(localized: "Document")
                : entry.metadataTypeLabel
        }
    }

    static func iconTint(for entry: RemoteFileEntry) -> Color {
        switch entry.type {
        case .directory:
            return .accentColor
        case .symlink:
            return .secondary
        case .other:
            return .secondary
        case .file:
            return .primary
        }
    }
}
