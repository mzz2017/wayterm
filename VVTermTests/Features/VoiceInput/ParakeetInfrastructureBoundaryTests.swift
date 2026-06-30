import Foundation
import Testing

// Test Context:
// These tests protect VoiceInput Parakeet infrastructure ownership during the
// feature-first cleanup. Codable model configuration and runtime inference
// logic have different change cadences; merging them back into one broad file
// makes model format updates and MLX runtime debugging harder to localize.
// Runtime model code should report unsupported model shapes or inference
// invariants as errors instead of terminating the app with crash-only APIs.
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

    @Test
    func parakeetProductPathsDoNotUseCrashOnlyAPIs() throws {
        let root = try sourceRoot()
        let parakeet = root.appendingPathComponent("VVTerm/Features/VoiceInput/Infrastructure/Parakeet")
        let forbiddenAPIs = [
            "fatalError(",
            "preconditionFailure(",
            "assertionFailure(",
            "assert("
        ]

        for file in try swiftFiles(in: parakeet) {
            let source = try source(at: file)
            for forbiddenAPI in forbiddenAPIs {
                #expect(
                    !source.contains(forbiddenAPI),
                    "Parakeet product code should throw/report errors instead of using \(forbiddenAPI) in \(file.lastPathComponent)."
                )
            }
        }
    }

    @Test
    func parakeetRuntimeDecodePathsHaveCancellationCheckpoints() throws {
        let root = try sourceRoot()
        let modelSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/VoiceInput/Infrastructure/Parakeet/ParakeetModel.swift")
        )

        // Given Parakeet model execution is compiled only on arm64 in product
        // builds, these source guards protect the lifecycle rule that long MLX
        // transcription work must observe task cancellation inside its decode
        // and chunk loops.
        try expectCancellationCheck(
            in: modelSource,
            after: "public func transcribe(",
            before: "private func transcribeChunked("
        )
        try expectCancellationCheck(
            in: modelSource,
            after: "while start < audioLength {",
            before: "return sentencesToResult(tokensToSentences(allTokens))"
        )
        try expectCancellationCheck(
            in: modelSource,
            after: "public func generate(mel: MLXArray)",
            before: "public func decode("
        )
        try expectCancellationCheck(
            in: modelSource,
            after: "while step < length {",
            before: "results.append(hypothesis)"
        )
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

    private func expectCancellationCheck(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws {
        guard let start = source.range(of: startMarker) else {
            Issue.record("Expected to find Parakeet runtime start marker: \(startMarker)")
            return
        }
        guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            Issue.record("Expected to find Parakeet runtime end marker: \(endMarker)")
            return
        }

        let section = source[start.upperBound..<end.lowerBound]
        #expect(
            section.contains("try Task.checkCancellation()"),
            "Parakeet runtime section after \(startMarker) should observe task cancellation."
        )
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
