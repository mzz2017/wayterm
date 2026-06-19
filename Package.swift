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
            name: "VVTermIOSApplicationLogicTests",
            dependencies: [
                "VVTermIOSApplicationLogic"
            ],
            path: "VVTermLinuxTests/App/iOS/Application"
        )
    ]
)
