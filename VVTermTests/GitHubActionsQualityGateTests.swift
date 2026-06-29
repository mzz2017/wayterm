import Foundation
import Testing

// Test Context:
// These tests protect remote quality gates that keep lifecycle and concurrency
// regressions visible on PR/merge. They intentionally inspect workflow source
// because GitHub Actions configuration is the behavior under test; update only
// when VVTerm intentionally changes its CI gate names or verification commands.

struct GitHubActionsQualityGateTests {
    @Test
    func qualityWorkflowRunsFocusedFullAndStrictConcurrencyGates() throws {
        let workflow = try source(
            at: sourceRoot().appendingPathComponent(".github/workflows/quality.yml")
        )
        let testIOSScript = try source(
            at: sourceRoot().appendingPathComponent("scripts/test-ios.sh")
        )

        // Given PR/merge quality should not depend on local agent discipline.
        #expect(workflow.contains("pull_request:"))
        #expect(workflow.contains("push:"))

        // Then CI runs the focused lifecycle gate before the full iOS unit gate.
        #expect(workflow.contains("ios-focused-runtime:"))
        #expect(workflow.contains("Focused runtime lifecycle tests"))
        #expect(workflow.contains("ios-unit:"))
        #expect(workflow.contains("needs: ios-focused-runtime"))
        #expect(workflow.contains("- ios-focused-runtime"))
        #expect(workflow.contains("- ios-strict-concurrency"))
        #expect(workflow.contains("run: ./scripts/test-ios.sh"))

        // And strict concurrency warnings are continuously guarded remotely.
        #expect(workflow.contains("ios-strict-concurrency:"))
        #expect(workflow.contains("Strict Swift concurrency build"))
        #expect(workflow.contains("IOS_TEST_XCODEBUILD_ACTION: build-for-testing"))
        #expect(workflow.contains("./scripts/test-ios.sh SWIFT_STRICT_CONCURRENCY=complete"))
        #expect(workflow.contains("SWIFT_STRICT_CONCURRENCY=complete"))
        #expect(workflow.contains("ENABLE_DEBUG_DYLIB: \"NO\""))

        // And the iOS wrapper can reuse the same isolated simulator setup for build gates.
        #expect(testIOSScript.contains("xcodebuild_action=\"${IOS_TEST_XCODEBUILD_ACTION:-test}\""))
        #expect(testIOSScript.contains("test | build-for-testing"))
        #expect(testIOSScript.contains("xcodebuild_args=(\"$xcodebuild_action\")"))
        #expect(testIOSScript.contains("ENABLE_DEBUG_DYLIB=NO"))
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
}

private enum SourceRootError: Error {
    case notFound
}
