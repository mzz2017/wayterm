import Testing
@testable import Waterm

// Test Context:
// These tests protect iOS workspace deletion warning copy after the policy moved
// into Servers. The policy keeps destructive-action wording out of SwiftUI view
// code while preserving distinct wording for unknown, empty, single-server, and
// multi-server workspaces. Update these tests only when the product intentionally
// changes workspace deletion warning copy.
struct IOSWorkspaceDeletionWarningPolicyTests {
    @Test
    func warningUsesConservativeCopyWhenServerCountIsUnknown() {
        // Given the caller cannot provide a reliable server count.
        let warning = IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: nil)

        // Then the warning assumes servers may be deleted.
        #expect(warning == "This will delete the workspace and all servers in it. This cannot be undone.")
    }

    @Test
    func warningOmitsServerCopyForEmptyWorkspace() {
        // Given the workspace has no servers.
        let warning = IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: 0)

        // Then the warning only names the workspace deletion.
        #expect(warning == "This will delete the workspace. This cannot be undone.")
    }

    @Test
    func warningUsesSingularServerCopyForOneServer() {
        // Given the workspace has exactly one server.
        let warning = IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: 1)

        // Then the warning uses singular server wording.
        #expect(warning == "This will delete the workspace and its 1 server. This cannot be undone.")
    }

    @Test
    func warningUsesPluralServerCopyForMultipleServers() {
        // Given the workspace has multiple servers.
        let warning = IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: 3)

        // Then the warning includes the precise server count.
        #expect(warning == "This will delete the workspace and all 3 servers in it. This cannot be undone.")
    }
}
