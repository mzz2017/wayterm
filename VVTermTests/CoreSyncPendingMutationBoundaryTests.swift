import Foundation
import Testing

// Test Context:
// Core/Sync owns pending CloudKit mutation durability and drain ordering, not
// feature domain models. These source-boundary tests should change only if the
// pending queue is intentionally moved out of Core or the feature-owned payload
// adapter contract is replaced.

struct CoreSyncPendingMutationBoundaryTests {
    @Test
    func pendingCloudKitMutationDoesNotStoreFeatureDomainObjects() throws {
        let root = try sourceRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("VVTerm/Core/Sync/PendingCloudKitSync.swift"),
            encoding: .utf8
        )
        let forbiddenStorageShapes = [
            "Server?",
            "Workspace?",
            "TerminalTheme?",
            "TerminalThemePreference?",
            "TerminalAccessoryProfile?",
            "static func serverUpsert(_ server: Server)",
            "static func workspaceUpsert(_ workspace: Workspace)",
            "static func terminalThemeUpsert(_ theme: TerminalTheme)",
            "static func terminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile)"
        ]

        for forbiddenShape in forbiddenStorageShapes {
            #expect(
                !source.contains(forbiddenShape),
                "PendingCloudKitMutation should store Core-owned payloads, not feature domain object shape \(forbiddenShape)."
            )
        }
    }

    @Test
    func cloudKitSyncCoordinatorDoesNotExposeFeatureDomainEnqueueAPI() throws {
        let root = try sourceRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("VVTerm/Core/Sync/CloudKitSyncCoordinator.swift"),
            encoding: .utf8
        )
        let forbiddenEnqueueSignatures = [
            "func enqueueServerUpsert(_ server: Server)",
            "func enqueueServerDelete(_ server: Server)",
            "func enqueueWorkspaceUpsert(_ workspace: Workspace)",
            "func enqueueWorkspaceDelete(_ workspace: Workspace)",
            "func enqueueTerminalThemeUpsert(_ theme: TerminalTheme)",
            "func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference)",
            "func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile)"
        ]

        for forbiddenSignature in forbiddenEnqueueSignatures {
            #expect(
                !source.contains(forbiddenSignature),
                "CloudKitSyncCoordinator Core surface should accept pending payload mutations, not feature domain enqueue API \(forbiddenSignature)."
            )
        }
    }

    @Test
    func cloudKitSyncCoordinatorDoesNotDecodeFeatureDomainPayloads() throws {
        let root = try sourceRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("VVTerm/Core/Sync/CloudKitSyncCoordinator.swift"),
            encoding: .utf8
        )
        let forbiddenDrainShapes = [
            "decodedPayload(as: Server.self)",
            "decodedPayload(as: Workspace.self)",
            "decodedPayload(as: TerminalTheme.self)",
            "decodedPayload(as: TerminalThemePreference.self)",
            "decodedPayload(as: TerminalAccessoryProfile.self)",
            "CloudKitManager.shared"
        ]

        for forbiddenShape in forbiddenDrainShapes {
            #expect(
                !source.contains(forbiddenShape),
                "CloudKitSyncCoordinator should delegate pending mutation sync, not decode or save feature domain shape \(forbiddenShape)."
            )
        }
    }

    @Test
    func cloudKitManagerDoesNotExposeFeatureDomainSyncAPI() throws {
        let root = try sourceRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("VVTerm/Core/Sync/CloudKitManager.swift"),
            encoding: .utf8
        )
        let forbiddenDomainShapes = [
            "CloudKitChanges",
            "[Server]",
            "[Workspace]",
            "Server(from:",
            "Workspace(from:",
            "func saveServer(",
            "func deleteServer(",
            "func saveWorkspace(",
            "func deleteWorkspace(",
            "func fetchTerminalThemes(",
            "func saveTerminalTheme(",
            "func fetchTerminalThemePreference(",
            "func saveTerminalThemePreference(",
            "TerminalAccessoryProfile"
        ]

        for forbiddenShape in forbiddenDomainShapes {
            #expect(
                !source.contains(forbiddenShape),
                "CloudKitManager should expose record-level CloudKit operations, not feature domain shape \(forbiddenShape)."
            )
        }
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let parent = url.deletingLastPathComponent()
            if parent == url {
                throw CocoaError(.fileNoSuchFile)
            }
            url = parent
        }
        return url.deletingLastPathComponent()
    }
}
