import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote-file path normalization and joining rules. They use
// pure path strings and no remote filesystem; update only when path semantics
// intentionally change.

struct RemoteFilePathTests {
    @Test
    func normalizeResolvesRelativeAndParentComponents() {
        let normalized = RemoteFilePath.normalize("../logs/./today.log", relativeTo: "/var/tmp/cache")

        #expect(normalized == "/var/tmp/logs/today.log")
    }

    @Test
    func parentOfRootStaysAtRoot() {
        #expect(RemoteFilePath.parent(of: "/") == "/")
    }

    @Test
    func breadcrumbsIncludeRootAndEveryPathSegment() {
        let breadcrumbs = RemoteFilePath.breadcrumbs(for: "/Users/demo/project")

        #expect(breadcrumbs.map(\.title) == ["/", "Users", "demo", "project"])
        #expect(breadcrumbs.map(\.path) == ["/", "/Users", "/Users/demo", "/Users/demo/project"])
    }
}
