import Foundation
import Testing

// Test Context:
// These tests protect VoiceInput Parakeet infrastructure ownership during the
// feature-first cleanup. Codable model configuration and runtime inference
// logic have different change cadences; merging them back into one broad file
// makes model format updates and MLX runtime debugging harder to localize.
// Update this test only if Parakeet infrastructure ownership intentionally
// changes.
struct ParakeetInfrastructureBoundaryTests {
    @Test
    func parakeetConfigurationStaysSeparateFromRuntimeModel() throws {
        let root = try sourceRoot()
        let parakeet = root.appendingPathComponent("VVTerm/Features/VoiceInput/Infrastructure/Parakeet")
        let configuration = parakeet.appendingPathComponent("ParakeetConfiguration.swift")
        let model = parakeet.appendingPathComponent("ParakeetModel.swift")

        let configurationSource = try source(at: configuration)
        let modelSource = try source(at: model)

        #expect(
            configurationSource.contains("struct ParakeetTDTConfig"),
            "Codable Parakeet model configuration should live in ParakeetConfiguration.swift."
        )
        #expect(
            configurationSource.contains("struct PreprocessConfig"),
            "Audio preprocessing configuration should stay with the decoded model configuration."
        )
        #expect(
            modelSource.contains("class ParakeetTDT"),
            "ParakeetModel.swift should remain the runtime model execution owner."
        )
        #expect(
            !modelSource.contains("struct ParakeetTDTConfig"),
            "ParakeetModel.swift should not re-own Codable configuration structs."
        )

        for file in try swiftFiles(in: parakeet) {
            let lineCount = try source(at: file).split(separator: "\n", omittingEmptySubsequences: false).count
            #expect(
                lineCount < 800,
                "\(file.lastPathComponent) should stay below the AGENTS.md superfile review threshold."
            )
        }
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return urls.filter { $0.pathExtension == "swift" }
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
