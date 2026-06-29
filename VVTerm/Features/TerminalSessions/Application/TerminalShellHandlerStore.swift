//
//  TerminalShellHandlerStore.swift
//  VVTerm
//
//  Session-scoped shell cancel and suspend handler indexing.
//

import Foundation

nonisolated struct TerminalShellHandlerStore {
    typealias CancelHandler = @MainActor (_ mode: ShellTeardownMode) async -> Void
    typealias SuspendHandler = @MainActor () async -> Void

    private var cancelHandlers: [UUID: CancelHandler] = [:]
    private var suspendHandlers: [UUID: SuspendHandler] = [:]

    var isEmpty: Bool {
        cancelHandlers.isEmpty && suspendHandlers.isEmpty
    }

    func suspendHandler(for sessionID: UUID) -> SuspendHandler? {
        suspendHandlers[sessionID]
    }

    mutating func registerCancelHandler(
        _ handler: @escaping CancelHandler,
        for sessionID: UUID
    ) {
        cancelHandlers[sessionID] = handler
    }

    mutating func unregisterCancelHandler(for sessionID: UUID) {
        cancelHandlers.removeValue(forKey: sessionID)
    }

    mutating func registerSuspendHandler(
        _ handler: @escaping SuspendHandler,
        for sessionID: UUID
    ) {
        suspendHandlers[sessionID] = handler
    }

    mutating func unregisterSuspendHandler(for sessionID: UUID) {
        suspendHandlers.removeValue(forKey: sessionID)
    }

    @discardableResult
    mutating func takeCancelHandler(for sessionID: UUID) -> CancelHandler? {
        let handler = cancelHandlers.removeValue(forKey: sessionID)
        suspendHandlers.removeValue(forKey: sessionID)
        return handler
    }

    mutating func removeAll() {
        cancelHandlers.removeAll()
        suspendHandlers.removeAll()
    }
}
