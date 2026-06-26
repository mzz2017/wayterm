import SwiftUI

struct RemoteFileSheetActionLabel: View {
    let title: String
    let isSubmitting: Bool

    var body: some View {
        Text(title)
            .opacity(isSubmitting ? 0 : 1)
            .overlay {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }
}

struct RemoteFileRenameSheet: View {
    let entry: RemoteFileEntry
    @Binding var proposedName: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onRename: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            renameContent
                .navigationTitle(String(localized: "Rename"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onRename()
                        } label: {
                            RemoteFileSheetActionLabel(
                                title: String(localized: "Rename"),
                                isSubmitting: isSubmitting
                            )
                        }
                        .disabled(trimmedProposedName.isEmpty || isSubmitting)
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Rename"))
                .font(.title2.weight(.semibold))

            renameContent

            HStack {
                Spacer()

                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onRename()
                } label: {
                    RemoteFileSheetActionLabel(
                        title: String(localized: "Rename"),
                        isSubmitting: isSubmitting
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedProposedName.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        #endif
    }

    private var renameContent: some View {
        Form {
            Section(String(localized: "Item")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name)
                        .font(.headline)

                    Text(entry.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "New Name")) {
                TextField(String(localized: "Name"), text: $proposedName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var trimmedProposedName: String {
        proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RemoteFileCreateFolderSheet: View {
    let destinationPath: String
    @Binding var folderName: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            createFolderContent
                .navigationTitle(String(localized: "New Folder"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onCreate()
                        } label: {
                            RemoteFileSheetActionLabel(
                                title: String(localized: "Create"),
                                isSubmitting: isSubmitting
                            )
                        }
                        .disabled(trimmedFolderName.isEmpty || isSubmitting)
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "New Folder"))
                .font(.title2.weight(.semibold))

            createFolderContent

            HStack {
                Spacer()

                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onCreate()
                } label: {
                    RemoteFileSheetActionLabel(
                        title: String(localized: "Create"),
                        isSubmitting: isSubmitting
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedFolderName.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        #endif
    }

    private var createFolderContent: some View {
        Form {
            Section(String(localized: "Destination")) {
                Text(destinationPath)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.vertical, 4)
            }

            Section(String(localized: "Folder Name")) {
                TextField(String(localized: "Name"), text: $folderName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var trimmedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RemoteFileMoveSheet: View {
    let entry: RemoteFileEntry
    @Binding var destinationDirectory: String
    let onRequestDirectories: (String, @escaping @MainActor (Result<[RemoteFileEntry], Error>) -> Void) -> Void
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onMove: () -> Void

    @State private var currentDirectory: String
    @State private var directories: [RemoteFileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        entry: RemoteFileEntry,
        destinationDirectory: Binding<String>,
        onRequestDirectories: @escaping (
            String,
            @escaping @MainActor (Result<[RemoteFileEntry], Error>) -> Void
        ) -> Void,
        isSubmitting: Bool,
        onCancel: @escaping () -> Void,
        onMove: @escaping () -> Void
    ) {
        self.entry = entry
        _destinationDirectory = destinationDirectory
        self.onRequestDirectories = onRequestDirectories
        self.isSubmitting = isSubmitting
        self.onCancel = onCancel
        self.onMove = onMove
        _currentDirectory = State(initialValue: destinationDirectory.wrappedValue)
    }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationStack {
                moveContent
                    .navigationTitle(String(localized: "Move"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Cancel")) {
                                onCancel()
                            }
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                onMove()
                            } label: {
                                RemoteFileSheetActionLabel(
                                    title: String(localized: "Move"),
                                    isSubmitting: isSubmitting
                                )
                            }
                            .disabled(destinationDirectory.isEmpty || isSubmitting)
                        }
                    }
            }
            #else
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "Move"))
                    .font(.title2.weight(.semibold))

                moveContent

                HStack {
                    Spacer()

                    Button(String(localized: "Cancel")) {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button {
                        onMove()
                    } label: {
                        RemoteFileSheetActionLabel(
                            title: String(localized: "Move"),
                            isSubmitting: isSubmitting
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destinationDirectory.isEmpty || isSubmitting)
                }
            }
            .padding(20)
            #endif
        }
        .task(id: currentDirectory) {
            requestDirectories()
        }
    }

    private var moveContent: some View {
        Form {
            Section(String(localized: "Item")) {
                HStack(spacing: 12) {
                    Image(systemName: entry.iconName)
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.headline)
                            .lineLimit(2)

                        Text(entry.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "Selected Folder")) {
                selectedDestinationRow
            }

            Section(String(localized: "Choose Folder")) {
                if currentDirectory != "/" {
                    Button {
                        navigate(to: RemoteFilePath.parent(of: currentDirectory))
                    } label: {
                        pickerRow(
                            title: String(localized: "Up"),
                            systemImage: "arrow.up",
                            iconColor: .accentColor
                        )
                    }
                }

                Button {
                    navigate(to: "/")
                } label: {
                    pickerRow(
                        title: String(localized: "Root"),
                        systemImage: "externaldrive",
                        iconColor: .accentColor
                    )
                }

                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "Loading folders…"))
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button(String(localized: "Retry")) {
                            requestDirectories()
                        }
                    }
                } else if directories.isEmpty {
                    Text(String(localized: "No subfolders in this location."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(directories.enumerated()), id: \.element.id) { _, directory in
                        Button {
                            navigate(to: directory.path)
                        } label: {
                            pickerRow(
                                title: directory.name,
                                systemImage: "folder",
                                iconColor: .accentColor,
                                showsCheckmark: currentDirectory == directory.path
                            )
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var selectedDestinationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.checkmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(folderDisplayName(for: destinationDirectory))
                    .font(.headline)
                    .lineLimit(1)

                Text(destinationDirectory)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func pickerRow(
        title: String,
        systemImage: String,
        iconColor: Color,
        showsCheckmark: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)

            Text(title)
                .foregroundStyle(.primary)

            Spacer()

            if showsCheckmark {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func requestDirectories() {
        let requestedDirectory = currentDirectory
        isLoading = true
        errorMessage = nil
        onRequestDirectories(requestedDirectory) { result in
            guard currentDirectory == requestedDirectory else { return }
            switch result {
            case .success(let entries):
                directories = entries
            case .failure(let error):
                directories = []
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func navigate(to path: String) {
        let normalizedPath = RemoteFilePath.normalize(path)
        currentDirectory = normalizedPath
        destinationDirectory = normalizedPath
    }

    private func folderDisplayName(for path: String) -> String {
        let normalizedPath = RemoteFilePath.normalize(path)
        guard normalizedPath != "/" else { return String(localized: "Root") }
        return URL(fileURLWithPath: normalizedPath).lastPathComponent
    }
}

struct RemoteFileDeleteConfirmationSheet: View {
    let entry: RemoteFileEntry
    let message: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle(String(localized: "Delete"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Delete"), role: .destructive) {
                            onDelete()
                        }
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Delete"))
                .font(.title2.weight(.semibold))

            content

            HStack {
                Spacer()

                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Delete"), role: .destructive) {
                    onDelete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #endif
    }

    private var content: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "trash.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(.headline)

                        Text(entry.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }
}
