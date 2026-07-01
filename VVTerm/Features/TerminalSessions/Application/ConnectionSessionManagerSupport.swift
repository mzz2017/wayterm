//
//  ConnectionSessionManagerSupport.swift
//  VVTerm
//
//  Connection session manager support state and request values.
//

import Foundation

enum ConnectionSessionManagerSupport {
    struct SSHUnregisterResult: Sendable {
        let shellToClose: (client: SSHClient, shellId: UUID)?
        let clientToDisconnect: SSHClient?
    }

    struct SessionCloseResult {
        let sessionId: UUID
        let serverId: UUID
        let tmuxSessionNameToKill: String?
        let tmuxSessionMultiplexerToKill: TerminalMultiplexer?
        let voiceCancelTask: Task<Void, Never>
        let richPasteUploadTasks: [Task<Void, Never>]
        let shellTeardownRequest: ShellTeardownRequest?
    }

    struct ShellTeardownRequest {
        let sessionId: UUID
        let handler: @MainActor (_ mode: ShellTeardownMode) async -> Void
    }

    struct TmuxInstallRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor () -> Void]
    }

    struct TmuxLifecycleRequest {
        let sessionId: UUID
        let serverId: UUID
        let shellId: UUID
        let task: Task<Void, Never>
    }

    struct ConnectionOpenRequest {
        let serverId: UUID
        let task: Task<Void, Never>
        var onOpened: [@MainActor (ConnectionSession) -> Void]
        var onFailed: [@MainActor (Error) -> Void]
    }

    struct MoshInstallRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor () -> Void]
        var onFailed: [@MainActor (Error) -> Void]
    }

    struct SessionRetryRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (TerminalReconnectRequestResult) -> Void]
    }

    struct ActiveConnectionOpenRequest {
        let sessionId: UUID
        var preferredViewId: String
        var task: Task<Void, Never>?
        var onOpened: [@MainActor () -> Void]
    }

    struct ForegroundReconnectRequest {
        let sessionId: UUID
        var task: Task<Void, Never>?
        var callbacks: [ForegroundReconnectCallback]
    }

    struct ForegroundReconnectCallback {
        let action: TerminalForegroundReconnectAction
        let onAction: @MainActor (TerminalForegroundReconnectAction) -> Void
    }

    struct SessionHostRetrustRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (Bool) -> Void]
    }

    struct SessionCredentialLoadRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (TerminalCredentialLoadResult) -> Void]
    }

    struct SurfaceAttachRequest {
        let sessionId: UUID
        var context: TerminalSurfaceAttachContext
        var attachOperation: @MainActor () async -> Void
        let task: Task<Void, Never>
        var generation: Int = 0
    }

    struct InputRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
    }

    struct RichPasteUploadRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
    }

    struct ResizeRequest {
        let sessionId: UUID
        var size: TerminalResizeRequestSize
        let task: Task<Void, Never>
    }

    struct ProcessExitRequest {
        let sessionId: UUID
        let task: Task<Void, Never>
    }

    final class SessionRuntimeState {
        let sessionId: UUID
        var server: Server
        var credentials: ServerCredentials
        let runtime: TerminalConnectionRuntime
        var onProcessExit: () -> Void

        init(
            sessionId: UUID,
            server: Server,
            credentials: ServerCredentials,
            runtime: TerminalConnectionRuntime,
            onProcessExit: @escaping () -> Void
        ) {
            self.sessionId = sessionId
            self.server = server
            self.credentials = credentials
            self.runtime = runtime
            self.onProcessExit = onProcessExit
        }
    }
}
