//
//  SSHConnectionOperationService.swift
//  VVTerm
//
//  Reusable SSH connection operation orchestration.
//

import Foundation

actor SSHConnectionOperationService {
    static let shared = SSHConnectionOperationService()

    private init() {}

    func runWithConnection<T: Sendable>(
        using client: SSHClient,
        target: SSHConnectionTarget,
        credentials: ServerCredentials,
        disconnectWhenDone: Bool = false,
        operation: @Sendable @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        do {
            _ = try await client.connect(to: target, credentials: credentials)
            let result = try await operation(client)
            if disconnectWhenDone {
                await client.disconnect()
            }
            return result
        } catch {
            if disconnectWhenDone {
                await client.disconnect()
            }
            throw error
        }
    }

    func withTemporaryConnection<T: Sendable>(
        target: SSHConnectionTarget,
        credentials: ServerCredentials,
        operation: @Sendable @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        let client = SSHClient()
        return try await runWithConnection(
            using: client,
            target: target,
            credentials: credentials,
            disconnectWhenDone: true,
            operation: operation
        )
    }
}
