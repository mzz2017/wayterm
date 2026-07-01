//
//  SSHPendingConnectCoordinator.swift
//  Waterm
//
//  Pending SSH connect request/session lifecycle ownership.
//

import Foundation

nonisolated final class SSHPendingConnectCoordinator {
    struct DisconnectSnapshot {
        let task: Task<SSHSession, Error>?
        let session: SSHSession?

        var shouldWaitForPendingSessionCleanup: Bool {
            session != nil
        }
    }

    private var task: Task<SSHSession, Error>?
    private var session: SSHSession?
    private var requestID: UUID?

    var currentTask: Task<SSHSession, Error>? {
        task
    }

    func begin(requestID: UUID) {
        self.requestID = requestID
        task = nil
        session = nil
    }

    func begin(requestID: UUID, task: Task<SSHSession, Error>) {
        begin(requestID: requestID)
        attachTask(task, requestID: requestID)
    }

    func attachTask(_ task: Task<SSHSession, Error>, requestID: UUID) {
        guard isCurrentRequest(requestID) else {
            task.cancel()
            return
        }
        self.task = task
    }

    @discardableResult
    func register(_ pendingSession: SSHSession, requestID: UUID) -> Bool {
        guard isCurrentRequest(requestID) else {
            return false
        }
        session = pendingSession
        return true
    }

    func isCurrentRequest(_ requestID: UUID) -> Bool {
        self.requestID == requestID
    }

    func isCurrentSession(_ pendingSession: SSHSession) -> Bool {
        guard let session else { return false }
        return ObjectIdentifier(session) == ObjectIdentifier(pendingSession)
    }

    func clearSessionIfCurrent(_ pendingSession: SSHSession) {
        guard isCurrentSession(pendingSession) else { return }
        session = nil
    }

    func clearRequestIfCurrent(_ requestID: UUID) {
        guard isCurrentRequest(requestID) else { return }
        self.requestID = nil
    }

    func clearAll() {
        task = nil
        session = nil
        requestID = nil
    }

    func cancelForDisconnect() -> DisconnectSnapshot {
        let snapshot = DisconnectSnapshot(task: task, session: session)
        task = nil
        session = nil
        requestID = nil
        snapshot.task?.cancel()
        snapshot.session?.abort()
        return snapshot
    }
}
