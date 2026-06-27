//
//  TerminalSettingsView.swift
//  VVTerm
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum CustomThemeApplyTarget: String, CaseIterable, Identifiable {
    case dark
    case light
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        case .both: return String(localized: "Both")
        }
    }
}


private struct CursorStyleOptionView: View {
    let style: TerminalCursorStyle
    let isSelected: Bool
    let blinks: Bool
    let palette: TerminalThemePreviewPalette

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                TerminalCursorPreview(style: style, blinks: blinks, palette: palette)
                    .frame(width: 72, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            }

            Text(style.displayName)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .contentShape(Rectangle())
    }
}

private struct TerminalCursorPreview: View {
    let style: TerminalCursorStyle
    let blinks: Bool
    let palette: TerminalThemePreviewPalette

    var body: some View {
        if blinks {
            TimelineView(.periodic(from: .now, by: 0.55)) { timeline in
                previewContent(isVisible: cursorIsVisible(at: timeline.date))
            }
        } else {
            previewContent(isVisible: true)
        }
    }

    private func cursorIsVisible(at date: Date) -> Bool {
        guard blinks else { return true }
        let tick = Int(date.timeIntervalSinceReferenceDate / 0.55)
        return tick.isMultiple(of: 2)
    }

    private func previewContent(isVisible: Bool) -> some View {
        HStack(spacing: 0) {
            Text("~ ")
                .foregroundStyle(palette.foreground.opacity(0.55))
            cursorSample(isVisible: isVisible)
        }
        .font(.system(size: 19, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.foreground.opacity(0.14), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cursorSample(isVisible: Bool) -> some View {
        switch style {
        case .block:
            Text("A")
                .foregroundStyle(isVisible ? palette.cursorText : palette.foreground.opacity(0.75))
                .padding(.horizontal, 1)
                .background(
                    Rectangle()
                        .fill(isVisible ? palette.cursor : Color.clear)
                )
        case .bar:
            ZStack(alignment: .leading) {
                Text("A")
                    .foregroundStyle(palette.foreground.opacity(0.75))
                Rectangle()
                    .fill(isVisible ? palette.cursor : Color.clear)
                    .frame(width: 2, height: 23)
            }
        case .underline:
            ZStack(alignment: .bottom) {
                Text("A")
                    .foregroundStyle(palette.foreground.opacity(0.75))
                Rectangle()
                    .fill(isVisible ? palette.cursor : Color.clear)
                    .frame(width: 13, height: 2)
            }
        case .blockHollow:
            Text("A")
                .foregroundStyle(palette.foreground.opacity(0.75))
                .padding(.horizontal, 1)
                .overlay(
                    Rectangle()
                        .stroke(isVisible ? palette.cursor : Color.clear, lineWidth: 1.5)
                )
        }
    }
}

// MARK: - Terminal Settings View

struct TerminalSettingsView: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var themeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var themeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("terminalNotificationsEnabled") private var terminalNotificationsEnabled = true
    @AppStorage("terminalProgressEnabled") private var terminalProgressEnabled = true
    @AppStorage("terminalAccessoryCustomizationEnabled") private var terminalAccessoryCustomizationEnabled = true
    @AppStorage("terminalKeyboardDismissButtonEnabled") private var terminalKeyboardDismissButtonEnabled = true
    @AppStorage("terminalMultiplexerDefault") private var multiplexerDefaultRaw = TerminalMultiplexer.tmux.rawValue
    @AppStorage("terminalTmuxStartupBehaviorDefault") private var tmuxStartupBehaviorDefaultRaw = TmuxStartupBehavior.askEveryTime.rawValue

    // Copy settings
    @AppStorage("terminalCopyTrimTrailingWhitespace") private var copyTrimTrailingWhitespace = true
    @AppStorage("terminalCopyCollapseBlankLines") private var copyCollapseBlankLines = false
    @AppStorage("terminalCopyStripShellPrompts") private var copyStripShellPrompts = false
    @AppStorage("terminalCopyFlattenCommands") private var copyFlattenCommands = false
    @AppStorage("terminalCopyRemoveBoxDrawing") private var copyRemoveBoxDrawing = false
    @AppStorage("terminalCopyStripAnsiCodes") private var copyStripAnsiCodes = true

    // Image paste settings
    @AppStorage("terminalImagePasteBehavior") private var imagePasteBehaviorRaw = ImagePasteBehavior.askOnce.rawValue

    // SSH settings
    @AppStorage("sshKeepAliveEnabled") private var keepAliveEnabled = true
    @AppStorage("sshKeepAliveInterval") private var keepAliveInterval = 30
    @AppStorage("sshAutoReconnect") private var autoReconnect = true

    // Cursor settings
    @AppStorage(TerminalDefaults.cursorStyleKey) private var cursorStyleRaw = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var cursorBlink = TerminalDefaults.defaultCursorBlink

    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var trustedHostsStore: TrustedHostsSettingsStore

    @State private var availableFonts: [String] = []
    @State private var builtInThemeNames: [String] = []
    @State private var customThemeErrorMessage: String?
    @State private var showingCustomThemeManager = false
    @State private var showingResetKnownHostsConfirmation = false

    init(
        fontName: Binding<String>,
        fontSize: Binding<Double>,
        trustedHostsStore: TrustedHostsSettingsStore
    ) {
        _fontName = fontName
        _fontSize = fontSize
        _trustedHostsStore = ObservedObject(wrappedValue: trustedHostsStore)
    }

    private var builtInThemeOptions: [String] {
        Set(builtInThemeNames)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var customThemes: [TerminalTheme] {
        terminalThemeManager.customThemes
            .filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var customThemeOptions: [String] {
        let builtIn = Set(builtInThemeOptions)
        return customThemes.map(\.name).filter { !builtIn.contains($0) }
    }

    private var allThemeNames: [String] {
        builtInThemeOptions + customThemeOptions
    }

    private var customThemeCountLabel: String {
        let count = Int64(customThemes.count)
        return count == 1
            ? String(format: String(localized: "%lld custom theme"), count)
            : String(format: String(localized: "%lld custom themes"), count)
    }

    private var tmuxStartupBehaviorDefaultBinding: Binding<TmuxStartupBehavior> {
        Binding(
            get: { TmuxStartupBehavior(rawValue: tmuxStartupBehaviorDefaultRaw) ?? .askEveryTime },
            set: { tmuxStartupBehaviorDefaultRaw = $0.rawValue }
        )
    }

    private var imagePasteBehavior: ImagePasteBehavior {
        ImagePasteBehavior(rawValue: imagePasteBehaviorRaw) ?? .askOnce
    }

    private var imagePasteBehaviorBinding: Binding<ImagePasteBehavior> {
        Binding(
            get: { imagePasteBehavior },
            set: { behavior in
                imagePasteBehaviorRaw = behavior.rawValue
            }
        )
    }

    private var tmuxStartupBehaviorDefault: TmuxStartupBehavior {
        TmuxStartupBehavior(rawValue: tmuxStartupBehaviorDefaultRaw) ?? .askEveryTime
    }

    private var selectedCursorStyle: TerminalCursorStyle {
        TerminalCursorStyle(rawValue: cursorStyleRaw) ?? TerminalDefaults.defaultCursorStyle
    }

    private var cursorPreviewThemeName: String {
        guard usePerAppearanceTheme else { return themeName }

        switch appearanceMode {
        case "light":
            return themeNameLight
        case "dark":
            return themeName
        default:
            return colorScheme == .dark ? themeName : themeNameLight
        }
    }

    private var cursorPreviewPalette: TerminalThemePreviewPalette {
        ThemeColorParser.previewPalette(for: cursorPreviewThemeName)
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

    @ViewBuilder
    private var themePickerRows: some View {
        if !builtInThemeOptions.isEmpty {
            Section("Built-in") {
                ForEach(builtInThemeOptions, id: \.self) { theme in
                    Text(theme).tag(theme)
                }
            }
        }

        if !customThemeOptions.isEmpty {
            Section("Custom") {
                ForEach(customThemeOptions, id: \.self) { theme in
                    Text(theme).tag(theme)
                }
            }
        }
    }

    private var fontSection: some View {
        Section("Font") {
            Picker("Font Family", selection: $fontName) {
                ForEach(availableFonts, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
            .disabled(availableFonts.isEmpty)

            HStack {
                Text(String(format: String(localized: "Size: %lldpt"), Int64(fontSize)))
                    .frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { fontSize },
                    set: { fontSize = $0.rounded() }
                ), in: 4...32, step: 1)
                Stepper("", value: $fontSize, in: 4...32, step: 1)
                    .labelsHidden()
            }
        }
    }

    private var cursorSection: some View {
        Section("Cursor") {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    ForEach(TerminalCursorStyle.allCases) { style in
                        CursorStyleOptionView(
                            style: style,
                            isSelected: selectedCursorStyle == style,
                            blinks: cursorBlink,
                            palette: cursorPreviewPalette
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            cursorStyleRaw = style.rawValue
                        }
                        .accessibilityLabel(style.displayName)
                    }
                }

                Divider()

                HStack {
                    Text("Blink")
                    Spacer()
                    Toggle("Blink", isOn: $cursorBlink)
                        .labelsHidden()
                }
            }
        }
    }

    private var themeSection: some View {
        Section("Theme") {
            Toggle("Use different themes for Light/Dark mode", isOn: $usePerAppearanceTheme)

            if usePerAppearanceTheme {
                Picker("Dark Mode Theme", selection: $themeName) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)

                Picker("Light Mode Theme", selection: $themeNameLight) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)
            } else {
                Picker("Theme", selection: $themeName) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)
            }

            HStack(spacing: 10) {
                Button("Manage custom themes") {
                    showingCustomThemeManager = true
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Text(customThemeCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Clipboard content or imported files must be Ghostty-compatible theme text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var terminalBehaviorSection: some View {
        Section("Terminal Behavior") {
            Toggle("Enable terminal notifications", isOn: $terminalNotificationsEnabled)
            Toggle("Show progress overlays", isOn: $terminalProgressEnabled)
        }
    }

    @ViewBuilder
    private var keyboardAccessorySection: some View {
        #if os(iOS)
        if terminalAccessoryCustomizationEnabled {
            Section {
                Toggle("Show keyboard dismiss button", isOn: $terminalKeyboardDismissButtonEnabled)

                NavigationLink {
                    TerminalAccessoryCustomizationView()
                } label: {
                    Text("Customize Accessory Bar")
                }

                NavigationLink {
                    TerminalCustomActionLibraryView()
                } label: {
                    Text("Manage Custom Actions")
                }
            } header: {
                Text("Keyboard Accessory")
            } footer: {
                Text("Reorder actions, add custom actions, show or hide the keyboard dismiss button, and sync your accessory bar across devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #endif
    }

    private var sessionPersistenceSection: some View {
        Section {
            Picker("Session persistence", selection: Binding(
                get: { TerminalMultiplexer(rawValue: multiplexerDefaultRaw) ?? .tmux },
                set: { multiplexerDefaultRaw = $0.rawValue }
            )) {
                ForEach(TerminalMultiplexer.allCases) { mux in
                    Text(mux.displayName).tag(mux)
                }
            }

            if (TerminalMultiplexer(rawValue: multiplexerDefaultRaw) ?? .tmux).isEnabled {
                Picker("On connect", selection: tmuxStartupBehaviorDefaultBinding) {
                    ForEach(TmuxStartupBehavior.configCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(tmuxStartupBehaviorDefault.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session Persistence")
        } footer: {
            Text("Choose the default behavior for new servers. You can still override per server in server settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var copyProcessingSection: some View {
        Section {
            Toggle("Trim trailing whitespace", isOn: $copyTrimTrailingWhitespace)
            Toggle("Collapse multiple blank lines", isOn: $copyCollapseBlankLines)
            Toggle("Strip shell prompts ($ #)", isOn: $copyStripShellPrompts)
            Toggle("Flatten multi-line commands", isOn: $copyFlattenCommands)
            Toggle("Remove box-drawing characters", isOn: $copyRemoveBoxDrawing)
            Toggle("Strip ANSI escape codes", isOn: $copyStripAnsiCodes)
        } header: {
            Text("Copy Text Processing")
        } footer: {
            Text("Transformations applied when copying text from terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var richClipboardSection: some View {
        Section {
            Picker("Behavior", selection: imagePasteBehaviorBinding) {
                Text(ImagePasteBehavior.automatic.settingsTitle)
                    .tag(ImagePasteBehavior.automatic)
                Text(ImagePasteBehavior.askOnce.settingsTitle)
                    .tag(ImagePasteBehavior.askOnce)
                Text(ImagePasteBehavior.disabled.settingsTitle)
                    .tag(ImagePasteBehavior.disabled)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Image Paste")
        } footer: {
            Text(imagePasteSectionFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imagePasteSectionFooter: String {
        switch imagePasteBehavior {
        case .disabled:
            return String(localized: "Image paste is turned off.")
        case .askOnce:
            return String(localized: "You’ll be asked before the image is uploaded.")
        case .automatic:
            return String(localized: "Images upload right away without showing the confirmation sheet.")
        }
    }

    private var sshConnectionSection: some View {
        Section("SSH Connection") {
            Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
            Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)

            if keepAliveEnabled {
                Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
            }
        }
    }

    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                showingResetKnownHostsConfirmation = true
            } label: {
                Label("Reset Trusted SSH Hosts", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .tint(.red)
            .disabled(trustedHostsStore.knownHostCount == 0)
        } header: {
            Text("Danger Zone")
        } footer: {
            Text(knownHostsFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var knownHostsFooterText: String {
        let count = Int64(trustedHostsStore.knownHostCount)
        if count == 1 {
            return String(localized: "VVTerm has 1 trusted SSH host on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection.")
        }
        return String(format: String(localized: "VVTerm has %lld trusted SSH hosts on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection."), count)
    }

    var body: some View {
        Form {
            fontSection
            cursorSection
            themeSection
            terminalBehaviorSection
            keyboardAccessorySection
            sessionPersistenceSection
            copyProcessingSection
            richClipboardSection
            sshConnectionSection
            dangerZoneSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingCustomThemeManager) {
            ManageCustomThemesSheet(
                customThemes: customThemes,
                darkThemeName: $themeName,
                lightThemeName: $themeNameLight,
                usePerAppearanceTheme: usePerAppearanceTheme,
                onSuggestThemeName: { source in
                    terminalThemeManager.suggestThemeName(from: source)
                },
                onCreateTheme: { name, content, applyTarget in
                    try createAndApplyCustomTheme(name: name, content: content, applyTarget: applyTarget)
                },
                onDelete: { themeID in
                    try terminalThemeManager.deleteCustomTheme(id: themeID)
                    ensureThemeSelectionIsValid()
                },
                onSaveEdit: { themeID, name, content in
                    try terminalThemeManager.updateCustomTheme(
                        id: themeID,
                        name: name,
                        content: content
                    )
                    ensureThemeSelectionIsValid()
                }
            )
        }
        .alert("Custom Theme", isPresented: customThemeErrorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(customThemeErrorMessage ?? "")
        }
        .alert("Reset Trusted SSH Hosts", isPresented: $showingResetKnownHostsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetKnownHosts()
            }
        } message: {
            Text("VVTerm will forget all saved SSH host fingerprints on this device. The next connection to each host will trust the key it presents.")
        }
        .onChange(of: themeName) { _ in
            ensureThemeSelectionIsValid()
        }
        .onChange(of: themeNameLight) { _ in
            ensureThemeSelectionIsValid()
        }
        .onChange(of: usePerAppearanceTheme) { _ in
            ensureThemeSelectionIsValid()
        }
        .onChange(of: terminalThemeManager.customThemes) { _ in
            ensureThemeSelectionIsValid()
        }
        .onAppear {
            if availableFonts.isEmpty {
                availableFonts = Self.fontListEnsuringCurrentFont(
                    systemFonts: loadSystemFonts(),
                    currentFontName: fontName
                )
            }
            if builtInThemeNames.isEmpty {
                builtInThemeNames = TerminalThemeManager.builtInThemeNames()
            }
            ensureThemeSelectionIsValid()
            refreshKnownHostCount()
        }
    }

    /// Ensures the current primary font appears in the picker list.
    /// If the stored font name is missing from the system font list
    /// (e.g., a previously-installed font was removed), it is prepended
    /// so the Picker can display the current selection without breaking.
    static func fontListEnsuringCurrentFont(systemFonts: [String], currentFontName: String) -> [String] {
        let trimmed = currentFontName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return systemFonts }
        guard !systemFonts.contains(trimmed) else { return systemFonts }
        return [trimmed] + systemFonts
    }

    private func refreshKnownHostCount() {
        trustedHostsStore.refreshKnownHostCount()
    }

    private func resetKnownHosts() {
        trustedHostsStore.resetTrustedHosts()
    }

    #if os(macOS)
    private func loadSystemFonts() -> [String] {
        let fontManager = NSFontManager.shared
        return fontManager.availableFontFamilies.filter { familyName in
            guard let font = NSFont(name: familyName, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
    #else
    private func loadSystemFonts() -> [String] {
        var fonts = ["Menlo", "SF Mono", "Courier New"]
        let nerdFonts = [
            "JetBrainsMono Nerd Font",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "MesloLGS Nerd Font"
        ]

        for fontFamily in nerdFonts where UIFont(name: fontFamily, size: 12) != nil {
            fonts.append(fontFamily)
        }

        return fonts.sorted()
    }
    #endif

    private func ensureThemeSelectionIsValid() {
        let available = Set(allThemeNames)
        if !available.contains(themeName) {
            themeName = "Aizen Dark"
        }
        if !available.contains(themeNameLight) {
            themeNameLight = "Aizen Light"
        }
    }

    private func createAndApplyCustomTheme(name: String, content: String, applyTarget: CustomThemeApplyTarget) throws {
        let theme = try terminalThemeManager.createCustomTheme(name: name, content: content)
        applyThemeSelection(themeName: theme.name, applyTarget: applyTarget)
        ensureThemeSelectionIsValid()
    }

    private func applyThemeSelection(themeName: String, applyTarget: CustomThemeApplyTarget) {
        guard usePerAppearanceTheme else {
            self.themeName = themeName
            return
        }

        switch applyTarget {
        case .dark:
            self.themeName = themeName
        case .light:
            self.themeNameLight = themeName
        case .both:
            self.themeName = themeName
            self.themeNameLight = themeName
        }
    }
}
