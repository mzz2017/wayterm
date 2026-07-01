//
//  ConnectionSessionsSnapshot.swift
//  Waterm
//
//  Codable persistence snapshots for connection sessions.
//

import Foundation

nonisolated struct ConnectionSessionsSnapshot: Codable {
    nonisolated struct SessionSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let lastActivity: Date
        let autoReconnect: Bool
        let parentSessionId: UUID?
        let workingDirectory: String?
        let presentationOverrides: TerminalPresentationOverrides?

        init(from session: ConnectionSession) {
            self.id = session.id
            self.serverId = session.serverId
            self.title = session.title
            self.createdAt = session.createdAt
            self.lastActivity = session.lastActivity
            self.autoReconnect = session.autoReconnect
            self.parentSessionId = session.parentSessionId
            self.workingDirectory = session.workingDirectory
            self.presentationOverrides = session.presentationOverrides.isEmpty ? nil : session.presentationOverrides
        }

        func toSession() -> ConnectionSession {
            ConnectionSession(
                id: id,
                serverId: serverId,
                title: title,
                connectionState: .disconnected,
                createdAt: createdAt,
                lastActivity: lastActivity,
                terminalSurfaceId: nil,
                autoReconnect: autoReconnect,
                workingDirectory: workingDirectory,
                presentationOverrides: presentationOverrides ?? .empty,
                parentSessionId: parentSessionId
            )
        }
    }

    nonisolated struct ServerSnapshot: Codable {
        let serverId: UUID
        let selectedSessionId: UUID?
        let selectedView: String?
    }

    let sessions: [SessionSnapshot]
    let selectedSessionId: UUID?
    let serverSelections: [ServerSnapshot]
}
