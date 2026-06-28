// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VVTermLinuxCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VVTermIOSApplicationLogic",
            targets: [
                "VVTermConnectionViewsApplicationLogic",
                "VVTermIOSApplicationLogic",
                "VVTermRemoteFilesApplicationLogic",
                "VVTermServersApplicationLogic",
                "VVTermTerminalSessionsApplicationLogic"
            ]
        )
    ],
    targets: [
        .target(
            name: "VVTermRemoteFilesDomain",
            path: "VVTerm/Features/RemoteFiles/Domain",
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
            name: "VVTermTerminalCoreLogic",
            path: "VVTerm/Core/Terminal/Logic"
        ),
        .target(
            name: "VVTermSSHCoreLogic",
            path: "VVTerm/Core/SSH",
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
                "RemoteTerminalTypeResolver.swift"
            ]
        ),
        .target(
            name: "VVTermIOSApplicationLogic",
            dependencies: ["VVTermRemoteFilesDomain"],
            path: "VVTerm/App/iOS/Application"
        ),
        .target(
            name: "VVTermConnectionViewsApplicationLogic",
            path: "VVTerm/Features/ConnectionViews/Application",
            exclude: [
                "ViewTabConfigurationManager.swift"
            ],
            sources: [
                "IOSConnectionViewSelectionPolicy.swift"
            ]
        ),
        .target(
            name: "VVTermRemoteFilesApplicationLogic",
            dependencies: ["VVTermRemoteFilesDomain"],
            path: "VVTerm/Features/RemoteFiles/Application",
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
            name: "VVTermServersApplicationLogic",
            path: "VVTerm/Features/Servers/Application",
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
            name: "VVTermTerminalSessionsApplicationLogic",
            path: "VVTerm/Features/TerminalSessions/Application",
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
            name: "VVTermTerminalCoreLogicTests",
            dependencies: [
                "VVTermTerminalCoreLogic"
            ],
            path: "VVTermLinuxTests/Core/Terminal"
        ),
        .testTarget(
            name: "VVTermSSHCoreLogicTests",
            dependencies: [
                "VVTermSSHCoreLogic"
            ],
            path: "VVTermLinuxTests/Core/SSH"
        ),
        .testTarget(
            name: "VVTermIOSApplicationLogicTests",
            dependencies: [
                "VVTermConnectionViewsApplicationLogic",
                "VVTermIOSApplicationLogic",
                "VVTermRemoteFilesApplicationLogic",
                "VVTermServersApplicationLogic",
                "VVTermTerminalSessionsApplicationLogic"
            ],
            path: "VVTermLinuxTests/App/iOS/Application"
        )
    ]
)
