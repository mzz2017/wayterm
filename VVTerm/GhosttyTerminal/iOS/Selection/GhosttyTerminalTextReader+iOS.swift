//
//  GhosttyTerminalTextReader+iOS.swift
//  VVTerm
//
//  Focused C text-read helpers for the iOS Ghostty terminal view
//

#if os(iOS)
import UIKit

enum GhosttyTerminalTextReader {
    static func readViewportLine(
        surface: ghostty_surface_t,
        row: Int,
        columns: Int
    ) -> String {
        guard columns > 0 else { return "" }

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: UInt32(row)
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(columns - 1),
                y: UInt32(row)
            ),
            rectangle: true
        )

        let rawLine = readText(surface: surface, selection: selection) ?? ""
        return TerminalViewportTextSanitizer.sanitizedLine(rawLine, columns: columns)
    }

    static func readText(
        surface: ghostty_surface_t,
        selection: ghostty_selection_s
    ) -> String? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    static func readSelection(surface: ghostty_surface_t) -> String? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return string(from: text)
    }

    static func quickLookWordSelection(
        surface: ghostty_surface_t,
        layout: TerminalTouchSelectionLayout
    ) -> TerminalGridSelection? {
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return layout.selection(fromViewportText: text)
    }

    private static func string(from text: ghostty_text_s) -> String {
        guard let rawText = text.text else { return "" }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(rawText).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: buffer, as: UTF8.self)
    }
}

#endif
