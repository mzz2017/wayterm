import XCTest
@testable import WatermServersApplicationLogic

// Test Context: protects workspace deletion warning copy generated outside
// SwiftUI. Update these tests when deletion warning product copy intentionally
// changes.

final class IOSWorkspaceDeletionPolicyTests: XCTestCase {
    func testWarningWithoutWorkspaceUsesGenericText() {
        XCTAssertEqual(
            IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: nil),
            "This will delete the workspace and all servers in it. This cannot be undone."
        )
    }

    func testWarningForEmptyWorkspaceMentionsOnlyWorkspace() {
        XCTAssertEqual(
            IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: 0),
            "This will delete the workspace. This cannot be undone."
        )
    }

    func testWarningForSingleServerUsesSingularText() {
        XCTAssertEqual(
            IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: 1),
            "This will delete the workspace and its 1 server. This cannot be undone."
        )
    }

    func testWarningForMultipleServersUsesCountedPluralText() {
        XCTAssertEqual(
            IOSWorkspaceDeletionWarningPolicy.warningText(serverCount: 3),
            "This will delete the workspace and all 3 servers in it. This cannot be undone."
        )
    }
}
