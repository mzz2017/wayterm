//
//  TerminalTabManagerSupport.swift
//  VVTerm
//
//  Terminal tab manager support state and request values.
//

import Foundation

enum TerminalTabManagerSupport {
    struct PaneCloseResult: Sendable {
        let paneId: UUID
        let tmuxSessionNameToKill: String?
        let richPasteUploadTasks: [Task<Void, Never>]
    }

    struct TabCloseResult: Sendable {
        let serverId: UUID
        let paneCloseResults: [PaneCloseResult]
    }

    struct TmuxInstallRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor () -> Void]
    }

    struct TmuxLifecycleRequest {
        let paneId: UUID
        let serverId: UUID
        let shellId: UUID
        let task: Task<Void, Never>
    }

    struct MoshInstallRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor () -> Void]
        var onFailed: [@MainActor (Error) -> Void]
    }

    struct PaneRetryRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (TerminalReconnectRequestResult) -> Void]
    }

    struct PaneHostRetrustRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (Bool) -> Void]
    }

    struct PaneCredentialLoadRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (TerminalCredentialLoadResult) -> Void]
    }

    struct SurfaceAttachRequest {
        let paneId: UUID
        var context: TerminalSurfaceAttachContext
        let task: Task<Void, Never>
    }

    struct InputRequest {
        let paneId: UUID
        let task: Task<Void, Never>
    }

    struct RichPasteUploadRequest {
        let paneId: UUID
        let task: Task<Void, Never>
    }

    struct ResizeRequest {
        let paneId: UUID
        var size: TerminalResizeRequestSize
        let task: Task<Void, Never>
    }

    struct ProcessExitRequest {
        let paneId: UUID
        let task: Task<Void, Never>
    }

    final class PaneRuntimeState {
        let paneId: UUID
        var server: Server
        var credentials: ServerCredentials
        let runtime: TerminalConnectionRuntime
        var onProcessExit: () -> Void

        init(
            paneId: UUID,
            server: Server,
            credentials: ServerCredentials,
            runtime: TerminalConnectionRuntime,
            onProcessExit: @escaping () -> Void
        ) {
            self.paneId = paneId
            self.server = server
            self.credentials = credentials
            self.runtime = runtime
            self.onProcessExit = onProcessExit
        }
    }
}
