import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class ProUpgradeWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = ProUpgradeWindowPresenter()

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private override init() {}

    func show<Content: View>(
        storeManager: StoreManager,
        source: PaywallSource = .general,
        onClose: @escaping () -> Void,
        @ViewBuilder content: (_ close: @escaping () -> Void) -> Content
    ) {
        if let window, window.isVisible {
            self.onClose = onClose
            ProUpgradeWindowChrome.configure(window, setInitialSize: false, source: source)
            // The sheet's .task does not rerun on window reuse, so record the new source here.
            storeManager.notePaywallPresented(source: source)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = content { [weak self] in
            self?.close()
        }
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        ProUpgradeWindowChrome.configure(window, setInitialSize: true, source: source)

        self.window = window
        self.onClose = onClose
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let closeHandler = onClose
        onClose = nil
        closeHandler?()
    }
}

enum ProUpgradeWindowChrome {
    private static let toolbarIdentifier = NSToolbar.Identifier("ProUpgradeWindowToolbar")
    private static let titlebarAccessoryIdentifier = NSUserInterfaceItemIdentifier("ProUpgradeTitlebarAccessory")

    static func configure(_ window: NSWindow, setInitialSize: Bool, source: PaywallSource = .general) {
        window.title = source.paywallTitle
        window.subtitle = source.paywallSubtitle
        window.styleMask.insert([.titled, .closable, .resizable])
        window.styleMask.remove(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 620)

        if setInitialSize {
            window.setContentSize(NSSize(width: 520, height: 780))
        }

        if window.toolbar?.identifier != toolbarIdentifier {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        } else {
            window.toolbar?.showsBaselineSeparator = false
        }
        window.toolbarStyle = .unified

        installTitlebarAccessory(in: window, source: source)
    }

    private static func installTitlebarAccessory(in window: NSWindow, source: PaywallSource) {
        if let existing = window.titlebarAccessoryViewControllers.first(where: {
            $0.view.identifier == titlebarAccessoryIdentifier
        }) {
            (existing.view as? ProUpgradeTitlebarView)?.updateText(source: source)
            return
        }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = ProUpgradeTitlebarView(identifier: titlebarAccessoryIdentifier, source: source)
        window.addTitlebarAccessoryViewController(accessory)
    }
}

private final class ProUpgradeTitlebarView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, source: PaywallSource) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 42))
        self.identifier = identifier
        setup()
        updateText(source: source)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updateText(source: PaywallSource) {
        titleField.stringValue = source.paywallTitle
        subtitleField.stringValue = source.paywallSubtitle
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        subtitleField.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            heightAnchor.constraint(equalToConstant: 42),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1)
        ])
    }
}
#endif
