import SwiftUI

struct ServerFormAuthenticationSection<KeyInput: View>: View {
    @Binding var transportSelection: ServerTransportSelection
    @Binding var selectedCloudflareAccessMode: CloudflareAccessMode
    @Binding var cloudflareClientID: String
    @Binding var cloudflareClientSecret: String
    @Binding var cloudflareTeamDomainOverride: String
    @Binding var showCloudflareOverrides: Bool
    @Binding var selectedAuthMethod: AuthMethod
    @Binding var password: String
    @Binding var sshPassphrase: String
    private let keyInput: () -> KeyInput

    init(
        transportSelection: Binding<ServerTransportSelection>,
        selectedCloudflareAccessMode: Binding<CloudflareAccessMode>,
        cloudflareClientID: Binding<String>,
        cloudflareClientSecret: Binding<String>,
        cloudflareTeamDomainOverride: Binding<String>,
        showCloudflareOverrides: Binding<Bool>,
        selectedAuthMethod: Binding<AuthMethod>,
        password: Binding<String>,
        sshPassphrase: Binding<String>,
        @ViewBuilder keyInput: @escaping () -> KeyInput
    ) {
        _transportSelection = transportSelection
        _selectedCloudflareAccessMode = selectedCloudflareAccessMode
        _cloudflareClientID = cloudflareClientID
        _cloudflareClientSecret = cloudflareClientSecret
        _cloudflareTeamDomainOverride = cloudflareTeamDomainOverride
        _showCloudflareOverrides = showCloudflareOverrides
        _selectedAuthMethod = selectedAuthMethod
        _password = password
        _sshPassphrase = sshPassphrase
        self.keyInput = keyInput
    }

    var body: some View {
        Section {
            Picker("Transport", selection: $transportSelection) {
                ForEach(ServerTransportSelection.allCases) { transport in
                    Label(transport.displayName, systemImage: transport.icon)
                        .tag(transport)
                }
            }

            if transportSelection == .cloudflare {
                cloudflareAccessFields
            }

            if transportSelection != .tailscale {
                authMethodFields
            } else {
                Text(String(localized: "Uses server-side Tailscale SSH policy. No password or SSH key is required."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Authentication")
        }
    }

    @ViewBuilder
    private var cloudflareAccessFields: some View {
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

    @ViewBuilder
    private var authMethodFields: some View {
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
            keyInput()

        case .sshKeyWithPassphrase:
            keyInput()
            SecureField("Key Passphrase", text: $sshPassphrase, prompt: Text(String(localized: "Optional")))
        }
    }
}

struct ServerFormConnectionSection<Footer: View>: View {
    let isTestingConnection: Bool
    let isDisabled: Bool
    let onTestConnection: () -> Void
    private let footer: () -> Footer

    init(
        isTestingConnection: Bool,
        isDisabled: Bool,
        onTestConnection: @escaping () -> Void,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.isTestingConnection = isTestingConnection
        self.isDisabled = isDisabled
        self.onTestConnection = onTestConnection
        self.footer = footer
    }

    var body: some View {
        Section {
            Button {
                onTestConnection()
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
            .disabled(isDisabled)
        } header: {
            sectionHeader("Connection")
        } footer: {
            footer()
        }
    }
}

struct ServerFormSessionSection: View {
    @Binding var multiplexer: TerminalMultiplexer
    @Binding var tmuxStartupBehavior: TmuxStartupBehavior

    var body: some View {
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
}

struct ServerFormSecuritySection: View {
    let biometryDisplayName: String
    let isBiometryAvailable: Bool
    let biometryAvailabilityMessage: String?
    @Binding var requiresBiometricUnlock: Bool

    var body: some View {
        Section {
            Toggle(
                String(format: String(localized: "Require %@ to open this server"), biometryDisplayName),
                isOn: $requiresBiometricUnlock
            )
            .disabled(!isBiometryAvailable && !requiresBiometricUnlock)

            if !isBiometryAvailable,
               let biometryAvailabilityMessage {
                Text(biometryAvailabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Security")
        }
    }
}

struct ServerFormNotesSection: View {
    @Binding var notes: String

    var body: some View {
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
