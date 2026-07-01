import XCTest
@testable import Waterm

// Test Context:
// These tests protect Hugging Face URL construction for on-device voice model
// downloads. Model IDs come from settings/catalog entries and file paths may
// come from remote repository metadata, so URL construction must encode unsafe
// characters without flattening repository path structure. Update these tests
// only if Waterm intentionally changes model hosting providers or URL layout.

final class MLXModelRepositoryURLBuilderTests: XCTestCase {
    func testModelInfoURLPreservesOwnerAndModelPathComponents() throws {
        let url = try MLXModelRepositoryURLBuilder.modelInfoURL(
            modelId: " mlx-community/whisper tiny mlx "
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/api/models/mlx-community/whisper%20tiny%20mlx",
            "Model ID URL construction should trim whitespace and encode unsafe characters without replacing owner/model separators."
        )
    }

    func testResolveURLPreservesNestedFilePathAndEncodesUnsafeCharacters() throws {
        let url = try MLXModelRepositoryURLBuilder.resolveURL(
            modelId: "org/model",
            filePath: "sub dir/model shard.safetensors"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/org/model/resolve/main/sub%20dir/model%20shard.safetensors",
            "Repository file paths should be encoded per path component while preserving nested directories."
        )
    }

    func testRejectsEmptyModelOrFilePath() {
        XCTAssertThrowsError(try MLXModelRepositoryURLBuilder.modelInfoURL(modelId: " \n "))
        XCTAssertThrowsError(try MLXModelRepositoryURLBuilder.resolveURL(modelId: "org/model", filePath: " "))
    }
}
