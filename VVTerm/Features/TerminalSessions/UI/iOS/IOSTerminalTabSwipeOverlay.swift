import SwiftUI
#if os(iOS)
import UIKit

struct IOSTerminalTabSwipeOverlay: View {
    let selectedView: String
    let serverSessions: [ConnectionSession]
    let fileTabServerId: UUID?
    @Binding var selectedSessionId: UUID?
    @ObservedObject var fileTabs: RemoteFileTabManager

    private var shouldShowOverlay: Bool {
        (selectedView == ConnectionViewTab.terminal.id && serverSessions.count > 1)
            || (selectedView == ConnectionViewTab.files.id && selectedFileTabCount > 1)
    }

    private var selectedFileTabCount: Int {
        guard let fileTabServerId else { return 0 }
        return fileTabs.tabs(for: fileTabServerId).count
    }

    var body: some View {
        if shouldShowOverlay {
            GeometryReader { _ in
                let edgeWidth: CGFloat = 32
                let leadingGestureInset: CGFloat = selectedView == ConnectionViewTab.files.id ? 44 : 0
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: leadingGestureInset)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture)

                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture)
                }
            }
        }
    }

    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical),
                      abs(horizontal) > 60 else { return }
                if horizontal < 0 {
                    selectNextTab()
                } else {
                    selectPreviousTab()
                }
            }
    }

    private func selectNextTab() {
        if selectedView == ConnectionViewTab.files.id {
            guard let fileTabServerId else { return }
            fileTabs.selectNextTab(for: fileTabServerId)
        } else {
            guard let currentId = selectedSessionId,
                  let index = serverSessions.firstIndex(where: { $0.id == currentId }),
                  index < serverSessions.count - 1 else { return }
            selectedSessionId = serverSessions[index + 1].id
        }
        triggerTabSwitchFeedback()
    }

    private func selectPreviousTab() {
        if selectedView == ConnectionViewTab.files.id {
            guard let fileTabServerId else { return }
            fileTabs.selectPreviousTab(for: fileTabServerId)
        } else {
            guard let currentId = selectedSessionId,
                  let index = serverSessions.firstIndex(where: { $0.id == currentId }),
                  index > 0 else { return }
            selectedSessionId = serverSessions[index - 1].id
        }
        triggerTabSwitchFeedback()
    }

    private func triggerTabSwitchFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}

#endif
