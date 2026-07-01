import Foundation

nonisolated enum MLXModelRepositoryURLBuilder {
    nonisolated enum URLBuildError: LocalizedError {
        case invalidBaseURL
        case emptyModelId
        case emptyFilePath

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Model repository URL is invalid"
            case .emptyModelId:
                return "Model ID is required"
            case .emptyFilePath:
                return "Model file path is required"
            }
        }
    }

    static func modelInfoURL(modelId: String) throws -> URL {
        try baseModelURL(modelId: modelId)
            .appendingPathComponent("api")
            .appendingPathComponent("models")
            .appendingPathComponents(modelPathComponents(from: modelId))
    }

    static func resolveURL(modelId: String, filePath: String) throws -> URL {
        let fileComponents = pathComponents(from: filePath)
        guard !fileComponents.isEmpty else {
            throw URLBuildError.emptyFilePath
        }

        return try baseModelURL(modelId: modelId)
            .appendingPathComponents(modelPathComponents(from: modelId))
            .appendingPathComponent("resolve")
            .appendingPathComponent("main")
            .appendingPathComponents(fileComponents)
    }

    private static func baseModelURL(modelId: String) throws -> URL {
        guard !modelPathComponents(from: modelId).isEmpty else {
            throw URLBuildError.emptyModelId
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        guard let url = components.url else {
            throw URLBuildError.invalidBaseURL
        }
        return url
    }

    private static func modelPathComponents(from modelId: String) -> [String] {
        pathComponents(from: modelId)
    }

    private static func pathComponents(from path: String) -> [String] {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

private extension URL {
    nonisolated func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
    }
}
