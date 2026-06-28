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
            refreshTask?.cancel()
            let requestID = UUID()
            refreshRequestID = requestID
            refreshTask = Task { @MainActor [self] in
                await updateActivity(for: snapshots, requestID: requestID)
                if refreshRequestID == requestID {
                    refreshTask = nil
                    refreshRequestID = nil
                }
            }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private var activity: Activity<VVTermActivityAttributes>?

    @available(iOS 16.1, *)
    private var lastState: VVTermActivityAttributes.ContentState?

    @available(iOS 16.1, *)
    private var refreshTask: Task<Void, Never>?

    @available(iOS 16.1, *)
    private var refreshRequestID: UUID?

    @available(iOS 16.1, *)
    private func updateActivity(for snapshots: [TerminalLiveActivitySnapshot], requestID: UUID) async {
        guard isCurrentRefresh(requestID) else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities(requestID: requestID)
            return
        }

        let activeCount = snapshots.count
        if activeCount == 0 {
            await endAllActivities(requestID: requestID)
            return
        }

        await attachToExistingActivityIfNeeded()
        guard isCurrentRefresh(requestID) else { return }

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
        guard isCurrentRefresh(requestID) else { return }
        lastState = newState
    }

    @available(iOS 16.1, *)
    private func isCurrentRefresh(_ requestID: UUID) -> Bool {
        refreshRequestID == requestID && !Task.isCancelled
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
    private func endAllActivities(requestID: UUID) async {
        guard isCurrentRefresh(requestID) else { return }
        let existing = Activity<VVTermActivityAttributes>.activities
        for activity in existing {
            guard isCurrentRefresh(requestID) else { return }
            await activity.end(dismissalPolicy: .immediate)
        }
        guard isCurrentRefresh(requestID) else { return }
        self.activity = nil
        lastState = nil
    }
    #endif
}
