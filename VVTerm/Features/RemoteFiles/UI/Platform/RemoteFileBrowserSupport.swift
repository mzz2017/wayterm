import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import ObjectiveC.runtime
#else
import UIKit
#endif

struct RemoteFileIOSRow: View {
    let entry: RemoteFileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.iconName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(entry.type == .directory ? folderTint : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if entry.type == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []

        if let modifiedAt = entry.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }

        switch entry.type {
        case .directory:
            parts.append(String(localized: "Folder"))
        default:
            if let size = entry.size {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
        }

        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var folderTint: Color {
        Color.blue
    }
}

struct RemoteFileDownloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        self.sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: .immediate)
    }
}

struct RemoteFileShareItem: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let title: String
}

#if os(macOS)
struct RemoteFileSharePicker: NSViewRepresentable {
    let item: RemoteFileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.presentIfNeeded(item: item, from: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private let onComplete: () -> Void
        private var activeItemID: UUID?
        private var activePicker: NSSharingServicePicker?
        private var activeService: NSSharingService?
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func presentIfNeeded(item: RemoteFileShareItem, from view: NSView) {
            guard activeItemID != item.id else { return }

            activeItemID = item.id
            didFinish = false

            let picker = NSSharingServicePicker(items: [item.sourceURL])
            picker.delegate = self
            activePicker = picker

            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let service else {
                finish()
                return
            }

            activeService = service
            service.delegate = self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish()
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            finish()
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            activePicker = nil
            activeService = nil
            activeItemID = nil
            onComplete()
        }
    }
}
#else
struct RemoteFileShareSheet: UIViewControllerRepresentable {
    let item: RemoteFileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [item.sourceURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.finish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    final class Coordinator {
        private let onComplete: () -> Void
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            onComplete()
        }
    }
}

struct RemoteFileImportPicker: UIViewControllerRepresentable {
    let onComplete: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .folder],
            asCopy: true
        )
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Result<[URL], Error>) -> Void
        private var didFinish = false

        init(onComplete: @escaping (Result<[URL], Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.success([]))
        }

        private func finish(_ result: Result<[URL], Error>) {
            guard !didFinish else { return }
            didFinish = true
            onComplete(result)
        }
    }
}
#endif

extension UTType {
    static let vvtermRemoteFileEntry = UTType(exportedAs: "app.vivy.vvterm.remote-file-entry")
}

#if os(macOS)
@MainActor
final class MacOSMenuActionTarget: NSObject {
    private let actionHandler: () -> Void

    init(actionHandler: @escaping () -> Void) {
        self.actionHandler = actionHandler
    }

    @objc
    func performAction(_ sender: Any?) {
        actionHandler()
    }
}

struct MacOSWindowTopInsetBridge: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowUpdate = { [topInset = _topInset] window in
            let safeArea = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let measuredTopInset = max(
                window.frame.height - window.contentLayoutRect.height,
                safeArea.top
            )

            if abs(topInset.wrappedValue - measuredTopInset) > 0.5 {
                topInset.wrappedValue = measuredTopInset
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

private var macOSMenuActionTargetAssociationKey: UInt8 = 0

@MainActor
func makeMacOSMenuItem(
    title: String,
    systemImage: String? = nil,
    keyEquivalent: String = "",
    modifierMask: NSEvent.ModifierFlags = [],
    action: @escaping () -> Void
) -> NSMenuItem {
    let item = NSMenuItem(
        title: title,
        action: #selector(MacOSMenuActionTarget.performAction(_:)),
        keyEquivalent: keyEquivalent
    )
    item.keyEquivalentModifierMask = modifierMask
    if let systemImage {
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    }

    let target = MacOSMenuActionTarget(actionHandler: action)
    item.target = target
    objc_setAssociatedObject(
        item,
        &macOSMenuActionTargetAssociationKey,
        target,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return item
}

func makeMacOSSeparatorMenuItem() -> NSMenuItem {
    .separator()
}
#endif
