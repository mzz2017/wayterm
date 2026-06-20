import Foundation
import os.log
#if os(iOS)
import ActivityKit
#endif

struct TerminalLiveActivitySnapshot: Equatable, Sendable {
    let sessionId: UUID
    let serverId: UUID
    let state: TerminalEntityConnectionState
}

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "LiveActivity")

    private init() {}

    func refresh(with snapshots: [TerminalLiveActivitySnapshot]) {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            Task { await updateActivity(for: snapshots) }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private var activity: Activity<VVTermActivityAttributes>?

    @available(iOS 16.1, *)
    private var lastState: VVTermActivityAttributes.ContentState?

    @available(iOS 16.1, *)
    private func updateActivity(for snapshots: [TerminalLiveActivitySnapshot]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities()
            return
        }

        let activeCount = snapshots.count
        if activeCount == 0 {
            await endAllActivities()
            return
        }

        await attachToExistingActivityIfNeeded()

        let status: VVTermLiveActivityStatus
        if snapshots.contains(where: { $0.state == .reconnecting }) {
            status = .reconnecting
        } else if snapshots.contains(where: { $0.state.isOpening }) {
            status = .connecting
        } else if snapshots.contains(where: { $0.state.isConnected }) {
            status = .connected
        } else {
            status = .disconnected
        }

        let newState = VVTermActivityAttributes.ContentState(status: status, activeCount: activeCount)
        if activity == nil {
            do {
                let attributes = VVTermActivityAttributes(appName: "VVTerm")
                activity = try Activity.request(attributes: attributes, contentState: newState, pushType: nil)
                lastState = newState
            } catch {
                logger.error("Failed to start Live Activity: \(String(describing: error))")
            }
            return
        }

        guard newState != lastState else { return }
        await activity?.update(using: newState)
        lastState = newState
    }

    @available(iOS 16.1, *)
    private func attachToExistingActivityIfNeeded() async {
        guard activity == nil else { return }
        let existing = Activity<VVTermActivityAttributes>.activities
        guard let current = existing.first else { return }
        activity = current

        if existing.count > 1 {
            for duplicate in existing.dropFirst() {
                await duplicate.end(dismissalPolicy: .immediate)
            }
        }
    }

    @available(iOS 16.1, *)
    private func endAllActivities() async {
        let existing = Activity<VVTermActivityAttributes>.activities
        for activity in existing {
            await activity.end(dismissalPolicy: .immediate)
        }
        self.activity = nil
        lastState = nil
    }
    #endif
}
