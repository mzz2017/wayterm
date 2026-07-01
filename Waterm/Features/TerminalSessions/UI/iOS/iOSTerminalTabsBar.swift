import SwiftUI

#if os(iOS)
struct iOSTerminalTabsBar: View {
    let sessions: [ConnectionSession]
    @Binding var selectedSessionId: UUID?
    let titleForSession: (ConnectionSession) -> String
    let onClose: (ConnectionSession) -> Void
    private let minTabWidth: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            let count = max(sessions.count, 1)
            let availableWidth = max(proxy.size.width - ServerViewTopTabBarMetrics.horizontalPadding * 2, 0)
            let totalSpacing = ServerViewTopTabBarMetrics.tabSpacing * CGFloat(max(count - 1, 0))
            let itemWidth = count > 0 ? (availableWidth - totalSpacing) / CGFloat(count) : 0
            let useEqualWidth = itemWidth >= minTabWidth

            Group {
                if useEqualWidth {
                    HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                        ForEach(sessions) { session in
                            iOSTerminalTabButton(
                                session: session,
                                title: titleForSession(session),
                                isSelected: selectedSessionId == session.id,
                                fixedWidth: itemWidth,
                                onSelect: { selectedSessionId = session.id },
                                onClose: { onClose(session) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                    .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                            ForEach(sessions) { session in
                                iOSTerminalTabButton(
                                    session: session,
                                    title: titleForSession(session),
                                    isSelected: selectedSessionId == session.id,
                                    fixedWidth: nil,
                                    onSelect: { selectedSessionId = session.id },
                                    onClose: { onClose(session) }
                                )
                                .frame(minWidth: minTabWidth)
                            }
                        }
                        .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                        .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                        .animation(nil, value: sessions.map(\.id))
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(height: ServerViewTopTabBarMetrics.barHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(Capsule(style: .continuous))
        .padding(.horizontal, ServerViewTopTabBarMetrics.outerHorizontalPadding)
        .padding(.vertical, 6)
    }
}

private struct iOSTerminalTabButton: View {
    let session: ConnectionSession
    let title: String
    let isSelected: Bool
    let fixedWidth: CGFloat?
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 36)
        .padding(.vertical, ServerViewTopTabBarMetrics.tabVerticalPadding)
        .frame(height: ServerViewTopTabBarMetrics.tabHeight)
        .frame(width: fixedWidth, alignment: .leading)
        .foregroundStyle(.primary)
        .background(
            isSelected ? Color.primary.opacity(0.18) : Color.clear,
            in: Capsule(style: .continuous)
        )
        .overlay(alignment: .trailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isSelected ? 0.16 : 0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .idle: return .secondary
        case .failed: return .red
        }
    }
}
#endif
