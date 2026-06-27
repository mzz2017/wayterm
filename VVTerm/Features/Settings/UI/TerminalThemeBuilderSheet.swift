import SwiftUI

struct ThemeBuilderSheet: View {
    let usePerAppearanceTheme: Bool
    let showApplyTarget: Bool
    let title: String
    let preservedExtraLines: [String]
    let onDeleteRequest: (() throws -> Void)?
    let onSave: (String, String, CustomThemeApplyTarget) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var background: String
    @State private var foreground: String
    @State private var cursorColor: String
    @State private var cursorText: String
    @State private var selectionBackground: String
    @State private var selectionForeground: String
    @State private var paletteColors: [String]
    @State private var applyTarget: CustomThemeApplyTarget
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    private struct ParsedThemeValues {
        var background = "#101418"
        var foreground = "#D8E0EA"
        var cursorColor = "#F8B26A"
        var cursorText = "#101418"
        var selectionBackground = "#2E3A46"
        var selectionForeground = "#D8E0EA"
        var paletteColors = Array(repeating: "", count: 16)
        var extraLines: [String] = []
    }

    init(
        usePerAppearanceTheme: Bool,
        showApplyTarget: Bool? = nil,
        title: String = "Theme Builder",
        initialName: String = "Custom Theme",
        initialContent: String? = nil,
        initialApplyTarget: CustomThemeApplyTarget = .dark,
        onDeleteRequest: (() throws -> Void)? = nil,
        onSave: @escaping (String, String, CustomThemeApplyTarget) throws -> Void
    ) {
        self.usePerAppearanceTheme = usePerAppearanceTheme
        self.showApplyTarget = showApplyTarget ?? usePerAppearanceTheme
        self.title = title
        self.onDeleteRequest = onDeleteRequest
        self.onSave = onSave

        let parsed = Self.parseThemeValues(from: initialContent)
        self.preservedExtraLines = parsed.extraLines

        _name = State(initialValue: initialName)
        _background = State(initialValue: parsed.background)
        _foreground = State(initialValue: parsed.foreground)
        _cursorColor = State(initialValue: parsed.cursorColor)
        _cursorText = State(initialValue: parsed.cursorText)
        _selectionBackground = State(initialValue: parsed.selectionBackground)
        _selectionForeground = State(initialValue: parsed.selectionForeground)
        _paletteColors = State(initialValue: parsed.paletteColors)
        _applyTarget = State(initialValue: initialApplyTarget)
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard TerminalThemeValidator.isValidHexColor(background) else { return false }
        guard TerminalThemeValidator.isValidHexColor(foreground) else { return false }
        guard cursorColor.isEmpty || TerminalThemeValidator.isValidHexColor(cursorColor) else { return false }
        guard cursorText.isEmpty || TerminalThemeValidator.isValidHexColor(cursorText) else { return false }
        guard selectionBackground.isEmpty || TerminalThemeValidator.isValidHexColor(selectionBackground) else { return false }
        guard selectionForeground.isEmpty || TerminalThemeValidator.isValidHexColor(selectionForeground) else { return false }
        guard paletteColors.allSatisfy({ $0.isEmpty || TerminalThemeValidator.isValidHexColor($0) }) else { return false }
        return true
    }

    private var previewBackground: Color {
        previewColor(for: background, fallback: Color.fromHex("#101418"))
    }

    private var previewForeground: Color {
        previewColor(for: foreground, fallback: Color.fromHex("#D8E0EA"))
    }

    private var previewCursorColor: Color {
        previewColor(for: cursorColor, fallback: Color.fromHex("#F8B26A"))
    }

    private var previewCursorText: Color {
        previewColor(for: cursorText, fallback: previewBackground)
    }

    private var previewSelectionBackground: Color {
        previewColor(for: selectionBackground, fallback: Color.fromHex("#2E3A46"))
    }

    private var previewSelectionForeground: Color {
        previewColor(for: selectionForeground, fallback: previewForeground)
    }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationStack {
                formContent
                .environment(\.defaultMinListRowHeight, 34)
                .modifier(ThemeBuilderCompactListSectionSpacingModifier())
                .modifier(ThemeBuilderTransparentNavigationBarModifier())
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarAppearance(
                    backgroundColor: .clear,
                    isTranslucent: true,
                    shadowColor: .clear
                )
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .tint(.secondary)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(!canSave)
                    }
                    if onDeleteRequest != nil {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("Remove Theme", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                            .tint(.red)

                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            #else
            VStack(spacing: 0) {
                DialogSheetHeader(title: LocalizedStringKey(title)) {
                    dismiss()
                }

                Divider()

                formContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                macActionRow
            }
            #endif
        }
        .alert("Delete Custom Theme?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                do {
                    try onDeleteRequest?()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
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
                    sectionHeader("Theme")
                }

                Section {
                    colorField(String(localized: "Background"), text: $background, placeholder: "#101418", fallback: Color.fromHex("#101418"))
                    colorField(String(localized: "Foreground"), text: $foreground, placeholder: "#D8E0EA", fallback: Color.fromHex("#D8E0EA"))
                } header: {
                    sectionHeader("Required Colors")
                }

                Section {
                    colorField(String(localized: "Cursor"), text: $cursorColor, placeholder: "#F8B26A", fallback: Color.fromHex("#F8B26A"))
                    colorField(String(localized: "Cursor Text"), text: $cursorText, placeholder: "#101418", fallback: previewBackground)
                    colorField(String(localized: "Selection Background"), text: $selectionBackground, placeholder: "#2E3A46", fallback: Color.fromHex("#2E3A46"))
                    colorField(String(localized: "Selection Foreground"), text: $selectionForeground, placeholder: "#D8E0EA", fallback: Color.fromHex("#D8E0EA"))
                } header: {
                    sectionHeader("Optional Colors")
                } footer: {
                    Text("Leave optional values empty to keep defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(0..<16, id: \.self) { index in
                        colorField(
                            String(
                                format: String(localized: "Palette %lld"),
                                Int64(index)
                            ),
                            text: paletteColorBinding(index),
                            placeholder: paletteFallbackHex(index),
                            fallback: Color.fromHex(paletteFallbackHex(index))
                        )
                    }
                } header: {
                    sectionHeader("Palette (0-15)")
                } footer: {
                    Text("Optional ANSI palette entries. Leave empty to use Ghostty defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    terminalPreview
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 126)
                } header: {
                    sectionHeader("Preview")
                }

                if showApplyTarget {
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

    #if os(macOS)
    private var macActionRow: some View {
        HStack(spacing: 10) {
            if onDeleteRequest != nil {
                Button("Remove Theme", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

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

    private var terminalPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("restty@prod-web-01:~$ printenv APP_ENV")

            HStack(spacing: 6) {
                Text("APP_ENV=")
                    .foregroundStyle(previewForeground.opacity(0.78))
                Text("production")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(previewSelectionBackground)
                    .foregroundStyle(previewSelectionForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            HStack(spacing: 6) {
                Text("cursor>")
                    .foregroundStyle(previewForeground.opacity(0.78))
                Text("A")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(previewCursorColor)
                    .foregroundStyle(previewCursorText)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("selection")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(previewSelectionBackground)
                    .foregroundStyle(previewSelectionForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Rectangle()
                .fill(previewForeground.opacity(0.16))
                .frame(height: 1)

            Text("ANSI Palette")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(previewForeground.opacity(0.82))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 26), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<16, id: \.self) { index in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palettePreviewColor(index))
                            .frame(height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(previewForeground.opacity(0.18), lineWidth: 1)
                            )
                        Text("\(index)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(previewForeground.opacity(0.8))
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .foregroundStyle(previewForeground)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(previewBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(previewForeground.opacity(0.15), lineWidth: 1)
        )
    }

    private func colorField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        fallback: Color
    ) -> some View {
        #if os(iOS)
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)

            Spacer(minLength: 8)

            TextField("", text: text, prompt: Text(placeholder))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 110, maxWidth: 170, alignment: .trailing)

            ThemeBuilderColorSwatchPicker(
                label: label,
                text: text,
                fallback: fallback
            )
        }
        #else
        HStack(spacing: 10) {
            ThemeBuilderColorSwatchPicker(
                label: label,
                text: text,
                fallback: fallback
            )

            TextField(label, text: text, prompt: Text(placeholder))
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                #endif
                .font(.system(.body, design: .monospaced))
        }
        #endif
    }

    private func paletteColorBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { paletteColors[index] },
            set: { paletteColors[index] = $0 }
        )
    }

    private func paletteFallbackHex(_ index: Int) -> String {
        let defaults = [
            "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
            "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
            "#666666", "#D54E53", "#B9CA4A", "#E7C547",
            "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA"
        ]
        guard defaults.indices.contains(index) else { return "#808080" }
        return defaults[index]
    }

    private func palettePreviewColor(_ index: Int) -> Color {
        guard paletteColors.indices.contains(index) else {
            return Color.fromHex(paletteFallbackHex(index))
        }
        return previewColor(
            for: paletteColors[index],
            fallback: Color.fromHex(paletteFallbackHex(index))
        )
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

    #if os(iOS)
    private struct ThemeBuilderCompactListSectionSpacingModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 17.0, *) {
                content.listSectionSpacing(.compact)
            } else {
                content
            }
        }
    }

    private struct ThemeBuilderTransparentNavigationBarModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 16.0, *) {
                content.toolbarBackground(.hidden, for: .navigationBar)
            } else {
                content
            }
        }
    }
    #endif

    private static func parseThemeValues(from content: String?) -> ParsedThemeValues {
        guard let content, !content.isEmpty else {
            return ParsedThemeValues()
        }

        var parsed = ParsedThemeValues()
        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                parsed.extraLines.append(trimmed)
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "palette" {
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                guard
                    paletteParts.count == 2,
                    let paletteIndex = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                    (0..<16).contains(paletteIndex),
                    let paletteColor = TerminalThemeValidator.normalizeHexColor(String(paletteParts[1]))
                else {
                    parsed.extraLines.append(trimmed)
                    continue
                }
                parsed.paletteColors[paletteIndex] = paletteColor
                continue
            }

            let normalized = TerminalThemeValidator.normalizeHexColor(value) ?? value

            switch key {
            case "background":
                parsed.background = normalized
            case "foreground":
                parsed.foreground = normalized
            case "cursor-color":
                parsed.cursorColor = normalized
            case "cursor-text":
                parsed.cursorText = normalized
            case "selection-background":
                parsed.selectionBackground = normalized
            case "selection-foreground":
                parsed.selectionForeground = normalized
            default:
                parsed.extraLines.append("\(key) = \(value)")
            }
        }

        return parsed
    }

    private func save() {
        do {
            var lines: [String] = []
            lines.append("background = \(TerminalThemeValidator.normalizeHexColor(background) ?? background)")
            lines.append("foreground = \(TerminalThemeValidator.normalizeHexColor(foreground) ?? foreground)")

            if let value = TerminalThemeValidator.normalizeHexColor(cursorColor) {
                lines.append("cursor-color = \(value)")
            }
            if let value = TerminalThemeValidator.normalizeHexColor(cursorText) {
                lines.append("cursor-text = \(value)")
            }
            if let value = TerminalThemeValidator.normalizeHexColor(selectionBackground) {
                lines.append("selection-background = \(value)")
            }
            if let value = TerminalThemeValidator.normalizeHexColor(selectionForeground) {
                lines.append("selection-foreground = \(value)")
            }
            for index in 0..<paletteColors.count {
                if let value = TerminalThemeValidator.normalizeHexColor(paletteColors[index]) {
                    lines.append("palette = \(index)=\(value)")
                }
            }

            lines.append(contentsOf: preservedExtraLines)

            let content = lines.joined(separator: "\n") + "\n"
            let normalized = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
            try onSave(
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                normalized,
                showApplyTarget ? applyTarget : .dark
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func previewColor(for value: String, fallback: Color) -> Color {
        guard TerminalThemeValidator.isValidHexColor(value) else { return fallback }
        return Color.fromHex(value)
    }
}

private struct ThemeBuilderColorSwatchPicker: View {
    let label: String
    @Binding var text: String
    let fallback: Color

    private var swatchColor: Color {
        guard TerminalThemeValidator.isValidHexColor(text) else { return fallback }
        return Color.fromHex(text)
    }

    var body: some View {
        let pickColorLabel = String(
            format: String(localized: "Pick %@ color"),
            label
        )

        ColorPicker(
            pickColorLabel,
            selection: Binding(
                get: { swatchColor },
                set: { selectedColor in
                    text = selectedColor.toHex()
                }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .accessibilityLabel(pickColorLabel)
    }
}
