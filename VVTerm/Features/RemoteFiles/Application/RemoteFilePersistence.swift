import Combine
import Foundation

extension RemoteFileBrowserStore {
    func loadPersistedStates() {
        guard let decoded = try? persistedStateStore.load() else {
            persistedStates = [:]
            return
        }
        persistedStates = decoded
    }

    func persistedState(for tabId: UUID) -> RemoteFileBrowserPersistedState {
        persistedStates[tabId.uuidString] ?? .init()
    }

    func persistState(for tabId: UUID) {
        let fallback = persistedState(for: tabId)
        let state = states[tabId]
        persistedStates[tabId.uuidString] = RemoteFileBrowserPersistedState(
            lastVisitedPath: state?.currentPath ?? fallback.lastVisitedPath,
            sort: state?.sort ?? fallback.sort,
            sortDirection: state?.sortDirection ?? fallback.sortDirection,
            showHiddenFiles: state?.showHiddenFiles ?? fallback.showHiddenFiles,
            hasCustomizedHiddenFiles: state?.hasCustomizedHiddenFiles ?? fallback.hasCustomizedHiddenFiles
        )
        persistStates()
    }

    func persistStates() {
        try? persistedStateStore.save(persistedStates)
    }
}
