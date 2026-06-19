import Foundation

public struct RemoteFileBreadcrumb: Identifiable, Hashable, Sendable {
    public let title: String
    public let path: String

    public var id: String { path }
}

public enum RemoteFilePath {
    public static func normalize(_ path: String, relativeTo currentPath: String? = nil) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return currentPath ?? "/"
        }

        let basePath: String
        if trimmed.hasPrefix("/") {
            basePath = trimmed
        } else if let currentPath {
            let separator = currentPath == "/" ? "" : "/"
            basePath = currentPath + separator + trimmed
        } else {
            basePath = "/" + trimmed
        }

        let components = basePath.split(separator: "/", omittingEmptySubsequences: false)
        var normalized: [Substring] = []

        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            default:
                normalized.append(component)
            }
        }

        return "/" + normalized.joined(separator: "/")
    }

    public static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }

        var components = normalized.split(separator: "/")
        _ = components.popLast()
        if components.isEmpty {
            return "/"
        }
        return "/" + components.joined(separator: "/")
    }

    public static func appending(_ name: String, to directoryPath: String) -> String {
        let separator = directoryPath == "/" ? "" : "/"
        return normalize(directoryPath + separator + name)
    }

    public static func breadcrumbs(for path: String) -> [RemoteFileBreadcrumb] {
        let normalized = normalize(path)
        guard normalized != "/" else {
            return [RemoteFileBreadcrumb(title: "/", path: "/")]
        }

        var breadcrumbs = [RemoteFileBreadcrumb(title: "/", path: "/")]
        let components = normalized.split(separator: "/")
        var current = ""
        for component in components {
            current += "/" + component
            breadcrumbs.append(
                RemoteFileBreadcrumb(title: String(component), path: current)
            )
        }
        return breadcrumbs
    }
}
