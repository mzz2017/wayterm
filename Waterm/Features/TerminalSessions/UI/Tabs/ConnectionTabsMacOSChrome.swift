//
//  ConnectionTabsMacOSChrome.swift
//  Waterm
//

import SwiftUI
#if os(macOS)
import AppKit

extension View {
    @ViewBuilder
    func macOSZenExpandedTopSafeArea(_ isEnabled: Bool) -> some View {
        if isEnabled {
            ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
    }
}

struct MacOSZenWindowChromeBridge: NSViewRepresentable {
    @Binding var contentInsets: EdgeInsets

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowUpdate = { [contentInsets = _contentInsets] window in
            guard let closeButton = window.standardWindowButton(.closeButton),
                  let miniButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton) else { return }

            let buttons = [closeButton, miniButton, zoomButton]
            buttons.forEach { button in
                button.isHidden = false
                button.alphaValue = 1
                button.superview?.isHidden = false
                button.superview?.alphaValue = 1
            }

            let safeArea = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let titlebarHeight = max(
                window.frame.height - window.contentLayoutRect.height,
                safeArea.top
            )
            let newInsets = EdgeInsets(
                top: titlebarHeight,
                leading: safeArea.left,
                bottom: safeArea.bottom,
                trailing: safeArea.right
            )

            let currentInsets = contentInsets.wrappedValue
            let didChange =
                abs(currentInsets.top - newInsets.top) > 0.5 ||
                abs(currentInsets.leading - newInsets.leading) > 0.5 ||
                abs(currentInsets.bottom - newInsets.bottom) > 0.5 ||
                abs(currentInsets.trailing - newInsets.trailing) > 0.5

            if didChange {
                contentInsets.wrappedValue = newInsets
            }
        }
        nsView.triggerUpdate()
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.removeObservers()
    }

    final class WindowObserverView: NSView {
        var onWindowUpdate: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            triggerUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            triggerUpdate()
        }

        override func layout() {
            super.layout()
            triggerUpdate()
        }

        func triggerUpdate() {
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindowUpdate?(window)
            }
        }

        func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        private func installObservers() {
            removeObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            observers = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.triggerUpdate()
                }
            }
        }

        deinit {
            removeObservers()
        }
    }
}

struct MacOSToolbarBackdrop: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 52
            color
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
    }
}

#else

extension View {
    @ViewBuilder
    func macOSZenExpandedTopSafeArea(_ isEnabled: Bool) -> some View {
        self
    }
}

#endif
