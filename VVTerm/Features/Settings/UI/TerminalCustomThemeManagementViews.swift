import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private struct PendingCustomThemeSource: Identifiable {
    let id = UUID()
    var suggestedName: String
    var content: String
}

private struct CustomThemeSaveSheet: View {
    let suggestedName: String
    let usePerAppearanceTheme: Bool
    let onSave: (String, CustomThemeApplyTarget) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var applyTarget: CustomThemeApplyTarget = .dark
    @State private var errorMessage: String?

    init(
        suggestedName: String,
        usePerAppearanceTheme: Bool,
        onSave: @escaping (String, CustomThemeApplyTarget) throws -> Void
    ) {
        self.suggestedName = suggestedName
        self.usePerAppearanceTheme = usePerAppearanceTheme
        self.onSave = onSave
        _name = State(initialValue: suggestedName)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            formContent
            .navigationTitle("Save Custom Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
        #else
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Save Custom Theme") {
                dismiss()
            }

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
        .frame(width: 700, height: usePerAppearanceTheme ? 300 : 250)
        #endif
    }

    private var formContent: some View {
        Form {
            Section {
                #if os(iOS)
                HStack(spacing: 10) {
                    Text("Name")
                    Spacer(minLength: 8)
                    TextField("", text: $name, prompt: Text("Custom Theme"))
                        .multilineTextAlignment(.trailing)
                }
                #else
                TextField("Name", text: $name, prompt: Text("Custom Theme"))
                #endif
            } header: {
                sectionHeader("Theme Name")
            }

            if usePerAppearanceTheme {
                Section {
                    Picker("Target", selection: $applyTarget) {
                        ForEach(CustomThemeApplyTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    sectionHeader("Apply To")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        #else
        Text(title)
        #endif
    }

    #if os(macOS)
    private var macActionRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    #endif

    private func save() {
        do {
            try onSave(
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                usePerAppearanceTheme ? applyTarget : .dark
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ManageCustomThemesSheet: View {
    let customThemes: [TerminalTheme]
    @Binding var darkThemeName: String
    @Binding var lightThemeName: String
    let usePerAppearanceTheme: Bool
    let onSuggestThemeName: (String) -> String
    let onCreateTheme: (String, String, CustomThemeApplyTarget) throws -> Void
    let onDelete: (UUID) throws -> Void
    let onSaveEdit: (UUID, String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingThemeImporter = false
    @State private var showingThemeBuilder = false
    @State private var pendingCustomThemeSource: PendingCustomThemeSource?
    @State private var customThemeErrorMessage: String?
    @State private var themePendingDeletion: TerminalTheme?
    @State private var themePendingEdit: TerminalTheme?
    @State private var hoveredThemeID: UUID?

    private var sortedThemes: [TerminalTheme] {
        customThemes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var deleteThemeAlertBinding: Binding<Bool> {
        Binding(
            get: { themePendingDeletion != nil },
            set: { newValue in
                if !newValue {
                    themePendingDeletion = nil
                }
            }
        )
    }

    private var editThemeSheetBinding: Binding<TerminalTheme?> {
        Binding(
            get: { themePendingEdit },
            set: { themePendingEdit = $0 }
        )
    }

    private var customThemeErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { customThemeErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    customThemeErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        Group {
            #if os(iOS)
            iosBody
            #else
            macBody
            #endif
        }
        .sheet(item: editThemeSheetBinding) { theme in
            ThemeBuilderSheet(
                usePerAppearanceTheme: false,
                showApplyTarget: false,
                title: String(
                    format: String(localized: "Edit \"%@\""),
                    theme.name
                ),
                initialName: theme.name,
                initialContent: theme.content,
                onDeleteRequest: {
                    try deleteTheme(theme.id)
                    themePendingEdit = nil
                }
            ) { name, content, _ in
                try onSaveEdit(theme.id, name, content)
            }
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 600)
            #endif
        }
        .fileImporter(
            isPresented: $showingThemeImporter,
            allowedContentTypes: [.text, .data],
            allowsMultipleSelection: false
        ) { result in
            handleThemeImport(result)
        }
        .sheet(item: $pendingCustomThemeSource) { source in
            CustomThemeSaveSheet(
                suggestedName: source.suggestedName,
                usePerAppearanceTheme: usePerAppearanceTheme
            ) { name, applyTarget in
                try onCreateTheme(name, source.content, applyTarget)
            }
        }
        .sheet(isPresented: $showingThemeBuilder) {
            ThemeBuilderSheet(usePerAppearanceTheme: usePerAppearanceTheme) { name, content, applyTarget in
                try onCreateTheme(name, content, applyTarget)
            }
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 600)
            #endif
        }
        .alert("Delete Custom Theme?", isPresented: deleteThemeAlertBinding) {
            Button("Delete", role: .destructive) {
                if let themePendingDeletion {
                    do {
                        try deleteTheme(themePendingDeletion.id)
                    } catch {
                        customThemeErrorMessage = error.localizedDescription
                    }
                }
                themePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                themePendingDeletion = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Custom Theme", isPresented: customThemeErrorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(customThemeErrorMessage ?? "")
        }
    }

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            Group {
                if sortedThemes.isEmpty {
                    customThemesEmptyState
                } else {
                    List {
                        ForEach(sortedThemes) { theme in
                            iOSThemeRow(theme)
                        }
                    }
                }
            }
            .navigationTitle("Custom Themes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        createThemeMenuItems
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private func iOSThemeRow(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let assignment = assignmentLabel(for: theme.name) {
                    Text(assignment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Menu {
                applyMenuItems(themeName: theme.name)

                Divider()

                Button("Edit") {
                    themePendingEdit = theme
                }

                Button("Delete", role: .destructive) {
                    themePendingDeletion = theme
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Edit") {
                themePendingEdit = theme
            }
            .tint(.blue)

            Button("Delete", role: .destructive) {
                themePendingDeletion = theme
            }
        }
    }
    #endif

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Custom Themes") {
                dismiss()
            }

            Divider()

            if sortedThemes.isEmpty {
                customThemesEmptyState
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sortedThemes) { theme in
                            let assignment = assignmentLabel(for: theme.name)
                            CustomThemeManagerRow(
                                theme: theme,
                                assignment: assignment,
                                usePerAppearanceTheme: usePerAppearanceTheme,
                                isHovered: hoveredThemeID == theme.id,
                                isSelected: assignment != nil,
                                onApply: { target in
                                    applyThemeSelection(themeName: theme.name, applyTarget: target)
                                },
                                onEdit: {
                                    themePendingEdit = theme
                                },
                                onDeleteRequest: {
                                    themePendingDeletion = theme
                                }
                            )
                            .onHover { hovering in
                                hoveredThemeID = hovering ? theme.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            Divider()

            HStack {
                Menu {
                    createThemeMenuItems
                } label: {
                    Label("New Custom Theme", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 400, height: 500)
    }
    #endif

    private var customThemesEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "paintpalette")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text("No Custom Themes")
                .font(.headline.weight(.semibold))

            Text("Create your first custom theme from clipboard, file import, or builder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func assignmentLabel(for theme: String) -> String? {
        if usePerAppearanceTheme {
            let usesDark = darkThemeName == theme
            let usesLight = lightThemeName == theme

            switch (usesDark, usesLight) {
            case (true, true):
                return String(localized: "Dark + Light")
            case (true, false):
                return String(localized: "Dark")
            case (false, true):
                return String(localized: "Light")
            case (false, false):
                return nil
            }
        }

        return darkThemeName == theme ? String(localized: "Active") : nil
    }

    private func deleteTheme(_ themeID: UUID) throws {
        try onDelete(themeID)
    }

    @ViewBuilder
    private func applyMenuItems(themeName: String) -> some View {
        if usePerAppearanceTheme {
            Button("Apply to Dark") {
                applyThemeSelection(themeName: themeName, applyTarget: .dark)
            }
            Button("Apply to Light") {
                applyThemeSelection(themeName: themeName, applyTarget: .light)
            }
            Button("Apply to Both") {
                applyThemeSelection(themeName: themeName, applyTarget: .both)
            }
        } else {
            Button("Use Theme") {
                applyThemeSelection(themeName: themeName, applyTarget: .dark)
            }
        }
    }

    @ViewBuilder
    private var createThemeMenuItems: some View {
        Button("Paste from Clipboard") {
            importThemeFromClipboard()
        }
        Button("Import from File") {
            showingThemeImporter = true
        }
        Button("Builder") {
            showingThemeBuilder = true
        }
    }

    private func importThemeFromClipboard() {
        #if os(iOS)
        guard let text = UIPasteboard.general.string else {
            customThemeErrorMessage = String(localized: "Clipboard does not contain text.")
            return
        }
        #elseif os(macOS)
        guard let text = NSPasteboard.general.string(forType: .string) else {
            customThemeErrorMessage = String(localized: "Clipboard does not contain text.")
            return
        }
        #else
        customThemeErrorMessage = String(localized: "Clipboard import is not supported on this platform.")
        return
        #endif

        preparePendingCustomTheme(content: text, suggestedName: String(localized: "Pasted Theme"))
    }

    private func handleThemeImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                customThemeErrorMessage = String(localized: "Cannot access selected file.")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let suggestedName = url.deletingPathExtension().lastPathComponent
                preparePendingCustomTheme(content: content, suggestedName: suggestedName)
            } catch {
                customThemeErrorMessage = String(
                    format: String(localized: "Failed to import theme file: %@"),
                    error.localizedDescription
                )
            }
        case .failure(let error):
            customThemeErrorMessage = String(
                format: String(localized: "Failed to import theme file: %@"),
                error.localizedDescription
            )
        }
    }

    private func preparePendingCustomTheme(content: String, suggestedName: String) {
        do {
            let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
            pendingCustomThemeSource = PendingCustomThemeSource(
                suggestedName: onSuggestThemeName(suggestedName),
                content: normalizedContent
            )
        } catch {
            customThemeErrorMessage = error.localizedDescription
        }
    }

    private func applyThemeSelection(themeName: String, applyTarget: CustomThemeApplyTarget) {
        guard usePerAppearanceTheme else {
            darkThemeName = themeName
            return
        }

        switch applyTarget {
        case .dark:
            darkThemeName = themeName
        case .light:
            lightThemeName = themeName
        case .both:
            darkThemeName = themeName
            lightThemeName = themeName
        }
    }
}

#if os(macOS)
private struct CustomThemeManagerRow: View {
    let theme: TerminalTheme
    let assignment: String?
    let usePerAppearanceTheme: Bool
    let isHovered: Bool
    let isSelected: Bool
    let onApply: (CustomThemeApplyTarget) -> Void
    let onEdit: () -> Void
    let onDeleteRequest: () -> Void

    @Environment(\.controlActiveState) private var controlActiveState

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    private var selectedTextColor: Color {
        Color(nsColor: .selectedTextColor)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(theme.name)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? selectedTextColor : .primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let assignment {
                PillBadge(text: assignment, color: .secondary)
            }

            if isHovered || isSelected {
                Menu {
                    applyMenuItems
                } label: {
                    Image(systemName: "paintbrush.pointed.fill")
                        .foregroundStyle(isSelected ? selectedTextColor.opacity(0.9) : .secondary)
                        .imageScale(.medium)
                }
                .menuStyle(.borderlessButton)

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(isSelected ? selectedTextColor.opacity(0.9) : .secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? selectionFillColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if usePerAppearanceTheme {
                onApply(.both)
            } else {
                onApply(.dark)
            }
        }
        .contextMenu {
            applyMenuItems
            Divider()
            Button("Edit") {
                onEdit()
            }
            Button("Delete", role: .destructive) {
                onDeleteRequest()
            }
        }
    }

    @ViewBuilder
    private var applyMenuItems: some View {
        if usePerAppearanceTheme {
            Button("Apply to Dark") {
                onApply(.dark)
            }
            Button("Apply to Light") {
                onApply(.light)
            }
            Button("Apply to Both") {
                onApply(.both)
            }
        } else {
            Button("Use Theme") {
                onApply(.dark)
            }
        }
    }
}
#endif
