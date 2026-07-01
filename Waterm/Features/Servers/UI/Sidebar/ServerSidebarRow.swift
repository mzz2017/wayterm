import SwiftUI

struct ServerRowDisplayModel: Identifiable {
    let id: UUID
    let name: String
    let host: String
    let environmentColor: Color
    let environmentShortName: String
}

struct ServerRow: View {
    let model: ServerRowDisplayModel
    let isSelected: Bool
    let isLocked: Bool
    let tabCount: Int
    let onSelect: () -> Void
    let onEdit: () -> Void
    var onMove: (() -> Void)? = nil
    let onConnect: () -> Void
    let onDelete: () -> Void
    var onLockedTap: (() -> Void)? = nil

    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private var selectedForegroundColor: Color {
        #if os(macOS)
        controlActiveState == .key ? .accentColor : .accentColor.opacity(0.78)
        #else
        .accentColor
        #endif
    }

    private var selectionFillColor: Color {
        #if os(macOS)
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
        #else
        return Color.primary.opacity(0.10)
        #endif
    }

    private var sessionIndicatorColor: Color {
        isSelected ? selectedForegroundColor.opacity(0.9) : .secondary
    }

    var body: some View {
        serverLabel
            .background(selectionBackground)
            .opacity(isLocked ? 0.7 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture {
                if isLocked {
                    onLockedTap?()
                } else {
                    onSelect()
                }
            }
            .contextMenu {
                if isLocked {
                    Button {
                        onLockedTap?()
                    } label: {
                        Label("Unlock with Pro", systemImage: "lock.open.fill")
                    }
                    if let onMove {
                        Button { onMove() } label: {
                            Label("Move to Workspace", systemImage: "arrow.turn.right.up")
                        }
                    }
                    Button { onEdit() } label: {
                        Label("Server Settings", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                } else {
                    Button {
                        onConnect()
                    } label: {
                        Label("Open Connection", systemImage: "point.forward.to.point.capsulepath.fill")
                    }
                    if let onMove {
                        Button { onMove() } label: {
                            Label("Move to Workspace", systemImage: "arrow.turn.right.up")
                        }
                    }
                    Button { onEdit() } label: {
                        Label("Server Settings", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                }
            }
    }

    private var serverLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "server.rack")
                    .foregroundStyle(isSelected ? selectedForegroundColor : .secondary)
                    .imageScale(.medium)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedForegroundColor : Color.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(model.host)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Circle()
                        .fill(model.environmentColor)
                        .frame(width: 6, height: 6)

                    Text(model.environmentShortName)
                        .font(.caption2)
                        .foregroundStyle(model.environmentColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isLocked {
                LockedBadge()
            } else if tabCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(tabCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(sessionIndicatorColor)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(selectionFillColor)
        }
    }
}
