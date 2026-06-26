import SwiftUI

#if os(macOS)
import AppKit
#endif

struct RemoteFileTextSaveRequest {
    let entry: RemoteFileEntry
    let text: String
    let onSaved: @MainActor @Sendable () -> Void
    let onFailure: @MainActor @Sendable (Error) -> Void
}

struct RemoteFileInspectorView: View {
    enum Chrome {
        case sidebar
        case sheet
    }

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case metadata
        case content

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .metadata:
                return "Metadata"
            case .content:
                return "Preview"
            }
        }
    }

    let selectedEntry: RemoteFileEntry?
    let viewerPayload: RemoteFileViewerPayload?
    let isLoadingViewer: Bool
    let viewerError: RemoteFileBrowserError?
    let directoryError: RemoteFileBrowserError?
    let chrome: Chrome
    let backgroundColor: Color
    let previewBackgroundColor: Color
    let sectionBackgroundColor: Color
    let onLoadPreview: ((RemoteFileEntry) -> Void)?
    let onDownloadPreview: ((RemoteFileEntry) -> Void)?
    let onDownload: ((RemoteFileEntry) -> Void)?
    let onShare: ((RemoteFileEntry) -> Void)?
    let onRename: ((RemoteFileEntry) -> Void)?
    let onMove: ((RemoteFileEntry) -> Void)?
    let onEditPermissions: ((RemoteFileEntry) -> Void)?
    let onDelete: ((RemoteFileEntry) -> Void)?
    let onClose: (() -> Void)?
    let onSaveText: ((RemoteFileTextSaveRequest) -> Void)?

    @State private var selectedTab: InspectorTab = .metadata
    @State private var editableText = ""
    @State private var isEditingText = false
    @State private var isSavingText = false
    @State private var textSaveErrorMessage: String?
    @State private var presentedMediaPreview: PresentedMediaPreview?

    var body: some View {
        Group {
            if chrome == .sidebar {
                sidebarInspectorContent
            } else {
                sheetInspectorContent
            }
        }
        .background(backgroundColor)
        .onChange(of: selectedEntry?.path) { _ in
            selectedTab = .metadata
            isEditingText = false
            isSavingText = false
            textSaveErrorMessage = nil
            editableText = viewerPayload?.textPreview ?? ""
        }
        .onChange(of: selectedEntry?.supportsPreview) { supportsPreview in
            if supportsPreview != true {
                selectedTab = .metadata
            }
        }
        .onChange(of: viewerPayload?.textPreview) { newValue in
            guard !isEditingText else { return }
            editableText = newValue ?? ""
        }
        .task(id: previewRequestID) {
            guard activeTab == .content, let selectedEntry, selectedEntry.supportsPreview else { return }
            guard viewerPayload?.entry.path != selectedEntry.path else { return }
            guard !isLoadingViewer else { return }
            guard viewerError == nil else { return }
            onLoadPreview?(selectedEntry)
        }
        .alert(String(localized: "Unable to Save"), isPresented: textSaveErrorBinding) {
            Button(String(localized: "OK"), role: .cancel) {
                textSaveErrorMessage = nil
            }
        } message: {
            Text(textSaveErrorMessage ?? "")
        }
        .sheet(item: $presentedMediaPreview) { item in
            RemoteFileExpandedMediaPreview(item: item)
        }
    }

    @ViewBuilder
    private var sidebarInspectorContent: some View {
        if let selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: chrome == .sidebar ? 12 : 16) {
                    RemoteFileInspectorHeader(
                        entry: selectedEntry,
                        chrome: chrome,
                        sectionBackgroundColor: sectionBackgroundColor,
                        actions: inspectorActions,
                        onClose: onClose
                    )
                    if showsPreviewTab {
                        inspectorTabs
                    }
                }
                .padding(chrome == .sidebar ? 12 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)

                if activeTab == .metadata {
                    Form {
                        RemoteFileInspectorMetadataFormSection(entry: selectedEntry)
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .background(backgroundColor)
                } else {
                    ScrollView {
                        previewContent(for: selectedEntry)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if chrome == .sidebar, onClose != nil {
                        HStack {
                            Spacer(minLength: 0)
                            closeInspectorButton
                        }
                    }

                    if let directoryError {
                        RemoteFileEmptyState(
                            icon: "exclamationmark.triangle.fill",
                            title: String(localized: "Preview Unavailable"),
                            message: directoryError.errorDescription ?? directoryError.localizedDescription
                        )
                    } else {
                        RemoteFileEmptyState(
                            icon: "doc.text.magnifyingglass",
                            title: String(localized: "Select an Item"),
                            message: String(localized: "Choose a file or folder to inspect its metadata.")
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sheetInspectorContent: some View {
        VStack(spacing: 0) {
            if selectedEntry != nil, showsPreviewTab {
                inspectorTabs
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }

            Form {
                if let selectedEntry {
                    if activeTab == .metadata {
                        RemoteFileInspectorMetadataFormSection(entry: selectedEntry)

                        if inspectorActions.showsPrimaryActions(for: selectedEntry) {
                            RemoteFileInspectorPrimaryActionsFormSection(
                                entry: selectedEntry,
                                actions: inspectorActions
                            )
                        }

                        if onDelete != nil {
                            RemoteFileInspectorDeleteFormSection(
                                entry: selectedEntry,
                                actions: inspectorActions
                            )
                        }
                    } else {
                        previewFormSection(for: selectedEntry)
                    }
                } else if let directoryError {
                    Section {
                        inspectorStatusMessage(
                            title: String(localized: "Preview Unavailable"),
                            message: directoryError.errorDescription ?? directoryError.localizedDescription,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                } else {
                    Section {
                        inspectorStatusMessage(
                            title: String(localized: "Select an Item"),
                            message: String(localized: "Choose a file or folder to inspect its metadata."),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(backgroundColor)
        }
        .background(backgroundColor)
    }

    private var inspectorTabs: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .frame(height: 36)
                        .background(
                            selectedTab == tab ? Color.primary.opacity(0.18) : Color.clear,
                            in: Capsule(style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func previewContent(for selectedEntry: RemoteFileEntry) -> some View {
        if let viewerPayload, viewerPayload.entry.path == selectedEntry.path {
            loadedSidebarPreviewContent(viewerPayload, selectedEntry: selectedEntry)
        } else if isLoadingViewer {
            RemoteFileEmptyState(
                icon: "doc.text.magnifyingglass",
                title: String(localized: "Loading Preview"),
                message: String(localized: "Fetching the remote file contents.")
            )
        } else if let viewerError {
            VStack(alignment: .leading, spacing: 12) {
                RemoteFileEmptyState(
                    icon: "exclamationmark.triangle.fill",
                    title: String(localized: "Preview Unavailable"),
                    message: viewerError.errorDescription ?? viewerError.localizedDescription
                )

                if let onLoadPreview {
                    Button(String(localized: "Retry Preview")) {
                        onLoadPreview(selectedEntry)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        } else {
            RemoteFileEmptyState(
                icon: "doc.text.magnifyingglass",
                title: String(localized: "Loading Preview"),
                message: String(localized: "Fetching the remote file contents.")
            )
        }
    }

    @ViewBuilder
    private func loadedSidebarPreviewContent(
        _ payload: RemoteFileViewerPayload,
        selectedEntry: RemoteFileEntry
    ) -> some View {
        switch payload.previewKind {
        case .text:
            textPreviewSection(
                payload,
                selectedEntry: selectedEntry,
                useSectionBackground: true
            )
        case .image, .video:
            mediaPreviewSection(payload)
        case .unavailable:
            if payload.requiresExplicitDownload {
                previewDownloadPrompt(payload)
            } else {
                previewUnavailableState(payload)
            }
        }
    }

    private func textPreviewSection(
        _ payload: RemoteFileViewerPayload,
        selectedEntry: RemoteFileEntry,
        useSectionBackground: Bool,
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Text(String(localized: "Preview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if isEditingText {
                TextEditor(text: $editableText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(previewContainerBackground(useSectionBackground: useSectionBackground))
            } else {
                ScrollView(.vertical) {
                    Text(payload.textPreview ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                .padding(12)
                .background(previewContainerBackground(useSectionBackground: useSectionBackground))
            }

            if payload.canEditText, onSaveText != nil {
                textEditingControls(for: selectedEntry, originalText: payload.textPreview ?? "")
            }

            if payload.isTruncated {
                Text(String(localized: "Preview output was truncated to avoid loading large remote files."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func textEditingControls(for entry: RemoteFileEntry, originalText: String) -> some View {
        HStack(spacing: 10) {
            if isEditingText {
                Button(String(localized: "Cancel")) {
                    isEditingText = false
                    editableText = originalText
                }
                .buttonStyle(.bordered)

                Button(String(localized: "Save")) {
                    saveEditedText(for: entry)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingText || editableText == originalText)
            } else {
                Button(String(localized: "Edit Text")) {
                    editableText = originalText
                    isEditingText = true
                }
                .buttonStyle(.bordered)
            }

            if isSavingText {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func mediaPreviewSection(
        _ payload: RemoteFileViewerPayload,
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Text(String(localized: "Preview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let previewFileURL = payload.previewFileURL {
                switch payload.previewKind {
                case .image:
                    Button {
                        presentMediaPreview(payload)
                    } label: {
                        RemoteFileImagePreview(url: previewFileURL, backgroundColor: previewBackground)
                    }
                    .buttonStyle(.plain)
                case .video:
                    RemoteFileVideoPreview(url: previewFileURL, backgroundColor: previewBackground)
                case .text, .unavailable:
                    EmptyView()
                }

                Button {
                    presentMediaPreview(payload)
                } label: {
                    Label(String(localized: "Open Full Preview"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
            } else {
                if payload.requiresExplicitDownload {
                    previewDownloadPrompt(payload)
                } else {
                    previewUnavailableState(payload)
                }
            }
        }
    }

    @ViewBuilder
    private func previewDownloadPrompt(_ payload: RemoteFileViewerPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteFileEmptyState(
                icon: "arrow.down.circle",
                title: String(localized: "Download Preview"),
                message: payload.unavailableMessage
                    ?? String(localized: "Download the remote file to generate an inline preview.")
            )

            if let onDownloadPreview {
                Button {
                    onDownloadPreview(payload.entry)
                } label: {
                    let sizeLabel = previewSizeLabel(for: payload)
                    if let sizeLabel {
                        Label(
                            String(
                                format: String(localized: "Download Preview (%@)"),
                                sizeLabel
                            ),
                            systemImage: "arrow.down.circle"
                        )
                    } else {
                        Label(String(localized: "Download Preview"), systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func previewUnavailableState(_ payload: RemoteFileViewerPayload) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                RemoteFileEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: String(localized: "Preview Unavailable"),
                    message: unavailablePreviewMessage(for: payload)
                )

                unavailablePreviewAction(payload)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder
    private func unavailablePreviewAction(_ payload: RemoteFileViewerPayload) -> some View {
        #if os(macOS)
        if let previewFileURL = payload.previewFileURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([previewFileURL])
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "finder")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        } else if inspectorActions.canShare(payload.entry) {
            Button {
                onShare?(payload.entry)
            } label: {
                Label(String(localized: "Open in Another App"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        #else
        if inspectorActions.canDownload(payload.entry) {
            Button {
                onDownload?(payload.entry)
            } label: {
                Label(String(localized: "Save to Files"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        #endif
    }

    private func unavailablePreviewMessage(for payload: RemoteFileViewerPayload) -> String {
        #if os(macOS)
        if payload.previewKind == .video, payload.previewFileURL != nil {
            return String(
                localized: "Inline video preview is unreliable for this downloaded file on macOS. Reveal it in Finder and open it with another app such as VLC or IINA."
            )
        }
        #endif

        if let message = payload.unavailableMessage {
            if message == String(localized: "This file downloaded successfully, but macOS could not open it for inline preview.") {
                return String(
                    localized: "This file downloaded successfully, but macOS could not decode it for inline preview. Reveal it in Finder and open it with another app such as VLC or IINA."
                )
            }
            return message
        }

        return String(localized: "Inline preview is unavailable for this file.")
    }

    private func previewContainerBackground(useSectionBackground: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(useSectionBackground ? previewBackground : Color.clear)
    }

    private var closeInspectorButton: some View {
        Button {
            onClose?()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help(Text("Close Preview"))
    }

    @ViewBuilder
    private func previewFormSection(for selectedEntry: RemoteFileEntry) -> some View {
        Section {
            if let viewerPayload, viewerPayload.entry.path == selectedEntry.path {
                switch viewerPayload.previewKind {
                case .text:
                    textPreviewSection(
                        viewerPayload,
                        selectedEntry: selectedEntry,
                        useSectionBackground: false,
                        showsHeader: false
                    )
                case .image, .video:
                    mediaPreviewSection(viewerPayload, showsHeader: false)
                case .unavailable:
                    if viewerPayload.requiresExplicitDownload {
                        previewDownloadPrompt(viewerPayload)
                    } else {
                        inspectorStatusMessage(
                            title: String(localized: "Preview Unavailable"),
                            message: viewerPayload.unavailableMessage
                                ?? String(localized: "Inline preview is unavailable for this file."),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            } else if isLoadingViewer {
                inspectorLoadingMessage(
                    title: String(localized: "Loading Preview"),
                    message: String(localized: "Fetching the remote file contents.")
                )
            } else if let viewerError {
                inspectorStatusMessage(
                    title: String(localized: "Preview Unavailable"),
                    message: viewerError.errorDescription ?? viewerError.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )

                if let onLoadPreview {
                    Button(String(localized: "Retry Preview")) {
                        onLoadPreview(selectedEntry)
                    }
                }
            } else {
                inspectorLoadingMessage(
                    title: String(localized: "Loading Preview"),
                    message: String(localized: "Fetching the remote file contents.")
                )
            }
        } header: {
            Text(String(localized: "Preview"))
        }
    }

    private var textSaveErrorBinding: Binding<Bool> {
        Binding(
            get: { textSaveErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    textSaveErrorMessage = nil
                }
            }
        )
    }

    private func saveEditedText(for entry: RemoteFileEntry) {
        guard let onSaveText else { return }

        isSavingText = true
        onSaveText(RemoteFileTextSaveRequest(
            entry: entry,
            text: editableText,
            onSaved: {
                isEditingText = false
                textSaveErrorMessage = nil
                isSavingText = false
            },
            onFailure: { error in
                textSaveErrorMessage = error.localizedDescription
                isSavingText = false
            }
        ))
    }

    private func inspectorStatusMessage(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func inspectorLoadingMessage(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var previewBackground: Color {
        previewBackgroundColor
    }

    private var inspectorActions: RemoteFileInspectorActions {
        RemoteFileInspectorActions(
            onDownload: onDownload,
            onShare: onShare,
            onRename: onRename,
            onMove: onMove,
            onEditPermissions: onEditPermissions,
            onDelete: onDelete
        )
    }

    private var showsPreviewTab: Bool {
        selectedEntry?.supportsPreview == true
    }

    private var activeTab: InspectorTab {
        showsPreviewTab ? selectedTab : .metadata
    }

    private var previewRequestID: String {
        guard activeTab == .content, let selectedEntry else { return "metadata" }
        return selectedEntry.path
    }

    private func previewSizeLabel(for payload: RemoteFileViewerPayload) -> String? {
        guard let byteCount = payload.previewByteCount else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private func presentMediaPreview(_ payload: RemoteFileViewerPayload) {
        guard let url = payload.previewFileURL else { return }
        presentedMediaPreview = PresentedMediaPreview(
            title: payload.entry.name,
            kind: payload.previewKind,
            url: url
        )
    }
}
