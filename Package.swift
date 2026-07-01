// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatermLinuxCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "WatermIOSApplicationLogic",
            targets: [
                "WatermConnectionViewsApplicationLogic",
                "WatermIOSApplicationLogic",
                "WatermRemoteFilesApplicationLogic",
                "WatermServersApplicationLogic",
                "WatermTerminalSessionsApplicationLogic"
            ]
        )
    ],
    targets: [
        .target(
            name: "WatermRemoteFilesDomain",
            path: "Waterm/Features/RemoteFiles/Domain",
            exclude: [
                "RemoteFileBrowserError.swift",
                "RemoteFileBrowserPersistedState.swift",
                "RemoteFileBrowserState.swift",
                "RemoteFileConflictPolicy.swift",
                "RemoteFileDragPayload.swift",
                "RemoteFileEntry.swift",
                "RemoteFilePermissions.swift",
                "RemoteFilePreview.swift",
                "RemoteFileSort.swift",
                "RemoteFileTab.swift",
                "RemoteFileTabSnapshot.swift",
                "RemoteFileType.swift"
            ],
            sources: [
                "RemoteFilePath.swift"
            ]
        ),
        .target(
            name: "WatermTerminalCoreLogic",
            path: "Waterm/Core/Terminal/Logic"
        ),
        .target(
            name: "WatermSSHCoreLogic",
            path: "Waterm/Core/SSH",
            exclude: [
                "AtomicSocket.swift",
                "KnownHostsManager.swift",
                "LibSSH2SessionDriver.swift",
                "RemoteClipboardTransferService.swift",
                "RemoteCommandExecuting.swift",
                "RemoteConnectionLease.swift",
                "RemoteEnvironmentResolver.swift",
                "RemoteMoshManager.swift",
                "RemoteTmuxManager.swift",
                "RemoteTmuxManager+Commands.swift",
                "RemoteTmuxManager+WindowsPowerShell.swift",
                "RemoteTmuxSessionListParser.swift",
                "RemoteZmxCommandBuilder.swift",
                "ShellHandle.swift",
                "ShellTransport.swift",
                "SSHAuthenticationGate.swift",
                "SSHChannelCleanupTaskRegistry.swift",
                "SSHClient.swift",
                "SSHClientAbortState.swift",
                "SSHConnectionOperationService.swift",
                "SSHError.swift",
                "SSHFileTransferTypes.swift",
                "SSHKeyboardInteractiveAuth.swift",
                "SSHKeyGenerator.swift",
                "SSHMoshTeardownTaskRegistry.swift",
                "SSHPublicKeyDeriver.swift",
                "SSHRemoteFileErrorMapper.swift",
                "SSHSession.swift",
                "SSHSession+Channels.swift",
                "SSHSession+RemoteFiles.swift",
                "SSHSession+Upload.swift",
                "SSHSessionConfig.swift",
                "SSHUploadStrategy.swift",
                "TerminalRichPasteCoordinator.swift"
            ],
            sources: [
                "RemoteEnvironment.swift",
                "RemotePlatform.swift",
                "RemoteTerminalBootstrap.swift",
                "RemoteTerminalTypeResolver.swift",
                "SSHConnectionTarget.swift"
            ]
        ),
        .target(
            name: "WatermIOSApplicationLogic",
            dependencies: ["WatermRemoteFilesDomain"],
            path: "Waterm/App/iOS/Application"
        ),
        .target(
            name: "WatermConnectionViewsApplicationLogic",
            path: "Waterm/Features/ConnectionViews/Application",
            exclude: [
                "ViewTabConfigurationManager.swift"
            ],
            sources: [
                "IOSConnectionViewSelectionPolicy.swift"
            ]
        ),
        .target(
            name: "WatermRemoteFilesApplicationLogic",
            dependencies: ["WatermRemoteFilesDomain"],
            path: "Waterm/Features/RemoteFiles/Application",
            exclude: [
                "RemoteFileBrowserActions.swift",
                "RemoteFileBrowserStore.swift",
                "RemoteFileBrowserStore+DirectoryLoading.swift",
                "RemoteFileDropPolicy.swift",
                "RemoteFileInlineEditPolicy.swift",
                "RemoteFileMoveDestinationLoadCoordinator.swift",
                "RemoteFileNavigationCoordinator.swift",
                "RemoteFileNavigationRequestCoordinator.swift",
                "RemoteFilePermissionEditPolicy.swift",
                "RemoteFilePersistence.swift",
                "RemoteFilePreviewCoordinator.swift",
                "RemoteFilePreviewLoadCoordinator.swift",
                "RemoteFileRequestLifecycleCoordinator.swift",
                "RemoteFileServiceAccessCoordinator.swift",
                "RemoteFileServiceAccessing.swift",
                "RemoteFileTabManager.swift",
                "RemoteFileTabOpeningPolicy.swift",
                "RemoteFileTransferCoordinator.swift",
                "RemoteFileTransferPolicy.swift"
            ],
            sources: [
                "RemoteFileTabTitlePolicy.swift"
            ]
        ),
        .target(
            name: "WatermServersApplicationLogic",
            path: "Waterm/Features/Servers/Application",
            exclude: [
                "ServerAccessPolicy.swift",
                "ServerConnectionTester.swift",
                "ServerCredentialPersistence.swift",
                "ServerFormConnectionTestPolicy.swift",
                "ServerFormCredentialBuilder.swift",
                "ServerFormCredentialProvider.swift",
                "ServerFormSubmissionBuilder.swift",
                "ServerFormValidationPolicy.swift",
                "ServerKnownHostRemovalService.swift",
                "ServerLocalDataStore.swift",
                "ServerManager.swift",
                "ServerManager+AccessPolicy.swift",
                "ServerManager+Deletion.swift",
                "ServerManager+Environment.swift",
                "ServerManager+Move.swift",
                "ServerManager+Persistence.swift",
                "ServerManager+Queries.swift",
                "ServerManager+Requests.swift",
                "ServerManager+Sync.swift",
                "ServerManagerSyncDependencies.swift",
                "ServerMoveSupport.swift",
                "ServerSidebarPolicy.swift",
                "ServerSyncStateService.swift"
            ],
            sources: [
                "IOSServerListPolicy.swift",
                "IOSWorkspaceDeletionWarningPolicy.swift"
            ]
        ),
        .target(
            name: "WatermTerminalSessionsApplicationLogic",
            path: "Waterm/Features/TerminalSessions/Application",
            exclude: [
                "ConnectionReliabilityManager.swift",
                "ConnectionSessionManager.swift",
                "ConnectionSessionManager+Closing.swift",
                "ConnectionSessionManager+Open.swift",
                "ConnectionSessionManager+Persistence.swift",
                "ConnectionSessionManager+Reconnect.swift",
                "ConnectionSessionManager+Runtime.swift",
                "ConnectionSessionManager+TerminalIO.swift",
                "ConnectionSessionManager+TerminalSurfaces.swift",
                "ConnectionSessionManager+Testing.swift",
                "ConnectionSessionManager+Tmux.swift",
                "ConnectionSessionManager+Watchdog.swift",
                "ConnectionSessionManagerSupport.swift",
                "ConnectionSessionsSnapshot.swift",
                "LiveActivityManager.swift",
                "SSHShellRegistry.swift",
                "TerminalAutoReconnectPolicy.swift",
                "TerminalConnectWatchdogStore.swift",
                "TerminalConnectionRegistry.swift",
                "TerminalConnectionRunner.swift",
                "TerminalConnectionRuntime.swift",
                "TerminalContainerPresentationPolicy.swift",
                "TerminalMoshService.swift",
                "TerminalOpenRequestStore.swift",
                "TerminalReconnectInFlightStore.swift",
                "TerminalRichPasteUploadRequest.swift",
                "TerminalRuntimePreferencesStore.swift",
                "TerminalScopedRequestStore.swift",
                "TerminalSerialRequestStore.swift",
                "TerminalServerTaskStore.swift",
                "TerminalSessionLifecycleTypes.swift",
                "TerminalShellHandlerStore.swift",
                "TerminalSurfaceRegistry.swift",
                "TerminalTabClosePanePolicy.swift",
                "TerminalTabManager.swift",
                "TerminalTabManager+Closing.swift",
                "TerminalTabManager+Open.swift",
                "TerminalTabManager+Persistence.swift",
                "TerminalTabManager+Reconnect.swift",
                "TerminalTabManager+Runtime.swift",
                "TerminalTabManager+TerminalIO.swift",
                "TerminalTabManager+TerminalSurfaces.swift",
                "TerminalTabManager+Testing.swift",
                "TerminalTabManager+Tmux.swift",
                "TerminalTabManager+Watchdog.swift",
                "TerminalTabManagerSupport.swift",
                "TerminalTabSplitPolicy.swift",
                "TerminalTabsSnapshot.swift",
                "TerminalTabsSnapshotRestorePlanner.swift",
                "TerminalTeardownTaskStore.swift",
                "TerminalTmuxCleanupStore.swift",
                "TerminalTmuxService.swift",
                "TerminalVoiceInputStore.swift",
                "TerminalWorkingDirectoryService.swift",
                "TmuxAttachPreferences.swift",
                "TmuxAttachResolver.swift"
            ],
            sources: [
                "IOSTerminalViewPolicy.swift"
            ]
        ),
        .testTarget(
            name: "WatermTerminalCoreLogicTests",
            dependencies: [
                "WatermTerminalCoreLogic"
            ],
            path: "WatermLinuxTests/Core/Terminal"
        ),
        .testTarget(
            name: "WatermSSHCoreLogicTests",
            dependencies: [
                "WatermSSHCoreLogic"
            ],
            path: "WatermLinuxTests/Core/SSH"
        ),
        .testTarget(
            name: "WatermIOSApplicationLogicTests",
            dependencies: [
                "WatermConnectionViewsApplicationLogic",
                "WatermIOSApplicationLogic",
                "WatermRemoteFilesApplicationLogic",
                "WatermServersApplicationLogic",
                "WatermTerminalSessionsApplicationLogic"
            ],
            path: "WatermLinuxTests/App/iOS/Application"
        )
    ]
)
