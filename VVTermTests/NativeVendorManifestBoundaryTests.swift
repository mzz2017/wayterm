import Foundation
import Testing

// Test Context:
// These boundary tests protect vendored native artifact provenance. Source
// tarball hashes are not enough once prebuilt .a libraries and generated
// headers are committed; CI must also verify the checked-in Vendor manifest.
// Update only when VVTerm intentionally changes native vendor verification.
struct NativeVendorManifestBoundaryTests {
    @Test
    func nativeVendorArtifactsAreChecksumGatedInBuildScriptAndCI() throws {
        let root = try sourceRoot()
        let buildScript = try source(at: root.appendingPathComponent("scripts/build.sh"))
        let workflow = try source(at: root.appendingPathComponent(".github/workflows/quality.yml"))
        let manifest = root.appendingPathComponent("Vendor/native-artifacts.sha256")

        // Given native binaries and headers are checked into Vendor.
        #expect(FileManager.default.fileExists(atPath: manifest.path))

        // Then the build script can verify the committed manifest, and CI runs
        // that gate with the other native source/vendor checks.
        #expect(buildScript.contains("check-vendor-manifest"))
        #expect(buildScript.contains("generate_vendor_manifest"))
        #expect(buildScript.contains("Vendor/native-artifacts.sha256"))
        #expect(workflow.contains("./scripts/build.sh check-vendor-manifest"))
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
