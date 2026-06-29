//
//  Ghostty.ConfigBuilder.swift
//  VVTerm
//
//  Ghostty terminal configuration text generation.
//

import Foundation

extension Ghostty {
    nonisolated enum ConfigBuilder {
        static func sanitizedFontFamilies(primaryFamily: String) -> [String] {
            #if os(macOS)
            let candidates = [primaryFamily] + TerminalDefaults.macOSFallbackFontFamilies
            #else
            let candidates = [primaryFamily]
            #endif

            var seen = Set<String>()
            var families: [String] = []

            for candidate in candidates {
                let family = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !family.isEmpty else { continue }
                guard seen.insert(family).inserted else { continue }
                families.append(family)
            }

            return families
        }

        static func escapedFontFamilyValue(_ family: String) -> String {
            family
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        static func fontFamilyLines(primaryFamily: String) -> String {
            sanitizedFontFamilies(primaryFamily: primaryFamily)
                .map { "font-family = \"\(escapedFontFamilyValue($0))\"" }
                .joined(separator: "\n")
        }

        static func safeOutputProfileLines() -> String {
            #if os(iOS)
            """
            # iOS safe output profile
            image-storage-limit = 0
            clipboard-write = deny
            custom-shader = ""
            background-image = ""
            background-opacity = 1
            background-blur = false
            osc8-hyperlinks = false
            osc8-max-uri-bytes = 2048
            osc8-max-id-bytes = 256
            font-fallback-limit = 8
            glyph-atlas-max-size = 2048
            color-glyphs = false
            """
            #else
            ""
            #endif
        }

        static func configContent(
            primaryFontFamily: String,
            fontSize: Double,
            shellName: String,
            themeName: String,
            cursorStyle: TerminalCursorStyle = TerminalDefaults.defaultCursorStyle,
            cursorBlink: Bool = TerminalDefaults.defaultCursorBlink
        ) -> String {
            """
            \(fontFamilyLines(primaryFamily: primaryFontFamily))
            font-size = \(Int(fontSize))
            window-inherit-font-size = false
            window-padding-balance = false
            window-padding-x = 0
            window-padding-y = 0
            window-padding-color = extend-always

            # Enable shell integration (resources dir auto-detected from app bundle)
            shell-integration = \(shellName)
            shell-integration-features = no-cursor,sudo,title

            # Cursor
            cursor-style = \(cursorStyle.rawValue)
            cursor-style-blink = \(cursorBlink ? "true" : "false")

            theme = \(themeName)

            # Disable audible bell
            audible-bell = false

            # Limit scrollback to prevent unbounded memory growth
            # 10000 lines is plenty for most use cases (~5-10MB)
            scrollback-limit = 10000

            \(safeOutputProfileLines())

            # Faster scroll speed (especially for iOS touch)
            mouse-scroll-multiplier = 3

            # Custom keybinds
            keybind = shift+enter=text:\\n

            """
        }
    }
}
