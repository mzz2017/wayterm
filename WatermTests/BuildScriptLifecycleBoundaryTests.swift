import Foundation
import Testing

// Test Context:
// These boundary tests protect local and CI build-script cleanup lifecycles.
// Ghostty builds create large temporary workdirs, so cleanup must be tied to the
// build_ghosttykit function returning or failing, not only to the success tail.
// Update only when Ghostty build diagnostics intentionally change how temporary
// workdirs are retained for KEEP_WORKDIR=1.
struct BuildScriptLifecycleBoundaryTests {
    @Test
    func ghosttyBuildWorkdirCleanupRunsOnFunctionExitUnlessKeptForDiagnostics() throws {
        let buildScript = try source(
            at: sourceRoot().appendingPathComponent("scripts/build.sh")
        )

        // Given Ghostty builds allocate multi-GB temporary workdirs.
        #expect(buildScript.contains("GHOSTTY_WORKDIR=\"$(mktemp -d"))

        // Then cleanup is owned by a shell-exit trap plus a success cleanup so
        // set -e failures before the success tail do not leak /tmp build dirs.
        #expect(buildScript.contains("cleanup_ghostty_workdir()"))
        #expect(buildScript.contains("trap cleanup_ghostty_workdir EXIT"))
        #expect(buildScript.contains("self-test-ghostty-cleanup"))
        #expect(
            buildScript.contains("if [ \"${KEEP_WORKDIR}\" = \"1\" ]"),
            "KEEP_WORKDIR=1 should still intentionally retain the workdir for diagnostics."
        )
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
