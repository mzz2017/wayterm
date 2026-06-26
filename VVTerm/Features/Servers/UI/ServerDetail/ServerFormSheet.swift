import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ServerFormSheet: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var sshKeyStore = SSHKeySettingsStore.shared
    @EnvironmentObject private var appLockManager: AppLockManager
    private let credentialProvider: ServerFormCredentialProvider
    private let connectionTester: ServerConnectionTester
    let workspace: Workspace?
    let server: Server?
    let prefill: ServerFormPrefill?
    let onSave: (Server) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var transportSelection: ServerTransportSelection = .standard
    @State private var selectedAuthMethod: AuthMethod = .password
    @State private var password: String = ""
    @State private var sshKey: String = ""
    @State private var sshPassphrase: String = ""
    @State private var sshPublicKey: String = ""
    @State private var selectedCloudflareAccessMode: CloudflareAccessMode = .oauth
    @State private var cloudflareClientID: String = ""
    @State private var cloudflareClientSecret: String = ""
    @State private var cloudflareTeamDomainOverride: String = ""
    @State private var showCloudflareOverrides: Bool = false
    @State private var selectedWorkspaceId: UUID?
    @State private var selectedEnvironment: ServerEnvironment = .production
    @State private var notes: String = ""
    @State private var requiresBiometricUnlock: Bool = false
    @State private var multiplexer: TerminalMultiplexer = .tmux
    @State private var tmuxStartupBehavior: TmuxStartupBehavior = .vvtermManaged

    @State private var showingServerLimitAlert = false
    @State private var showingCreateWorkspace = false
    @State private var showingAddKeySheet = false
    @State private var isSaving = false
    @State private var isLoadingCredentials = false
    @State private var error: String?
    @State private var storedKeys: [SSHKeyEntry] = []
    @State private var selectedStoredKey: SSHKeyEntry?
    @State private var programmaticSSHKeyValue: String?
    @State private var isTestingConnection = false
    @State private var connectionTestError: String?
    @State private var connectionTestSucceeded = false
    @State private var lastTestSnapshot: ConnectionTestSnapshot?
    @State private var activeConnectionTestRequestID: UUID?
    @State private var showingLocalDiscoverySheet = false

    private var isEditing: Bool { server != nil }

    @MainActor
    init(
        serverManager: ServerManager,
        workspace: Workspace?,
        server: Server? = nil,
        prefill: ServerFormPrefill? = nil,
        onSave: @escaping (Server) -> Void
    ) {
        self.init(
            serverManager: serverManager,
            workspace: workspace,
            server: server,
            prefill: prefill,
            credentialProvider: .shared,
            connectionTester: .shared,
            onSave: onSave
        )
    }

    init(
        serverManager: ServerManager,
        workspace: Workspace?,
        server: Server? = nil,
        prefill: ServerFormPrefill? = nil,
        credentialProvider: ServerFormCredentialProvider,
        connectionTester: ServerConnectionTester,
        onSave: @escaping (Server) -> Void
    ) {
        self.serverManager = serverManager
        self.workspace = workspace
        self.server = server
        self.prefill = prefill
        self.credentialProvider = credentialProvider
        self.connectionTester = connectionTester
        self.onSave = onSave

        let initialWorkspaceId = server?.workspaceId ?? workspace?.id
        _selectedWorkspaceId = State(initialValue: initialWorkspaceId)
        let defaults = ServerFormDefaults()

        if let server = server {
            _name = State(initialValue: server.name)
            _host = State(initialValue: server.host)
            _port = State(initialValue: String(server.port))
            _username = State(initialValue: server.username)
            _transportSelection = State(initialValue: ServerTransportSelection(server: server))
            _selectedAuthMethod = State(initialValue: server.authMethod)
            _selectedCloudflareAccessMode = State(initialValue: server.cloudflareAccessMode ?? .oauth)
            _cloudflareTeamDomainOverride = State(initialValue: server.cloudflareTeamDomainOverride ?? "")
            _showCloudflareOverrides = State(
                initialValue: !(server.cloudflareTeamDomainOverride ?? "").isEmpty
            )
            _selectedEnvironment = State(initialValue: server.environment)
            _notes = State(initialValue: server.notes ?? "")
            _requiresBiometricUnlock = State(initialValue: server.requiresBiometricUnlock)
            _multiplexer = State(initialValue: server.multiplexerOverride ?? defaults.multiplexer())
            _tmuxStartupBehavior = State(initialValue: server.tmuxStartupBehaviorOverride ?? defaults.tmuxStartupBehavior())
        } else if let prefill {
            _name = State(initialValue: prefill.name)
            _host = State(initialValue: prefill.host)
            _port = State(initialValue: String(prefill.port))
            _username = State(initialValue: prefill.username ?? "")
            _multiplexer = State(initialValue: defaults.multiplexer())
            _tmuxStartupBehavior = State(initialValue: defaults.tmuxStartupBehavior())
        } else {
            _multiplexer = State(initialValue: defaults.multiplexer())
            _tmuxStartupBehavior = State(initialValue: defaults.tmuxStartupBehavior())
        }
    }

    private var serverCount: Int {
        serverManager.servers.count
    }

    private var isAtLimit: Bool {
        !isEditing && !serverManager.canAddServer
    }

    private var assignmentWorkspaces: [Workspace] {
        serverManager.assignmentWorkspaces(for: server)
    }

    private var selectedWorkspace: Workspace? {
        if let selectedWorkspaceId,
           let matchingWorkspace = assignmentWorkspaces.first(where: { $0.id == selectedWorkspaceId }) {
            return matchingWorkspace
        }

        return assignmentWorkspaces.first
    }

    private var workspaceEnvironmentNotice: String? {
        guard let server,
              let selectedWorkspace,
              selectedWorkspace.id != server.workspaceId,
              serverManager.moveRequiresEnvironmentFallback(server, destination: selectedWorkspace) else {
            return nil
        }

        let resolvedEnvironment = serverManager.resolvedEnvironment(
            for: server,
            destination: selectedWorkspace,
            preferredEnvironment: selectedEnvironment
        )

        return String(
            format: String(localized: "\"%@\" isn't available in %@. The server will use %@ there."),
            server.environment.displayName,
            selectedWorkspace.name,
            resolvedEnvironment.displayName
        )
    }

    private var workspaceAvailabilityHelpText: String? {
        guard assignmentWorkspaces.count <= 1 else {
            return nil
        }

        if serverManager.workspaces.count <= 1 {
            if isEditing {
                return String(localized: "No additional workspaces yet. Create one to move this server.")
            }

            return String(localized: "No additional workspaces yet. Create one to organize servers separately.")
        }

        return String(localized: "No additional workspace is available for this server right now.")
    }

    private struct ConnectionTestSnapshot: Equatable {
        let host: String
        let port: String
        let username: String
        let transportSelection: ServerTransportSelection
        let authMethod: AuthMethod
        let password: String
        let sshKey: String
        let sshPassphrase: String
        let sshPublicKey: String
        let cloudflareAccessMode: CloudflareAccessMode
        let cloudflareClientID: String
        let cloudflareClientSecret: String
        let cloudflareTeamDomainOverride: String
    }

    private var connectionSnapshot: ConnectionTestSnapshot {
        ConnectionTestSnapshot(
            host: host,
            port: port,
            username: currentDraft.effectiveUsername,
            transportSelection: transportSelection,
            authMethod: selectedAuthMethod,
            password: password,
            sshKey: sshKey,
            sshPassphrase: sshPassphrase,
            sshPublicKey: sshPublicKey,
            cloudflareAccessMode: selectedCloudflareAccessMode,
            cloudflareClientID: cloudflareClientID,
            cloudflareClientSecret: cloudflareClientSecret,
            cloudflareTeamDomainOverride: cloudflareTeamDomainOverride
        )
    }

    private var hasValidConnectionTest: Bool {
        connectionTestSucceeded && lastTestSnapshot == connectionSnapshot
    }

    private var saveButtonDisabled: Bool {
        !isValid || isSaving || isAtLimit || isLoadingCredentials || isTestingConnection
    }

    var body: some View {
        #if os(iOS)
        formContent
        #else
        VStack(spacing: 0) {
            DialogSheetHeader(
                title: isEditing ? "Edit Server" : "Add Server",
                onClose: { dismiss() },
                isCloseDisabled: isSaving
            )

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
        #endif
    }

    private var formContent: some View {
        Form {
            limitSection
            serverSection
            authSection
            connectionSection
            sessionSection
            securitySection
            assignmentSection
            notesSection
            errorSection
        }
        .formStyle(.grouped)
        #if os(iOS)
        .environment(\.defaultMinListRowHeight, 34)
        .modifier(CompactListSectionSpacingModifier())
        .modifier(TransparentNavigationBarModifier())
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarAppearance(
                backgroundColor: .clear,
                isTranslucent: true,
                shadowColor: .clear
            )
        .navigationTitle(isEditing ? String(localized: "Edit Server") : String(localized: "Add Server"))
        #endif
        .interactiveDismissDisabled(isSaving)
        .task {
            await loadInitialFormData()
        }
        #if os(iOS)
            .toolbar { serverFormToolbar }
        #endif
            .sheet(isPresented: $showingAddKeySheet) {
                addSSHKeySheet
            }
            .sheet(isPresented: $showingCreateWorkspace) {
                createWorkspaceSheet
            }
            .sheet(isPresented: $showingLocalDiscoverySheet) {
                localDiscoverySheet
            }
            .limitReachedAlert(.servers, isPresented: $showingServerLimitAlert)
            .onAppear {
                handleFormAppear()
            }
            .onChange(of: host) { _ in resetConnectionTestState() }
            .onChange(of: port) { _ in resetConnectionTestState() }
            .onChange(of: username) { _ in resetConnectionTestState() }
            .onChange(of: transportSelection) { _ in resetConnectionTestState() }
            .onChange(of: selectedAuthMethod) { _ in resetConnectionTestState() }
            .onChange(of: selectedWorkspaceId) { _ in
                handleWorkspaceSelectionChanged()
            }
            .onChange(of: password) { _ in resetConnectionTestState() }
            .onChange(of: sshKey) { _ in
                handleSSHKeyChanged()
            }
            .onChange(of: sshPassphrase) { _ in resetConnectionTestState() }
            .onChange(of: sshPublicKey) { _ in resetConnectionTestState() }
            .onChange(of: selectedCloudflareAccessMode) { _ in resetConnectionTestState() }
            .onChange(of: cloudflareClientID) { _ in resetConnectionTestState() }
            .onChange(of: cloudflareClientSecret) { _ in resetConnectionTestState() }
            .onChange(of: cloudflareTeamDomainOverride) { _ in resetConnectionTestState() }
    }

    private var addSSHKeySheet: some View {
        AddSSHKeySheet(keyStore: sshKeyStore, onSave: handleStoredKeyAdded)
    }

    private var createWorkspaceSheet: some View {
        WorkspaceFormSheet(
            serverManager: serverManager,
            onSave: { workspace in
                selectedWorkspaceId = workspace.id
            }
        )
    }

    private var localDiscoverySheet: some View {
        LocalDeviceDiscoverySheet(manager: LocalSSHDiscoveryManager()) { discoveredHost in
            applyPrefill(ServerFormPrefill(discoveredHost: discoveredHost))
        }
    }

    private func loadInitialFormData() async {
        storedKeys = credentialProvider.storedSSHKeys()

        // Load credentials from keychain when editing.
        guard let server = server else { return }
        isLoadingCredentials = true
        defer { isLoadingCredentials = false }

        do {
            let credentials = try credentialProvider.credentials(for: server)
            applyLoadedCredentials(credentials, for: server)
            selectMatchingStoredKeyIfAvailable()
        } catch {
            self.error = String(format: String(localized: "Failed to load credentials: %@"), error.localizedDescription)
        }
    }

    private func applyLoadedCredentials(_ credentials: ServerCredentials, for server: Server) {
        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                if let pwd = credentials.password {
                    password = pwd
                }
            case .sshKey:
                if let keyData = credentials.privateKey,
                   let keyString = String(data: keyData, encoding: .utf8) {
                    sshKey = keyString
                }
            case .sshKeyWithPassphrase:
                if let keyData = credentials.privateKey,
                   let keyString = String(data: keyData, encoding: .utf8) {
                    sshKey = keyString
                }
                if let phrase = credentials.passphrase {
                    sshPassphrase = phrase
                }
            }
        }

        if let publicKeyData = credentials.publicKey,
           let publicKeyString = String(data: publicKeyData, encoding: .utf8) {
            sshPublicKey = publicKeyString
        } else {
            sshPublicKey = ""
        }

        cloudflareClientID = credentials.cloudflareClientID ?? ""
        cloudflareClientSecret = credentials.cloudflareClientSecret ?? ""
    }

    private func handleStoredKeyAdded(_ entry: SSHKeyEntry) {
        storedKeys = credentialProvider.storedSSHKeys()
        selectedStoredKey = entry
        loadStoredKey(entry)
    }

    private func handleFormAppear() {
        storedKeys = credentialProvider.storedSSHKeys()
        selectMatchingStoredKeyIfAvailable()
        reconcileAssignmentWorkspace()
    }

    private func handleWorkspaceSelectionChanged() {
        reconcileAssignmentWorkspace()
        resetConnectionTestState()
    }

    private func handleSSHKeyChanged() {
        if let programmaticSSHKeyValue,
           sshKey == programmaticSSHKeyValue {
            self.programmaticSSHKeyValue = nil
        } else if !isLoadingCredentials {
            selectedStoredKey = nil
            sshPublicKey = ""
        }
        resetConnectionTestState()
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var serverFormToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(isSaving)
                .tint(.secondary)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                saveServer()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(isEditing ? String(localized: "Save") : String(localized: "Add"))
                }
            }
            .disabled(saveButtonDisabled)
        }
    }
    #endif

    #if os(macOS)
    private var macActionRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }
            .disabled(isSaving)

            Button {
                saveServer()
            } label: {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Saving..."))
                    }
                } else {
                    Text(isEditing ? String(localized: "Save") : String(localized: "Add"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(saveButtonDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    #endif

    @ViewBuilder
    private var assignmentSection: some View {
        Section {
            if assignmentWorkspaces.count > 1 {
                Picker("Workspace", selection: $selectedWorkspaceId) {
                    ForEach(assignmentWorkspaces) { workspace in
                        HStack(spacing: 8) {
                            if serverManager.isWorkspaceLocked(workspace) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                Circle()
                                    .fill(Color.fromHex(workspace.colorHex))
                                    .frame(width: 8, height: 8)
                            }

                            Text(workspace.name)
                        }
                        .tag(Optional(workspace.id))
                    }
                }
            } else {
                LabeledContent("Workspace") {
                    if let selectedWorkspace {
                        HStack(spacing: 8) {
                            if serverManager.isWorkspaceLocked(selectedWorkspace) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                Circle()
                                    .fill(Color.fromHex(selectedWorkspace.colorHex))
                                    .frame(width: 8, height: 8)
                            }

                            Text(selectedWorkspace.name)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No Workspace")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Environment", selection: $selectedEnvironment) {
                ForEach(selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments) { env in
                    HStack {
                        Circle()
                            .fill(env.color)
                            .frame(width: 8, height: 8)
                        Text(env.displayName)
                    }
                    .tag(env)
                }
            }

            if let workspaceEnvironmentNotice {
                Text(workspaceEnvironmentNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if assignmentWorkspaces.count <= 1 {
                Button {
                    showingCreateWorkspace = true
                } label: {
                    Label("Create Workspace", systemImage: "folder.badge.plus")
                }
            }
        } header: {
            sectionHeader("Workspace")
        } footer: {
            if let workspaceAvailabilityHelpText {
                Text(workspaceAvailabilityHelpText)
            }
        }
    }

    @ViewBuilder
    private var limitSection: some View {
        if isAtLimit {
            Section {
                ProLimitBanner(
                    title: String(localized: "Server Limit Reached"),
                    message: String(format: String(localized: "You've reached the free limit of %lld servers. Pro unlocks unlimited servers, connections, and split panes."), Int64(FreeTierLimits.maxServers))
                ) {
                    showingServerLimitAlert = true
                }
            }
        } else if !isEditing && !storeManager.isPro {
            Section {
                UsageIndicator(
                    current: serverCount,
                    limit: FreeTierLimits.maxServers,
                    label: String(localized: "Servers"),
                    showUpgrade: $showingServerLimitAlert
                )
            }
        }
    }

    private var serverSection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text(String(localized: "My Server")))
                #if os(iOS)
                .textContentType(.name)
                #endif

            HStack(spacing: 12) {
                TextField("Host", text: $host, prompt: Text(String(localized: "203.0.113.10")))
                    #if os(iOS)
                    .textContentType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif

                TextField("Port", text: $port, prompt: Text(String(localized: "22")))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76)
            }

            TextField("Username", text: $username, prompt: Text(String(localized: "root")))
                #if os(iOS)
                .textContentType(.username)
                #endif
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Button {
                showingLocalDiscoverySheet = true
            } label: {
                Label(String(localized: "Pick from Local Discovery..."), systemImage: "dot.radiowaves.left.and.right")
            }
        } header: {
            sectionHeader("Server")
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section {
            Picker("Transport", selection: $transportSelection) {
                ForEach(ServerTransportSelection.allCases) { transport in
                    Label(transport.displayName, systemImage: transport.icon)
                        .tag(transport)
                }
            }

            if transportSelection == .cloudflare {
                Picker("Cloudflare Access", selection: $selectedCloudflareAccessMode) {
                    ForEach(CloudflareAccessMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                switch selectedCloudflareAccessMode {
                case .oauth:
                    Text(String(localized: "OAuth login will open in browser. Team/App domain values are auto-discovered from host."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showCloudflareOverrides {
                        TextField("Team Domain Override", text: $cloudflareTeamDomainOverride, prompt: Text("team.cloudflareaccess.com"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        Button("Hide Overrides") {
                            showCloudflareOverrides = false
                        }
                    } else {
                        Button("Set Team Domain Override") {
                            showCloudflareOverrides = true
                        }
                    }

                case .serviceToken:
                    TextField("Service Token Client ID", text: $cloudflareClientID, prompt: Text(String(localized: "Required")))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Service Token Client Secret", text: $cloudflareClientSecret, prompt: Text(String(localized: "Required")))
                }
            }

            if transportSelection != .tailscale {
                Picker("Method", selection: $selectedAuthMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Label(method.displayName, systemImage: method.icon)
                            .tag(method)
                    }
                }

                switch selectedAuthMethod {
                case .password:
                    SecureField("Password", text: $password, prompt: Text(String(localized: "Required")))
                        #if os(iOS)
                        .textContentType(.password)
                        #endif

                case .sshKey:
                    keyInputView

                case .sshKeyWithPassphrase:
                    keyInputView
                    SecureField("Key Passphrase", text: $sshPassphrase, prompt: Text(String(localized: "Optional")))
                }
            } else {
                Text(String(localized: "Uses server-side Tailscale SSH policy. No password or SSH key is required."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Authentication")
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                requestConnectionTest(force: true)
            } label: {
                Text(String(localized: "Test Connection"))
                    .opacity(isTestingConnection ? 0 : 1)
                    .overlay {
                        if isTestingConnection {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text(String(localized: "Testing..."))
                            }
                        }
                    }
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .controlSize(.regular)
            .disabled(!isValid || isTestingConnection)
        } header: {
            sectionHeader("Connection")
        } footer: {
            connectionFooter
        }
    }

    private var sessionSection: some View {
        Section {
            Picker("Session persistence", selection: $multiplexer) {
                ForEach(TerminalMultiplexer.allCases) { mux in
                    Text(mux.displayName).tag(mux)
                }
            }

            if multiplexer.isEnabled {
                Picker("On connect", selection: $tmuxStartupBehavior) {
                    ForEach(TmuxStartupBehavior.configCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(tmuxStartupBehavior.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Session")
        } footer: {
            Text("Sessions stay alive across app restarts and disconnects when tmux is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var securitySection: some View {
        Section {
            Toggle(
                String(format: String(localized: "Require %@ to open this server"), appLockManager.biometryDisplayName),
                isOn: $requiresBiometricUnlock
            )
            .disabled(!appLockManager.isBiometryAvailable && !requiresBiometricUnlock)

            if !appLockManager.isBiometryAvailable,
               let message = appLockManager.biometryAvailabilityMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Security")
        }
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $notes)
                .frame(minHeight: 56)
                #if os(iOS)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                #endif
        } header: {
            sectionHeader("Notes")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = error {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    #if os(iOS)
    private struct CompactListSectionSpacingModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 17.0, *) {
                content.listSectionSpacing(.compact)
            } else {
                content
            }
        }
    }

    private struct TransparentNavigationBarModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 16.0, *) {
                content.toolbarBackground(.hidden, for: .navigationBar)
            } else {
                content
            }
        }
    }
    #endif

    // MARK: - Key Input View

    @ViewBuilder
    private var connectionFooter: some View {
        if connectionTestSucceeded && hasValidConnectionTest {
            Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if let connectionTestError {
            Text(connectionTestError)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var keyInputView: some View {
        // Stored keys picker
        if !storedKeys.isEmpty {
            Picker("Stored Key", selection: $selectedStoredKey) {
                Text("Select a key...").tag(nil as SSHKeyEntry?)
                ForEach(storedKeys) { key in
                    HStack {
                        Image(systemName: key.hasPassphrase ? "lock.shield.fill" : "key.fill")
                        Text(key.name)
                    }
                    .tag(key as SSHKeyEntry?)
                }
            }
            .onChange(of: selectedStoredKey) { newKey in
                if let key = newKey {
                    loadStoredKey(key)
                }
            }
        }

        Button("Add to Keychain") {
            showingAddKeySheet = true
        }
    }

    private func loadStoredKey(_ entry: SSHKeyEntry) {
        do {
            guard let material = try credentialProvider.storedSSHKeyMaterial(for: entry) else {
                sshPublicKey = entry.publicKey ?? ""
                return
            }

            if sshKey != material.privateKey {
                programmaticSSHKeyValue = material.privateKey
            }
            sshKey = material.privateKey
            if let passphrase = material.passphrase {
                sshPassphrase = passphrase
            }
            sshPublicKey = material.publicKey ?? ""
        } catch {
            self.error = String(format: String(localized: "Failed to load key: %@"), error.localizedDescription)
        }
    }

    private func selectMatchingStoredKeyIfAvailable() {
        guard selectedStoredKey == nil,
              !sshKey.isEmpty,
              !storedKeys.isEmpty,
              selectedAuthMethod != .password else {
            return
        }

        selectedStoredKey = credentialProvider.matchingStoredSSHKey(
            in: storedKeys,
            privateKey: sshKey,
            passphrase: sshPassphrase,
            authMethod: selectedAuthMethod
        )
    }

    // MARK: - Validation

    private var isValid: Bool {
        !name.isEmpty &&
        !host.isEmpty &&
        ServerPortValidator.normalizedPort(from: port) != nil &&
        hasValidCredentials
    }

    private var hasValidCredentials: Bool {
        guard transportSelection != .tailscale else {
            return true
        }

        if transportSelection == .cloudflare {
            switch selectedCloudflareAccessMode {
            case .oauth:
                break
            case .serviceToken:
                guard !cloudflareClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !cloudflareClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
            }
        }

        switch selectedAuthMethod {
        case .password:
            return !password.isEmpty
        case .sshKey:
            return !sshKey.isEmpty
        case .sshKeyWithPassphrase:
            return !sshKey.isEmpty && !sshPassphrase.isEmpty
        }
    }

    // MARK: - Connection Test

    private func resetConnectionTestState() {
        cancelActiveConnectionTest()
        connectionTestError = nil
        connectionTestSucceeded = false
        lastTestSnapshot = nil
    }

    private func cancelActiveConnectionTest() {
        guard let requestID = activeConnectionTestRequestID else { return }
        activeConnectionTestRequestID = nil
        isTestingConnection = false
        connectionTester.cancelConnectionTestRequest(requestID)
    }

    private var currentDraft: ServerFormDraft {
        ServerFormDraft(
            workspaceId: selectedWorkspace?.id ?? assignmentWorkspaces.first?.id ?? serverManager.workspaces.first?.id ?? UUID(),
            environment: selectedEnvironment,
            name: name,
            host: host,
            port: port,
            username: username,
            connectionMode: transportSelection.connectionMode,
            authMethod: selectedAuthMethod,
            cloudflareAccessMode: selectedCloudflareAccessMode,
            cloudflareTeamDomainOverride: cloudflareTeamDomainOverride,
            notes: notes,
            requiresBiometricUnlock: requiresBiometricUnlock,
            multiplexer: multiplexer,
            tmuxStartupBehavior: tmuxStartupBehavior,
            password: password,
            sshKey: sshKey,
            sshPassphrase: sshPassphrase,
            sshPublicKey: sshPublicKey,
            cloudflareClientID: cloudflareClientID,
            cloudflareClientSecret: cloudflareClientSecret
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

    private func applyPrefill(_ prefill: ServerFormPrefill) {
        name = prefill.name
        host = prefill.host
        port = String(prefill.port)
        if let username = prefill.username, !username.isEmpty {
            self.username = username
        }
        resetConnectionTestState()
    }

    private func reconcileAssignmentWorkspace() {
        if selectedWorkspaceId == nil {
            selectedWorkspaceId = assignmentWorkspaces.first?.id
        }

        guard let selectedWorkspace else { return }

        selectedEnvironment = ServerMoveSupport.resolveEnvironment(
            currentEnvironment: server?.environment ?? selectedEnvironment,
            preferredEnvironment: selectedEnvironment,
            destination: selectedWorkspace
        )
    }

    private func requestConnectionTest(force: Bool) {
        let snapshot = connectionSnapshot
        let shouldSkip = !force && hasValidConnectionTest
        if shouldSkip {
            return
        }

        cancelActiveConnectionTest()
        isTestingConnection = true
        connectionTestError = nil
        connectionTestSucceeded = false

        let serverId = server?.id ?? UUID()
        let submission = ServerFormSubmissionBuilder.build(
            id: serverId,
            createdAt: server?.createdAt ?? Date(),
            draft: currentDraft
        )
        let requestID = UUID()
        activeConnectionTestRequestID = requestID

        connectionTester.requestConnectionTest(
            id: requestID,
            server: submission.server,
            credentials: submission.credentials,
            onSucceeded: {
                guard activeConnectionTestRequestID == requestID,
                      connectionSnapshot == snapshot else { return }
                lastTestSnapshot = snapshot
                connectionTestSucceeded = true
            },
            onFailed: { error in
                guard activeConnectionTestRequestID == requestID,
                      connectionSnapshot == snapshot else { return }
                applyConnectionTestFailure(error, testServer: submission.server, snapshot: snapshot)
            },
            onCompleted: {
                guard activeConnectionTestRequestID == requestID else { return }
                activeConnectionTestRequestID = nil
                isTestingConnection = false
            }
        )
    }

    private func applyConnectionTestFailure(
        _ error: Error,
        testServer: Server,
        snapshot: ConnectionTestSnapshot
    ) {
        lastTestSnapshot = snapshot
        let baseMessage = error.localizedDescription
        if testServer.connectionMode == .tailscale {
            let reminder = String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback).")
            if baseMessage.contains(reminder) {
                connectionTestError = baseMessage
            } else {
                connectionTestError = "\(baseMessage)\n\(reminder)"
            }
        } else {
            connectionTestError = baseMessage
        }
        if let sshError = error as? SSHError, case .cloudflareConfigurationRequired = sshError {
            showCloudflareOverrides = true
        }
        connectionTestSucceeded = false
    }

    private func saveServer() {
        isSaving = true
        error = nil

        let serverId = server?.id ?? UUID()
        let submission = ServerFormSubmissionBuilder.build(
            id: serverId,
            createdAt: server?.createdAt ?? Date(),
            draft: currentDraft
        )

        serverManager.requestServerSave(
            submission.server,
            credentials: submission.credentials,
            mode: isEditing ? .update : .create,
            onSaved: { savedServer in
                isSaving = false
                onSave(savedServer)
                dismiss()
            },
            onProRequired: {
                showingServerLimitAlert = true
                isSaving = false
            },
            onFailed: { message in
                error = message
                isSaving = false
            }
        )
    }
}

// MARK: - Preview

#Preview {
    ServerFormSheet(
        serverManager: ServerManager.shared,
        workspace: nil,
        onSave: { _ in }
    )
}
