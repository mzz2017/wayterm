import Foundation
import Testing

// Test Context:
// These tests protect remote quality gates that keep lifecycle and concurrency
// regressions visible on PR/merge. They intentionally inspect workflow source
// because GitHub Actions configuration is the behavior under test; update only
// when Waterm intentionally changes its CI gate names or verification commands.

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
        #expect(
            workflow.contains("IOS_TEST_REQUIRE_EXECUTED_TESTS: \"1\""),
            "Full iOS unit CI should fail if XCTest reports zero executed tests."
        )
        #expect(
            testIOSScript.contains("Test .+ passed after [0-9.]+ seconds"),
            "The iOS wrapper should count Swift Testing per-test output as executed tests."
        )

        // And strict concurrency warnings are continuously guarded remotely.
        #expect(workflow.contains("ios-strict-concurrency:"))
        #expect(workflow.contains("Strict Swift concurrency build"))
        #expect(workflow.contains("IOS_TEST_XCODEBUILD_ACTION: build-for-testing"))
        #expect(workflow.contains("./scripts/test-ios.sh SWIFT_STRICT_CONCURRENCY=complete"))
        #expect(workflow.contains("SWIFT_STRICT_CONCURRENCY=complete"))
        #expect(
            workflow.contains("IOS_TEST_FAIL_ON_SWIFT_CONCURRENCY_WARNINGS: \"1\""),
            "Strict Swift concurrency CI should fail on unaccepted Swift concurrency warnings."
        )
        #expect(testIOSScript.contains("IOS_TEST_FAIL_ON_SWIFT_CONCURRENCY_WARNINGS"))
        #expect(testIOSScript.contains("validate_swift_concurrency_warnings"))
        #expect(workflow.contains("ENABLE_DEBUG_DYLIB: \"NO\""))

        // And macOS app compilation is guarded remotely instead of being
        // inferred from SwiftPM or iOS-only Xcode gates.
        #expect(workflow.contains("macos-app-build:"))
        #expect(workflow.contains("macOS app build"))
        #expect(workflow.contains("Build macOS app target"))
        #expect(workflow.contains("-destination 'platform=macOS'"))
        #expect(workflow.contains("CODE_SIGNING_ALLOWED=NO"))

        // And the iOS wrapper can reuse the same isolated simulator setup for build gates.
        #expect(testIOSScript.contains("xcodebuild_action=\"${IOS_TEST_XCODEBUILD_ACTION:-test}\""))
        #expect(testIOSScript.contains("test_context=\"${IOS_TEST_CONTEXT:-${xcodebuild_action}}\""))
        #expect(testIOSScript.contains("test | build-for-testing"))
        #expect(testIOSScript.contains("xcodebuild_args=(\"$xcodebuild_action\")"))
        #expect(testIOSScript.contains("ENABLE_DEBUG_DYLIB=NO"))

        // And long-running CI runs publish enough wrapper-level evidence to triage hangs.
        #expect(workflow.contains("IOS_TEST_CONTEXT: focused-runtime-build"))
        #expect(workflow.contains("IOS_TEST_CONTEXT: focused-runtime-sync-cloudflare"))
        #expect(testIOSScript.contains("GITHUB_STEP_SUMMARY"))
        #expect(testIOSScript.contains("write_run_metadata"))
        #expect(testIOSScript.contains("::notice title=iOS xcodebuild started::"))

        // And native build cleanup has a behavior self-test in CI because the
        // Ghostty workdir is large enough for cleanup regressions to matter.
        #expect(workflow.contains("Verify Ghostty build cleanup"))
        #expect(workflow.contains("./scripts/build-ghostty-cleanup-self-test.sh"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
