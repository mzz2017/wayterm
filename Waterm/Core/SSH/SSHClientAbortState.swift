//
//  SSHClientAbortState.swift
//  Waterm
//
//  Thread-safe abort state shared across SSHClient isolation boundaries.
//

import Foundation

nonisolated final class SSHClientAbortState: @unchecked Sendable {
    private let lock = NSLock()
    private var aborted = false
    private var sessionForAbort: SSHSession?

    var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    func reset() {
        lock.lock()
        aborted = false
        lock.unlock()
    }

    func setSessionForAbort(_ session: SSHSession?) {
        lock.lock()
        sessionForAbort = session
        lock.unlock()
    }

    func abort() {
        lock.lock()
        aborted = true
        let session = sessionForAbort
        lock.unlock()
        session?.abort()
    }
}
