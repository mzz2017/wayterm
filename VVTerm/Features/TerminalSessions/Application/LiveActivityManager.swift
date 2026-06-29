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

#if os(iOS)
@available(iOS 16.1, *)
@MainActor
private struct TerminalLiveActivityHandle: @unchecked Sendable {
    // ActivityKit's Activity handle is used only through LiveActivityManager's
    // MainActor-owned lifecycle, but its async update/end APIs are @concurrent.
    nonisolated(unsafe) private let activity: Activity<VVTermActivityAttributes>

    init(_ activity: Activity<VVTermActivityAttributes>) {
        self.activity = activity
    }

    static var existingActivities: [TerminalLiveActivityHandle] {
        Activity<VVTermActivityAttributes>.activities.map(TerminalLiveActivityHandle.init)
    }

    static func request(
        attributes: VVTermActivityAttributes,
        contentState: VVTermActivityAttributes.ContentState
    ) throws -> TerminalLiveActivityHandle {
        let activity = try Activity.request(
            attributes: attributes,
            contentState: contentState,
            pushType: nil
        )
        return TerminalLiveActivityHandle(activity)
    }

    func update(using state: VVTermActivityAttributes.ContentState) async {
        await activity.update(using: state)
    }

    func endImmediately() async {
        await activity.end(dismissalPolicy: .immediate)
    }
}
#endif

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
    private var activity: TerminalLiveActivityHandle?

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
                activity = try TerminalLiveActivityHandle.request(
                    attributes: attributes,
                    contentState: newState
                )
                lastState = newState
            } catch {
                logger.error("Failed to start Live Activity: \(String(describing: error))")
            }
            return
        }

        guard newState != lastState else { return }
        let activityToUpdate = activity
        await activityToUpdate?.update(using: newState)
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
        let existing = TerminalLiveActivityHandle.existingActivities
        guard let current = existing.first else { return }
        activity = current

        if existing.count > 1 {
            for duplicate in existing.dropFirst() {
                await duplicate.endImmediately()
            }
        }
    }

    @available(iOS 16.1, *)
    private func endAllActivities(requestID: UUID) async {
        guard isCurrentRefresh(requestID) else { return }
        let existing = TerminalLiveActivityHandle.existingActivities
        for activity in existing {
            guard isCurrentRefresh(requestID) else { return }
            await activity.endImmediately()
        }
        guard isCurrentRefresh(requestID) else { return }
        self.activity = nil
        lastState = nil
    }
    #endif
}
