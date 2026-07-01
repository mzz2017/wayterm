import SwiftUI

// MARK: - Server Sidebar Support Views

struct ServerSidebarSupportBanner: View {
    let onUpgrade: () -> Void

    var body: some View {
        Button {
            onUpgrade()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Upgrade to Pro")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(verbatim: "\u{2022}")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text("Support Waterm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08))
    }
}

struct ServerSidebarFooterButtons: View {
    let canAddServer: Bool
    let onAddServer: () -> Void
    let onShowSupport: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onAddServer()
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .disabled(!canAddServer)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Spacer()

            Button {
                onShowSupport()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .help("Support & Feedback")

            Button {
                onShowSettings()
            } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Settings")
        }
    }
}
