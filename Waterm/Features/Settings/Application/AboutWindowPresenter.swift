import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class AboutWindowPresenter {
    static let shared = AboutWindowPresenter()

    private var window: NSWindow?

    private init() {}

    func show<Content: View>(@ViewBuilder content: () -> Content) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: content())
        hostingView.setFrameSize(hostingView.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: hostingView.fittingSize.width,
                height: hostingView.fittingSize.height
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "About Waterm")
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
#endif
