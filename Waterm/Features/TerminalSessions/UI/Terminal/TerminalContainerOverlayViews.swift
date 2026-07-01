import SwiftUI

// MARK: - Terminal Container Overlay Views

struct TerminalContainerStateOverlay: View {
    let isTerminalInitializationFailed: Bool
    let shouldShowInitializingOverlay: Bool
    let shouldShowStateOverlay: Bool
    let surfaceStyle: NoticeSurfaceStyle
    let credentialLoadErrorMessage: String?
    let connectionState: ConnectionState
    let shouldUseInlineReconnectPresentation: Bool
    let tmuxStatus: TmuxStatus
    let shouldShowMoshDurabilityHint: Bool
    let isHostKeyVerificationFailure: Bool
    let onRetry: () -> Void
    let onTrustNewHostKey: () -> Void

    var body: some View {
        initializationOverlay
        stateOverlay
    }

    @ViewBuilder
    private var initializationOverlay: some View {
        if isTerminalInitializationFailed {
            BlockingStatusView(surfaceStyle: surfaceStyle) {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Terminal initialization failed")
                        .foregroundStyle(.red)
                }
                .multilineTextAlignment(.center)
            }
        } else if shouldShowInitializingOverlay {
            BlockingStatusView(showsScrim: false, surfaceStyle: surfaceStyle) {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Initializing terminal...")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if shouldShowStateOverlay {
            if let credentialLoadErrorMessage {
                credentialFailureOverlay(credentialLoadErrorMessage)
            } else {
                connectionStateOverlay
            }
        }
    }

    private func credentialFailureOverlay(_ message: String) -> some View {
        BlockingStatusView(surfaceStyle: surfaceStyle) {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Connection Failed")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var connectionStateOverlay: some View {
        switch connectionState {
        case .connecting:
            if !shouldUseInlineReconnectPresentation {
                activityOverlay(message: String(localized: "Connecting..."), foregroundStyle: .secondary)
            }
        case .reconnecting:
            if !shouldUseInlineReconnectPresentation {
                activityOverlay(message: String(localized: "Reconnecting..."), foregroundStyle: .orange)
            }
        case .disconnected:
            disconnectedOverlay
        case .failed(let error):
            failedOverlay(error)
        case .connected, .idle:
            EmptyView()
        }
    }

    private func activityOverlay(message: String, foregroundStyle: Color) -> some View {
        BlockingStatusView(showsScrim: false, surfaceStyle: surfaceStyle) {
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text(message)
                    .foregroundStyle(foregroundStyle)
            }
            .padding(.vertical, 6)
            .multilineTextAlignment(.center)
        }
    }

    private var disconnectedOverlay: some View {
        BlockingStatusView(surfaceStyle: surfaceStyle) {
            VStack(spacing: 16) {
                Image(systemName: "bolt.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Disconnected")
                    .foregroundStyle(.secondary)
                if tmuxStatus.indicatesTmux {
                    Text("tmux session is still running on the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if shouldShowMoshDurabilityHint {
                    Text("Without tmux, app backgrounding can interrupt running commands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Reconnect") {
                    onRetry()
                }
                .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
        }
    }

    private func failedOverlay(_ error: String) -> some View {
        BlockingStatusView(showsScrim: false, surfaceStyle: surfaceStyle) {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Connection Failed")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if isHostKeyVerificationFailure {
                    Button("Trust New Host Key") {
                        onTrustNewHostKey()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
        }
    }
}

#if os(macOS) || os(iOS)
struct TerminalContainerVoiceOverlayLayer: View {
    @ObservedObject var voiceInput: TerminalVoiceInputStore
    let target: TerminalVoiceInputTarget
    let isConnected: Bool
    let isReady: Bool
    let isRecording: Bool
    let isVoiceButtonEnabled: Bool
    let bottomInset: CGFloat
    let onStart: () -> Void
    let onSend: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        #if os(macOS)
        if isConnected && isReady {
            if isRecording {
                voiceOverlay
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isVoiceButtonEnabled {
                voiceTriggerButton
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }
        }
        #endif

        #if os(iOS)
        if isConnected && isReady && isRecording {
            voiceOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 16)
                .padding(.bottom, bottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
        }
        #endif
    }

    private var voiceOverlay: some View {
        VoiceRecordingView(
            voiceInput: voiceInput,
            target: target,
            onSend: onSend,
            onCancel: onCancel
        )
    }

    #if os(macOS)
    private var voiceTriggerButton: some View {
        Button {
            onStart()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Voice input (Command+Shift+M)"))
        .padding(14)
    }
    #endif
}
#endif

struct TerminalEmptyStateView: View {
    let server: Server?
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(server?.name ?? String(localized: "Terminal"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("No terminals open")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onNewTerminal) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Terminal")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
