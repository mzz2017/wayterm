import SwiftUI

#if os(iOS)

struct IOSTerminalFloatingControls: View {
    let showsReturnButton: Bool
    let showsVoiceButton: Bool
    let colorScheme: ColorScheme
    let onKeyboard: () -> Void
    let onVoiceInput: () -> Void
    let onReturn: () -> Void

    var body: some View {
        if showsReturnButton {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    keyboardVoiceControls(showsTitle: true)
                    Spacer(minLength: 14)
                    returnControl
                }

                HStack(spacing: 10) {
                    keyboardVoiceControls(showsTitle: false)
                    Spacer(minLength: 14)
                    returnControl
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    keyboardVoiceControls(showsTitle: true)
                }

                HStack(spacing: 10) {
                    keyboardVoiceControls(showsTitle: false)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func keyboardVoiceControls(showsTitle: Bool) -> some View {
        HStack(spacing: 10) {
            keyboardControl(showsTitle: showsTitle)
            if showsVoiceButton {
                voiceControl(showsTitle: showsTitle)
            }
        }
    }

    @ViewBuilder
    private func keyboardControl(showsTitle: Bool) -> some View {
        controlButton(
            title: "Keyboard",
            systemImage: "keyboard",
            accessibilityLabel: "Show Keyboard",
            showsTitle: showsTitle,
            action: onKeyboard
        )
    }

    @ViewBuilder
    private func voiceControl(showsTitle: Bool) -> some View {
        controlButton(
            title: "Voice input",
            systemImage: "mic.fill",
            accessibilityLabel: "Voice input",
            showsTitle: showsTitle,
            action: onVoiceInput
        )
    }

    private var returnControl: some View {
        controlButton(
            title: "Enter",
            systemImage: "arrow.turn.down.left",
            accessibilityLabel: "Enter",
            showsTitle: false,
            isPrimary: true,
            action: onReturn
        )
    }

    @ViewBuilder
    private func controlButton(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        showsTitle: Bool,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            HStack(spacing: showsTitle ? 6 : 0) {
                Image(systemName: systemImage)
                if showsTitle {
                    Text(title)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(isPrimary ? Color.accentColor : Color.primary)
            .padding(.horizontal, showsTitle ? 2 : 0)
        }
        .accessibilityLabel(Text(accessibilityLabel))

        button
            .buttonStyle(.glass(tint: Color.accentColor.opacity(isPrimary ? 0.5 : glassOpacity)))
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }

    private var glassOpacity: Double {
        colorScheme == .dark ? 0.24 : 0.14
    }
}

struct IOSTerminalConnectingStateView: View {
    let serverName: String

    var body: some View {
        BlockingStatusView(showsScrim: false) {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                Text(String(format: String(localized: "Connecting to %@..."), serverName))
                    .font(.headline)
                Text(String(localized: "Preparing server details..."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
