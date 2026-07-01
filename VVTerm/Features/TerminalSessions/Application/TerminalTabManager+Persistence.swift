import Foundation
import os.log

extension TerminalTabManager {
    private func makeServerSnapshots() -> [TerminalTabsSnapshot.ServerSnapshot] {
        tabsByServer.map { serverId, tabs in
            TerminalTabsSnapshot.ServerSnapshot(
                serverId: serverId,
                tabs: tabs.map { TerminalTabsSnapshot.TabSnapshot(from: $0, paneStates: paneStates) },
                selectedTabId: selectedTabByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }
    }

    private func makeSnapshot() -> TerminalTabsSnapshot {
        TerminalTabsSnapshot(servers: makeServerSnapshots())
    }

    private func applyRestoredSnapshot(_ snapshot: TerminalTabsSnapshot) {
        let plan = TerminalTabsSnapshotRestorePlanner.plan(
            from: snapshot,
            isTmuxEnabled: { [tmuxResolver] serverId in
                tmuxResolver.isTmuxEnabled(for: serverId)
            }
        )
        tabsByServer = plan.tabsByServer
        selectedTabByServer = plan.selectedTabByServer
        selectedViewByServer = plan.selectedViewByServer
        paneStates = plan.paneStates
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
            logger.error("Failed to persist tabs snapshot: \(error.localizedDescription)")
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
            logger.error("Failed to restore tabs snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}
