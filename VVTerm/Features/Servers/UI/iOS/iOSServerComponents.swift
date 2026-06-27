//
//  iOSServerComponents.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
// MARK: - iOS Server Row

struct iOSServerRow: View {
    let server: Server
    @ObservedObject var serverManager: ServerManager
    let onTap: () -> Void
    let onEdit: () -> Void
    var onMove: (() -> Void)? = nil
    var onLockedTap: (() -> Void)? = nil

    @Environment(\.privacyModeEnabled) private var privacyModeEnabled

    private var isLocked: Bool {
        serverManager.isServerLocked(server)
    }

    var body: some View {
        Button(action: {
            if isLocked {
                onLockedTap?()
            } else {
                onTap()
            }
        }) {
            HStack(spacing: 12) {
                // Server icon or lock icon
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                } else {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                }

                // Server info
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(isLocked ? .secondary : .primary)

                    Text(server.visibleAddress(privacyModeEnabled: privacyModeEnabled))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLocked {
                    LockedBadge()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .opacity(isLocked ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onMove {
                Button {
                    onMove()
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .tint(.blue)
            }

            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                serverManager.requestServerDeletion(server)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            if isLocked {
                Button {
                    onLockedTap?()
                } label: {
                    Label("Unlock with Pro", systemImage: "lock.open.fill")
                }

                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                if let onMove {
                    Button {
                        onMove()
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                }

                Button(role: .destructive) {
                    serverManager.requestServerDeletion(server)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } else {
                Button {
                    onTap()
                } label: {
                    Label("Connect", systemImage: "play.fill")
                }

                if let onMove {
                    Button {
                        onMove()
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                }

                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }
}

// MARK: - iOS Active Connection Row

struct iOSActiveConnectionRow: View {
    let session: ConnectionSession
    let title: String
    let tabCount: Int
    let onOpen: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                // Connection info
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(session.connectionState.statusString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !session.tmuxStatus.shortLabel.isEmpty {
                    Text(session.tmuxStatus.shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Text(tabCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDisconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark")
            }
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var tabCountText: String {
        let count = tabCount
        return count == 1
            ? String(format: String(localized: "%lld tab"), count)
            : String(format: String(localized: "%lld tabs"), count)
    }
}

// MARK: - iOS Workspace Picker View

struct iOSWorkspacePickerView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var storeManager: StoreManager
    @Binding var selectedWorkspace: Workspace?
    let onDismiss: () -> Void

    @State private var lockedWorkspaceAlert: Workspace?
    @State private var showingCreateWorkspace = false
    @State private var workspaceToEdit: Workspace?
    @State private var workspaceToDelete: Workspace?
    @State private var workspaceToManageServers: Workspace?

    var body: some View {
        List {
            ForEach(serverManager.workspaces) { workspace in
                workspaceRow(for: workspace)
            }
        }
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateWorkspace = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            WorkspaceFormSheet(
                serverManager: serverManager,
                storeManager: storeManager,
                onSave: { newWorkspace in
                    selectedWorkspace = newWorkspace
                }
            )
        }
        .sheet(item: $workspaceToEdit) { workspace in
            WorkspaceFormSheet(
                serverManager: serverManager,
                storeManager: storeManager,
                workspace: workspace,
                onSave: { updatedWorkspace in
                    if selectedWorkspace?.id == updatedWorkspace.id {
                        selectedWorkspace = updatedWorkspace
                    }
                }
            )
        }
        .sheet(item: $workspaceToManageServers) { workspace in
            NavigationStack {
                LockedWorkspaceServerManagementSheet(
                    serverManager: serverManager,
                    storeManager: storeManager,
                    workspace: workspace
                )
            }
        }
        .lockedItemAlert(
            .workspace,
            itemName: lockedWorkspaceAlert?.name ?? "",
            isPresented: Binding(
                get: { lockedWorkspaceAlert != nil },
                set: { if !$0 { lockedWorkspaceAlert = nil } }
            )
        )
        .alert("Delete Workspace?", isPresented: Binding(
            get: { workspaceToDelete != nil },
            set: { if !$0 { workspaceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let workspace = workspaceToDelete {
                    deleteWorkspace(workspace)
                }
            }
        } message: {
            Text(deleteWarningText(for: workspaceToDelete))
        }
    }

    private func workspaceRow(for workspace: Workspace) -> some View {
        let isLocked = serverManager.isWorkspaceLocked(workspace)
        return Button {
            select(workspace, isLocked: isLocked)
        } label: {
            workspaceRowLabel(for: workspace, isLocked: isLocked)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            workspaceLeadingSwipeActions(for: workspace, isLocked: isLocked)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            workspaceTrailingSwipeActions(for: workspace, isLocked: isLocked)
        }
        .contextMenu {
            workspaceContextMenu(for: workspace, isLocked: isLocked)
        }
    }

    private func select(_ workspace: Workspace, isLocked: Bool) {
        if isLocked {
            lockedWorkspaceAlert = workspace
        } else {
            selectedWorkspace = workspace
            onDismiss()
        }
    }

    private func workspaceServerCount(_ workspace: Workspace) -> Int {
        serverManager.servers(in: workspace, environment: nil).count
    }

    private func workspaceRowLabel(for workspace: Workspace, isLocked: Bool) -> some View {
        HStack {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                Circle()
                    .fill(Color.fromHex(workspace.colorHex))
                    .frame(width: 12, height: 12)
            }

            Text(workspace.name)
                .foregroundStyle(isLocked ? .secondary : .primary)

            Spacer()

            if isLocked {
                LockedBadge()
            } else {
                if selectedWorkspace?.id == workspace.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }

                Text(workspaceServerCount(workspace), format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isLocked ? 0.7 : 1.0)
    }

    @ViewBuilder
    private func workspaceLeadingSwipeActions(for workspace: Workspace, isLocked: Bool) -> some View {
        if isLocked {
            if workspaceServerCount(workspace) > 0 {
                Button {
                    workspaceToManageServers = workspace
                } label: {
                    Label("Manage Servers", systemImage: "server.rack")
                }
                .tint(.blue)
            }

            Button {
                lockedWorkspaceAlert = workspace
            } label: {
                Label("Unlock with Pro", systemImage: "lock.open.fill")
            }
            .tint(.orange)
        } else {
            Button {
                workspaceToEdit = workspace
            } label: {
                Label("Edit Workspace", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func workspaceTrailingSwipeActions(for workspace: Workspace, isLocked: Bool) -> some View {
        if !isLocked {
            Button(role: .destructive) {
                workspaceToDelete = workspace
            } label: {
                Label("Delete Workspace", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(for workspace: Workspace, isLocked: Bool) -> some View {
        if isLocked {
            if workspaceServerCount(workspace) > 0 {
                Button {
                    workspaceToManageServers = workspace
                } label: {
                    Label("Manage Servers", systemImage: "server.rack")
                }
            }

            Button {
                lockedWorkspaceAlert = workspace
            } label: {
                Label("Unlock with Pro", systemImage: "lock.open.fill")
            }
        } else {
            Button {
                workspaceToEdit = workspace
            } label: {
                Label("Edit Workspace", systemImage: "pencil")
            }

            Button(role: .destructive) {
                workspaceToDelete = workspace
            } label: {
                Label("Delete Workspace", systemImage: "trash")
            }
        }
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        serverManager.requestWorkspaceDeletion(workspace) {
            if selectedWorkspace?.id == workspace.id {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
    }

    private func deleteWarningText(for workspace: Workspace?) -> String {
        guard let workspace else {
            return IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: nil)
        }
        let count = serverManager.servers(in: workspace, environment: nil).count
        return IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: count)
    }
}
#endif
