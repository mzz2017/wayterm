import SwiftUI

#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct ProUpgradeWindowConfigurator: NSViewRepresentable {
    let source: PaywallSource

    func makeNSView(context: Context) -> WindowConfigurationView {
        WindowConfigurationView(source: source)
    }

    func updateNSView(_ nsView: WindowConfigurationView, context: Context) {
        nsView.source = source
        nsView.applyWindowConfiguration()
    }

    final class WindowConfigurationView: NSView {
        var source: PaywallSource

        init(source: PaywallSource) {
            self.source = source
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowConfiguration()
        }

        func applyWindowConfiguration() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                ProUpgradeWindowChrome.configure(window, setInitialSize: false, source: self.source)
            }
        }
    }
}
#endif

extension View {
    #if os(macOS)
    @MainActor
    func proUpgradePresentation(
        isPresented: Binding<Bool>,
        source: PaywallSource = .general
    ) -> some View {
        proUpgradePresentation(
            isPresented: isPresented,
            source: source,
            windowPresentation: .live
        )
    }

    func proUpgradePresentation(
        isPresented: Binding<Bool>,
        source: PaywallSource = .general,
        windowPresentation: ProUpgradeWindowPresentationService
    ) -> some View {
        modifier(
            ProUpgradePresentationModifier(
                isPresented: isPresented,
                source: source,
                windowPresentation: windowPresentation
            )
        )
    }
    #else
    func proUpgradePresentation(isPresented: Binding<Bool>, source: PaywallSource = .general) -> some View {
        modifier(ProUpgradePresentationModifier(isPresented: isPresented, source: source))
    }
    #endif
}

private struct ProUpgradePresentationModifier: ViewModifier {
    @EnvironmentObject private var storeManager: StoreManager
    @Binding var isPresented: Bool
    let source: PaywallSource
    #if os(macOS)
    let windowPresentation: ProUpgradeWindowPresentationService
    #endif

    #if os(macOS)
    init(
        isPresented: Binding<Bool>,
        source: PaywallSource,
        windowPresentation: ProUpgradeWindowPresentationService
    ) {
        _isPresented = isPresented
        self.source = source
        self.windowPresentation = windowPresentation
    }
    #else
    init(isPresented: Binding<Bool>, source: PaywallSource) {
        _isPresented = isPresented
        self.source = source
    }
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onAppear {
                if isPresented {
                    presentWindow()
                }
            }
            .onChangeCompat(of: isPresented) { shouldPresent in
                if shouldPresent {
                    presentWindow()
                } else {
                    windowPresentation.close()
                }
            }
        #else
        content
            .sheet(isPresented: $isPresented) {
                ProUpgradeSheet(source: source)
                    .environmentObject(storeManager)
            }
        #endif
    }

    #if os(macOS)
    private func presentWindow() {
        windowPresentation.show(storeManager, source, {
            isPresented = false
        }) { closeWindow in
            AnyView(
                ProUpgradeSheet(source: source, onDismiss: closeWindow)
                    .environmentObject(storeManager)
            )
        }
    }
    #endif
}
