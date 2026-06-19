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
            targets: ["VVTermIOSApplicationLogic"]
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
                "KnownHostsManager.swift",
                "RemoteClipboardTransferService.swift",
                "RemoteEnvironmentResolver.swift",
                "RemoteMoshManager.swift",
                "RemoteTmuxManager.swift",
                "RemoteZmxCommandBuilder.swift",
                "SSHClient.swift",
                "SSHKeyGenerator.swift",
                "SSHPublicKeyDeriver.swift",
                "ShellTransport.swift",
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
                "VVTermIOSApplicationLogic"
            ],
            path: "VVTermLinuxTests/App/iOS/Application"
        )
    ]
)
