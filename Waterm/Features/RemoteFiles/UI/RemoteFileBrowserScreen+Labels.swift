import Foundation

extension RemoteFileBrowserScreen {
    func currentFolderTitle(for path: String) -> String {
        RemoteFilePath.breadcrumbs(for: path).last?.title ?? "/"
    }

    func itemCountLabel(for count: Int) -> String {
        count == 1
            ? String(format: String(localized: "%lld item"), Int64(count))
            : String(format: String(localized: "%lld items"), Int64(count))
    }

    func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func deleteAlertTitle(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Delete Folder?")
        case .file:
            return String(localized: "Delete File?")
        case .symlink, .other:
            return String(localized: "Delete Item?")
        }
    }

    func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            switch ext {
            case "yaml", "yml":
                return String(localized: "YAML Document")
            case "json":
                return String(localized: "JSON Document")
            case "md":
                return String(localized: "Markdown Document")
            case "txt", "log":
                return String(localized: "Text Document")
            case "swift":
                return String(localized: "Swift Source")
            case "sh", "bash", "zsh":
                return String(localized: "Shell Script")
            case "png", "jpg", "jpeg", "gif", "webp", "heic":
                return String(localized: "Image")
            case "zip", "tar", "gz", "tgz", "xz", "bz2":
                return String(localized: "Archive")
            default:
                return String(localized: "Document")
            }
        }
    }
}
