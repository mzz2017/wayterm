#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct WatermLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WatermActivityAttributes.self) { context in
            WatermLiveActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        AppIconView(size: 20)
                        Text(String(localized: "Waterm"))
                            .font(.headline)
                        StatusDot(status: context.state.status)
                    }
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        Text(context.state.activeCount, format: .number)
                            .font(.headline)
                        Text(String(localized: "active"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                }
            } compactLeading: {
                AppIconView(size: 16)
            } compactTrailing: {
                Text(context.state.activeCount, format: .number)
                    .font(.caption)
            } minimal: {
                AppIconView(size: 16)
            }
        }
    }
}

@available(iOS 16.1, *)
private struct WatermLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WatermActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(String(localized: "Waterm"))
                        .font(.headline)
                    StatusDot(status: context.state.status)
                }
                Text(sessionCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var sessionCountLabel: String {
        if context.state.activeCount == 1 {
            return String(localized: "1 active session")
        }
        return String(format: String(localized: "%lld active sessions"), Int64(context.state.activeCount))
    }
}

@available(iOS 16.1, *)
private struct StatusDot: View {
    let status: WatermLiveActivityStatus

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .reconnecting:
            return .yellow
        case .disconnected:
            return .gray
        }
    }
}

@available(iOS 16.1, *)
private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        iconImage
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    @ViewBuilder
    private var iconImage: some View {
        Image("WatermLiveIcon")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
    }
}
#endif
