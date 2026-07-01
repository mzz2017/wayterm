import Foundation
import os.log

extension ConnectionSessionManager {
    private func makeServerSnapshots() -> [ConnectionSessionsSnapshot.ServerSnapshot] {
        Set(sessions.map(\.serverId)).map { serverId in
            ConnectionSessionsSnapshot.ServerSnapshot(
                serverId: serverId,
                selectedSessionId: selectedSessionByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }
    }

    private func makeSnapshot() -> ConnectionSessionsSnapshot {
        ConnectionSessionsSnapshot(
            sessions: sessions.map { ConnectionSessionsSnapshot.SessionSnapshot(from: $0) },
            selectedSessionId: selectedSessionId,
            serverSelections: makeServerSnapshots()
        )
    }

    private func applyRestoredSnapshot(_ snapshot: ConnectionSessionsSnapshot) {
        var restoredSessions = snapshot.sessions.map { $0.toSession() }
        for index in restoredSessions.indices {
            let serverId = restoredSessions[index].serverId
            if !tmuxResolver.isTmuxEnabled(for: serverId) {
                restoredSessions[index].tmuxStatus = .off
            }
        }

        sessions = restoredSessions
        selectedSessionId = snapshot.selectedSessionId
        selectedSessionByServer = Dictionary(
            uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                guard let selected = snapshot.selectedSessionId else { return nil }
                return (snapshot.serverId, selected)
            }
        )
        selectedViewByServer = Dictionary(
            uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                guard let view = snapshot.selectedView else { return nil }
                return (snapshot.serverId, view)
            }
        )
    }

    func schedulePersist() {
        guard !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                self?.persistSnapshot()
            }
        }
    }

    private func persistSnapshot() {
        do {
            try snapshotStore.save(makeSnapshot())
        } catch {
            logger.error("Failed to persist session snapshot: \(error.localizedDescription)")
        }
    }

    func flushPendingSnapshotPersistence() {
        persistTask?.cancel()
        persistTask = nil
        persistSnapshot()
    }

    func restoreSnapshot() {
        do {
            guard let snapshot = try snapshotStore.load() else { return }
            isRestoring = true
            applyRestoredSnapshot(snapshot)
        } catch {
            logger.error("Failed to restore session snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}
