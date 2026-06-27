import Foundation
import Testing

// Test Context:
// These source-boundary tests protect Servers UI superfile control. ServerFormSheet
// is the add/edit form root; independent sheets and feature-specific presentation
// flows should stay in sibling files so the root form does not become the owner of
// every server-management workflow. Update these tests only when the Servers UI
// ownership boundary intentionally changes.
@Suite
struct ServerFormSuperfileBoundaryTests {
    @Test
    func serverFormSheetDoesNotOwnMoveServerSheet() throws {
        let root = try sourceRoot()
        let formSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )
        let moveSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/MoveServerSheet.swift")
        )

        // Given moving a server is a separate sheet workflow with its own
        // selection and save presentation state.
        #expect(
            !formSource.contains("struct MoveServerSheet"),
            "ServerFormSheet.swift should not own the move-server sheet workflow."
        )
        #expect(
            moveSource.contains("struct MoveServerSheet"),
            "MoveServerSheet.swift should own the move-server sheet workflow."
        )
        #expect(
            moveSource.contains("requestServerMove("),
            "MoveServerSheet should keep sending move intent through ServerManager."
        )
    }

    @Test
    func serverFormSheetDoesNotOwnTransportSelectionOrCredentialBuilder() throws {
        let root = try sourceRoot()
        let formSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )
        let selectionSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerTransportSelection.swift")
        )
        let credentialBuilderSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerFormCredentialBuilder.swift")
        )
        let submissionBuilderSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerFormSubmissionBuilder.swift")
        )
        let validationPolicySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerFormValidationPolicy.swift")
        )

        // Given transport selection is UI support and credential assembly is
        // application-layer form orchestration, the root form should only call into
        // those collaborators instead of owning submitted model construction.
        #expect(
            !formSource.contains("enum ServerTransportSelection"),
            "ServerFormSheet.swift should not own the transport selection support type."
        )
        #expect(
            !formSource.contains("struct ServerFormCredentialBuilder"),
            "ServerFormSheet.swift should not own credential assembly policy."
        )
        #expect(
            !formSource.contains("func buildServer"),
            "ServerFormSheet.swift should not own submitted Server construction."
        )
        #expect(
            !formSource.contains("func buildCredentials"),
            "ServerFormSheet.swift should not own submitted credential construction."
        )
        #expect(
            !formSource.contains("UserDefaults.standard"),
            "ServerFormSheet.swift should not read terminal defaults directly."
        )
        #expect(
            !formSource.contains("private var hasValidCredentials"),
            "ServerFormSheet.swift should not own credential validation policy."
        )
        #expect(
            !formSource.contains("ServerPortValidator.normalizedPort(from: port)"),
            "ServerFormSheet.swift should not own port validation policy."
        )
        #expect(
            selectionSource.contains("enum ServerTransportSelection"),
            "ServerTransportSelection.swift should own transport selection UI support."
        )
        #expect(
            credentialBuilderSource.contains("struct ServerFormCredentialBuilder"),
            "Servers Application should own server form credential assembly."
        )
        #expect(
            credentialBuilderSource.contains("connectionMode: SSHConnectionMode"),
            "Credential assembly should depend on connection mode, not UI selection state."
        )
        #expect(
            submissionBuilderSource.contains("struct ServerFormSubmissionBuilder"),
            "Servers Application should own server form submission assembly."
        )
        #expect(
            submissionBuilderSource.contains("struct ServerFormDefaults"),
            "Servers Application should own form default resolution."
        )
        #expect(
            formSource.contains("ServerFormValidationPolicy.isValid(draft: currentDraft)"),
            "ServerFormSheet.swift should delegate form validation to Servers Application policy."
        )
        #expect(
            validationPolicySource.contains("enum ServerFormValidationPolicy"),
            "Servers Application should own server form validation policy."
        )
    }

    @Test
    func serverFormSheetComposesFieldSectionsWithoutOwningTheirLayout() throws {
        let root = try sourceRoot()
        let formSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )
        let sectionSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSections.swift")
        )
        let platformModifierSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormPlatformModifiers.swift")
        )

        // Given ServerFormSheet is the add/edit form root.
        for component in [
            "ServerFormLimitSection",
            "ServerFormServerSection",
            "ServerFormAuthenticationSection",
            "ServerFormConnectionSection",
            "ServerFormConnectionFooter",
            "ServerFormKeyInputView",
            "ServerFormSessionSection",
            "ServerFormMacActionRow",
            "ServerFormSecuritySection",
            "ServerFormNotesSection",
            "ServerFormAssignmentSection"
        ] {
            #expect(
                formSource.contains("\(component)("),
                "ServerFormSheet.swift should compose \(component)."
            )
            #expect(
                !formSource.contains("struct \(component)"),
                "ServerFormSheet.swift should not define \(component)."
            )
            #expect(
                sectionSource.contains("struct \(component)"),
                "ServerFormSections.swift should define \(component)."
            )
        }

        for helperName in [
            "macActionRow",
            "limitSection",
            "serverSection",
            "connectionFooter",
            "keyInputView"
        ] {
            #expect(
                !formSource.contains("private var \(helperName)"),
                "ServerFormSheet.swift should not own \(helperName) presentation helper."
            )
        }

        for modifierName in [
            "CompactListSectionSpacingModifier",
            "TransparentNavigationBarModifier"
        ] {
            #expect(
                !formSource.contains("struct \(modifierName)"),
                "ServerFormSheet.swift should not own \(modifierName) platform support."
            )
            #expect(
                platformModifierSource.contains("struct \(modifierName)"),
                "ServerFormPlatformModifiers.swift should own \(modifierName) platform support."
            )
        }

        // Then the root form should keep sending lifecycle intent instead of
        // moving save or connection-test orchestration into the section views.
        #expect(
            formSource.contains("requestConnectionTest(force: true)"),
            "ServerFormSheet.swift should keep connection-test intent at the form root."
        )
        #expect(
            !sectionSource.contains("requestConnectionTest("),
            "ServerFormSections.swift should not own connection-test orchestration."
        )
        #expect(
            !sectionSource.contains("requestServerSave("),
            "ServerFormSections.swift should not own save orchestration."
        )
    }

    @Test
    func serverFormsDoNotResolveSharedServerManager() throws {
        let root = try sourceRoot()
        let formSources = try [
            "VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift",
            "VVTerm/Features/Servers/UI/Workspace/EnvironmentFormSheet.swift",
            "VVTerm/Features/Servers/UI/Workspace/WorkspaceFormSheet.swift"
        ].map { path in
            (path, try source(at: root.appendingPathComponent(path)))
        }

        for (path, formSource) in formSources {
            #expect(
                !formSource.contains("ServerManager.shared"),
                "\(path) should receive ServerManager through explicit injection, including previews."
            )
        }
    }

    @Test
    func workspaceFormUsesInjectedStoreManager() throws {
        let root = try sourceRoot()
        let workspaceFormSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Workspace/WorkspaceFormSheet.swift")
        )
        let callerSources = try [
            "VVTerm/Features/Servers/UI/ServerDetail/MoveServerSheet.swift",
            "VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift",
            "VVTerm/Features/Servers/UI/Workspace/WorkspaceSwitcherSheet.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerComponents.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        #expect(
            workspaceFormSource.contains("@ObservedObject var storeManager: StoreManager"),
            "WorkspaceFormSheet should receive StoreManager from its caller."
        )
        #expect(
            !workspaceFormSource.contains("StoreManager.shared"),
            "WorkspaceFormSheet should not resolve StoreManager.shared from workspace form UI."
        )
        #expect(
            callerSources.contains("storeManager: storeManager"),
            "WorkspaceFormSheet callers should pass the existing StoreManager dependency through."
        )
    }

    @Test
    func serverFormUsesInjectedStoreManager() throws {
        let root = try sourceRoot()
        let serverFormSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )
        let callerSources = try [
            "VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift",
            "VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift",
            "VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalPresentationHost.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Given ServerFormSheet enforces store-backed limits while presenting
        // from multiple app surfaces, the store dependency should be provided by
        // the caller instead of resolved by the form leaf.
        #expect(
            serverFormSource.contains("@ObservedObject var storeManager: StoreManager"),
            "ServerFormSheet should receive StoreManager from its caller."
        )
        #expect(
            !serverFormSource.contains("StoreManager.shared"),
            "ServerFormSheet should not resolve StoreManager.shared from the form UI."
        )
        #expect(
            callerSources.contains("storeManager: storeManager"),
            "ServerFormSheet callers should pass the existing StoreManager dependency through."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
