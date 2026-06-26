import SwiftUI

struct RemoteFilePermissionEditorSheet: View {
    let entry: RemoteFileEntry
    @Binding var draft: RemoteFilePermissionDraft
    let originalAccessBits: UInt32
    let preservedBits: UInt32
    let errorMessage: String?
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onApply: () -> Void

    private var permissionsChanged: Bool {
        draft.accessBits != originalAccessBits
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(String(localized: "Permissions"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onApply()
                        } label: {
                            RemoteFileSheetActionLabel(
                                title: String(localized: "Apply"),
                                isSubmitting: isSubmitting
                            )
                        }
                        .disabled(!permissionsChanged || isSubmitting)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            content

            Divider()

            HStack {
                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onApply()
                } label: {
                    RemoteFileSheetActionLabel(
                        title: String(localized: "Apply"),
                        isSubmitting: isSubmitting
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!permissionsChanged || isSubmitting)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                summaryCard

                ForEach(RemoteFilePermissionAudience.allCases) { audience in
                    permissionGroup(for: audience)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    inlineErrorMessage(errorMessage)
                }

                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isSubmitting)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.name, systemImage: entry.iconName)
                .font(.headline)

            Text(entry.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Access Summary"))
                .font(.subheadline.weight(.semibold))

            ForEach(RemoteFilePermissionAudience.allCases) { audience in
                HStack(alignment: .top, spacing: 10) {
                    Text(audienceTitle(audience))
                        .font(.callout.weight(.medium))
                        .frame(width: 86, alignment: .leading)

                    Text(accessSummary(for: audience))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Mode \(summaryModeString)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.18))
        )
    }

    private func permissionGroup(for audience: RemoteFilePermissionAudience) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(audienceTitle(audience))
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(RemoteFilePermissionCapability.allCases) { capability in
                    Toggle(isOn: permissionBinding(for: capability, audience: audience)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capabilityTitle(capability))
                                .font(.body.weight(.medium))

                            Text(capabilityDescription(capability))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    if capability != .execute {
                        Divider()
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.14))
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preservedBits != 0 {
                Text(String(localized: "Special permission bits already on this item will be preserved."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(footerDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func inlineErrorMessage(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.orange.opacity(0.12))
        )
    }

    private func permissionBinding(
        for capability: RemoteFilePermissionCapability,
        audience: RemoteFilePermissionAudience
    ) -> Binding<Bool> {
        Binding(
            get: {
                draft.isEnabled(capability, for: audience)
            },
            set: { isEnabled in
                draft.set(isEnabled, capability: capability, for: audience)
            }
        )
    }

    private func audienceTitle(_ audience: RemoteFilePermissionAudience) -> String {
        switch audience {
        case .owner:
            return String(localized: "Owner")
        case .group:
            return String(localized: "Group")
        case .everyone:
            return String(localized: "Everyone")
        }
    }

    private func capabilityTitle(_ capability: RemoteFilePermissionCapability) -> String {
        switch capability {
        case .read:
            return String(localized: "Read")
        case .write:
            return String(localized: "Write")
        case .execute:
            return entry.type == .directory
                ? String(localized: "Open Folder")
                : String(localized: "Run")
        }
    }

    private func capabilityDescription(_ capability: RemoteFilePermissionCapability) -> String {
        switch (entry.type, capability) {
        case (.directory, .read):
            return String(localized: "See the names of items inside this folder.")
        case (.directory, .write):
            return String(localized: "Create, rename, or remove items inside this folder.")
        case (.directory, .execute):
            return String(localized: "Open this folder and access items inside it.")
        case (_, .read):
            return String(localized: "Open the file and read its contents.")
        case (_, .write):
            return String(localized: "Change or replace the file contents.")
        case (_, .execute):
            return String(localized: "Run this file as a program or script.")
        }
    }

    private func accessSummary(for audience: RemoteFilePermissionAudience) -> String {
        let granted = RemoteFilePermissionCapability.allCases.compactMap { capability -> String? in
            guard draft.isEnabled(capability, for: audience) else { return nil }
            return capabilityTitle(capability)
        }

        if granted.isEmpty {
            return String(localized: "No access")
        }

        return granted.joined(separator: ", ")
    }

    private var summaryModeString: String {
        let octal = String((preservedBits | draft.accessBits) & 0o7777, radix: 8)
        let padded = String(repeating: "0", count: max(0, 4 - octal.count)) + octal
        return "\(padded) (\(draft.symbolicSummary))"
    }

    private var footerDescription: String {
        if entry.type == .directory {
            return String(localized: "Folder permissions control who can view, change, and enter this folder.")
        }

        return String(localized: "File permissions control who can open, change, or run this file.")
    }
}
