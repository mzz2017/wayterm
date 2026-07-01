import Foundation

struct RemoteFileDirectoryLoadRequestCoordinator {
    private var requestByTab: [UUID: UUID] = [:]

    mutating func beginRequest(for tabId: UUID) -> UUID {
        let requestID = UUID()
        requestByTab[tabId] = requestID
        return requestID
    }

    func isCurrent(_ requestID: UUID, for tabId: UUID) -> Bool {
        requestByTab[tabId] == requestID
    }

    mutating func clearRequest(for tabId: UUID) {
        requestByTab.removeValue(forKey: tabId)
    }

    mutating func clearAll() {
        requestByTab.removeAll()
    }
}
