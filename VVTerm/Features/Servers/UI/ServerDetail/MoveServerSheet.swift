import SwiftUI

struct MoveServerSheet: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject private var storeManager = StoreManager.shared
    let server: Server
    let preferredDestination: Workspace?
    let onMove: (Server) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedWorkspaceId: UUID?
    @State private var selectedEnvironment: ServerEnvironment
    @State private var isMoving = false
    @State private var error: String?
    @State private var showingUpgrade = false
    @State private var showingCreateWorkspace = false

    init(
        serverManager: ServerManager,
        server: Server,
        preferredDestination: Workspace? = nil,
        onMove: @escaping (Server) -> Void
    ) {
        self.serverManager = serverManager
        self.server = server
        self.preferredDestination = preferredDestination
        self.onMove = onMove
        _selectedWorkspaceId = State(initialValue: preferredDestination?.id)
        _selectedEnvironment = State(initialValue: server.environment)
    }

    private var currentWorkspace: Workspace? {
        serverManager.workspace(withId: server.workspaceId)
    }

    private var destinationWorkspaces: [Workspace] {
        let destinations = serverManager.moveDestinations(for: server)
        guard let preferredDestination,
              destinations.contains(where: { $0.id == preferredDestination.id }) else {
            return destinations
        }

        return destinations.sorted { lhs, rhs in
            if lhs.id == preferredDestination.id { return true }
            if rhs.id == preferredDestination.id { return false }
            return lhs.order < rhs.order
        }
    }

    private var selectedDestination: Workspace? {
        if let selectedWorkspaceId,
           let matchingDestination = destinationWorkspaces.first(where: { $0.id == selectedWorkspaceId }) {
            return matchingDestination
        }

        return destinationWorkspaces.first
    }

    private var moveButtonDisabled: Bool {
        isMoving || selectedDestination == nil
    }

    private var destinationAvailabilityNotice: String {
        if serverManager.workspaces.count <= 1 {
            if storeManager.isPro {
                return String(localized: "No additional workspaces yet. Create one to move this server.")
            }

            return String(localized: "No additional workspaces yet. Create another workspace to move this server. Multiple workspaces are available on Pro.")
        }

        return String(localized: "No additional workspace is available for this server right now.")
    }

    private var environmentNotice: String? {
        guard let selectedDestination,
              serverManager.moveRequiresEnvironmentFallback(server, destination: selectedDestination) else {
            return nil
        }

        let resolvedEnvironment = serverManager.resolvedEnvironment(
            for: server,
            destination: selectedDestination,
            preferredEnvironment: selectedEnvironment
        )

        return String(
            format: String(localized: "\"%@\" isn't available in %@. The server will use %@ there."),
            server.environment.displayName,
            selectedDestination.name,
            resolvedEnvironment.displayName
        )
    }

    var body: some View {
        #if os(iOS)
        content
        #else
        VStack(spacing: 0) {
            DialogSheetHeader(
                title: "Move Server",
                onClose: { dismiss() },
                isCloseDisabled: isMoving
            )

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        formContent
    }

    private var formContent: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    Text(server.name)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("From") {
                    Text(currentWorkspace?.name ?? String(localized: "Current Workspace"))
                        .foregroundStyle(.secondary)
                }

                if destinationWorkspaces.isEmpty {
                    Button {
                        showingCreateWorkspace = true
                    } label: {
                        Label("Create Workspace", systemImage: "folder.badge.plus")
                    }
                } else {
                    Picker("Destination", selection: $selectedWorkspaceId) {
                        ForEach(destinationWorkspaces) { workspace in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.fromHex(workspace.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(workspace.name)
                            }
                            .tag(Optional(workspace.id))
                        }
                    }

                    Picker("Environment", selection: $selectedEnvironment) {
                        ForEach(selectedDestination?.environments ?? ServerEnvironment.builtInEnvironments) { env in
                            HStack {
                                Circle()
                                    .fill(env.color)
                                    .frame(width: 8, height: 8)
                                Text(env.displayName)
                            }
                            .tag(env)
                        }
                    }

                    if let environmentNotice {
                        Text(environmentNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                sectionHeader("Move")
            } footer: {
                if destinationWorkspaces.isEmpty {
                    Text(destinationAvailabilityNotice)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .interactiveDismissDisabled(isMoving)
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: selectedWorkspaceId) { _ in
            reconcileSelection()
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            WorkspaceFormSheet(
                serverManager: serverManager,
                onSave: { workspace in
                    selectedWorkspaceId = workspace.id
                }
            )
        }
        .proUpgradePresentation(isPresented: $showingUpgrade, source: .workspaceLimit)
        #if os(iOS)
        .navigationTitle("Move Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isMoving)
                    .tint(.secondary)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    moveServer()
                } label: {
                    if isMoving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Move")
                    }
                }
                .disabled(moveButtonDisabled)
            }
        }
        #endif
    }

    #if os(macOS)
    private var macActionRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }
            .disabled(isMoving)

            Button {
                moveServer()
            } label: {
                if isMoving {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Moving..."))
                    }
                } else {
                    Text("Move")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(moveButtonDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    #endif

    private func reconcileSelection() {
        let hasValidSelection = selectedWorkspaceId.map { selectedId in
            destinationWorkspaces.contains(where: { $0.id == selectedId })
        } ?? false

        if !hasValidSelection {
            selectedWorkspaceId = preferredDestination?.id ?? destinationWorkspaces.first?.id
        }

        guard let selectedDestination else { return }

        selectedEnvironment = serverManager.resolvedEnvironment(
            for: server,
            destination: selectedDestination,
            preferredEnvironment: selectedEnvironment
        )
    }

    private func moveServer() {
        guard let destination = selectedDestination else { return }

        isMoving = true
        error = nil

        serverManager.requestServerMove(
            server,
            to: destination,
            preferredEnvironment: selectedEnvironment,
            onMoved: { updatedServer in
                isMoving = false
                onMove(updatedServer)
                dismiss()
            },
            onProRequired: {
                isMoving = false
                showingUpgrade = true
            },
            onFailed: { message in
                isMoving = false
                error = message
            }
        )
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        #else
        Text(title)
        #endif
    }
}
