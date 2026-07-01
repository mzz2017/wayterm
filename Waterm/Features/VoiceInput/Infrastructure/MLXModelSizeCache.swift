import Foundation

protocol MLXModelSizing: Sendable {
    func size(for modelId: String) async -> Int64?
}

protocol MLXModelInfoFetching: Sendable {
    func modelInfoData(for modelId: String) async throws -> Data
}

struct NoopMLXModelSizer: MLXModelSizing {
    nonisolated init() {}

    func size(for modelId: String) async -> Int64? {
        nil
    }
}

actor MLXModelSizeCache: MLXModelSizing {
    static let shared = MLXModelSizeCache(infoFetcher: LiveMLXModelInfoFetcher())

    private var cache: [String: Int64] = [:]
    private var failed: Set<String> = []
    private let infoFetcher: any MLXModelInfoFetching

    private struct HFModelSizeInfo: Decodable {
        let usedStorage: Int64?
    }

    init(infoFetcher: any MLXModelInfoFetching) {
        self.infoFetcher = infoFetcher
    }

    func size(for modelId: String) async -> Int64? {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let cached = cache[normalized] { return cached }
        if failed.contains(normalized) { return nil }

        do {
            let data = try await infoFetcher.modelInfoData(for: normalized)
            let info = try JSONDecoder().decode(HFModelSizeInfo.self, from: data)
            if let size = info.usedStorage {
                cache[normalized] = size
                return size
            }
            failed.insert(normalized)
            return nil
        } catch {
            failed.insert(normalized)
            return nil
        }
    }
}
