import Foundation

struct LiveMLXModelInfoFetcher: MLXModelInfoFetching {
    func modelInfoData(for modelId: String) async throws -> Data {
        let url = try MLXModelRepositoryURLBuilder.modelInfoURL(modelId: modelId)
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}
