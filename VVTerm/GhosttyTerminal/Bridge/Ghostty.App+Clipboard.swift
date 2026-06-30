import Foundation
import OSLog

extension Ghostty.App {
    static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        let surfaceContext = GhosttySurfaceCallbackContext.context(fromUserdata: userdata)
        return performClipboardReadOnMain(surfaceContext: surfaceContext, state: state)
    }

    private static func performClipboardReadOnMain(
        surfaceContext: GhosttySurfaceCallbackContext?,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                completeClipboardRead(surfaceContext: surfaceContext, state: state)
            }
        }

        var didStart = false
        DispatchQueue.main.sync {
            didStart = MainActor.assumeIsolated {
                completeClipboardRead(surfaceContext: surfaceContext, state: state)
            }
        }
        return didStart
    }

    @MainActor
    private static func completeClipboardRead(
        surfaceContext: GhosttySurfaceCallbackContext?,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let terminalView = surfaceContext?.resolveTerminalView() else { return false }
        guard let surface = terminalView.surfaceOwner.liveSurfaceHandle else { return false }

        let clipboardString = Clipboard.readString() ?? ""
        GhosttyClipboardBridge.completeReadRequest(
            surface: surface,
            string: clipboardString,
            state: state
        )

        Ghostty.logger.debug("Read clipboard: \(clipboardString.prefix(50))...")
        return true
    }

    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        #if os(iOS)
        guard location != GHOSTTY_CLIPBOARD_SELECTION else { return }
        #endif

        guard let string = GhosttyClipboardBridge.firstString(in: contents, count: count),
              !string.isEmpty else {
            return
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let cleanedString = TerminalTextCleaner.cleanText(string, settings: .current())
                guard !cleanedString.isEmpty else { return }

                Clipboard.copy(cleanedString)
                Ghostty.logger.debug("Wrote to clipboard: \(cleanedString.prefix(50))...")
            }
        }
    }
}
