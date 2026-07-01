#if os(macOS)
import AppKit

enum RemoteFileBrowserMacColumnID: String {
    case name
    case modifiedAt
    case size
    case kind

    init?(sort: RemoteFileSort) {
        switch sort {
        case .name: self = .name
        case .modifiedAt: self = .modifiedAt
        case .size: self = .size
        }
    }
}

final class RemoteFileBrowserMacNativeTableView: NSTableView {
    var menuProvider: ((Int?) -> NSMenu?)?
    var onSelectAll: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let row = self.row(at: location)
        return menuProvider?(row >= 0 ? row : nil)
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        onSelectAll?()
    }
}

final class RemoteFileBrowserMacNameCellView: NSTableCellView, NSTextFieldDelegate {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let editorField = RemoteFileBrowserMacInlineEditingTextField(string: "")
    private let progressIndicator = NSProgressIndicator()
    private var isConfiguringEditor = false
    private var suppressNextEndEditing = false
    private var onSubmit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = .secondaryLabelColor

        editorField.translatesAutoresizingMaskIntoConstraints = false
        editorField.font = .systemFont(ofSize: NSFont.systemFontSize)
        editorField.isBordered = false
        editorField.isBezeled = false
        editorField.drawsBackground = true
        editorField.backgroundColor = .textBackgroundColor
        editorField.focusRingType = .none
        editorField.lineBreakMode = .byTruncatingTail
        editorField.delegate = self
        editorField.wantsLayer = true
        editorField.onCancelOperation = { [weak self] in
            self?.onCancel?()
        }
        editorField.isHidden = true

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.controlSize = .small
        progressIndicator.style = .spinning
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(stack)
        addSubview(editorField)
        addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),

            editorField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            editorField.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -6),
            editorField.centerYAnchor.constraint(equalTo: centerYAnchor),
            editorField.heightAnchor.constraint(equalToConstant: 24),

            progressIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: RemoteFileEntry) {
        onSubmit = nil
        onCancel = nil
        suppressNextEndEditing = false
        titleField.stringValue = entry.name
        subtitleField.stringValue = entry.type == .symlink ? (entry.symlinkTarget ?? "") : ""
        subtitleField.isHidden = subtitleField.stringValue.isEmpty
        iconView.image = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: entry.name)
        iconView.contentTintColor = entry.type == .directory ? .systemBlue : .secondaryLabelColor
        titleField.isHidden = false
        editorField.isHidden = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
    }

    func configureInlineEditing(
        iconName: String,
        iconTintColor: NSColor,
        title: String,
        subtitle: String,
        proposedName: String,
        isSubmitting: Bool,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        suppressNextEndEditing = false

        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = true
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: title)
        iconView.contentTintColor = iconTintColor

        isConfiguringEditor = true
        editorField.stringValue = proposedName
        editorField.isEditable = !isSubmitting
        editorField.isSelectable = !isSubmitting
        editorField.textColor = isSubmitting ? .secondaryLabelColor : .labelColor
        editorField.placeholderString = proposedName.isEmpty ? title : nil
        editorField.applyInlineEditingAppearance(isSubmitting: isSubmitting)
        isConfiguringEditor = false

        titleField.isHidden = true
        editorField.isHidden = false
        progressIndicator.isHidden = !isSubmitting
        if isSubmitting {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    func requestEditingFocus() {
        guard !editorField.isHidden, !editorField.isHiddenOrHasHiddenAncestor, editorField.window != nil else { return }
        editorField.window?.makeFirstResponder(editorField)
        editorField.applyInlineEditingAppearance(isFocused: true, isSubmitting: !editorField.isEditable)
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editorField.currentEditor() else { return }
            editor.selectedRange = NSRange(location: 0, length: self.editorField.stringValue.count)
        }
    }

    var isEditingActive: Bool {
        guard let window = editorField.window else { return false }
        return window.firstResponder === editorField || window.firstResponder === editorField.currentEditor()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !editorField.isHidden, !isConfiguringEditor else { return }
        if suppressNextEndEditing {
            suppressNextEndEditing = false
            return
        }
        editorField.applyInlineEditingAppearance(isFocused: false, isSubmitting: !editorField.isEditable)
        let movement = notification.userInfo?["NSTextMovement"] as? Int ?? NSIllegalTextMovement
        if movement == NSCancelTextMovement {
            onCancel?()
            return
        }
        onSubmit?(editorField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            suppressNextEndEditing = true
            onSubmit?(editorField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            suppressNextEndEditing = true
            onCancel?()
            return true
        default:
            return false
        }
    }
}

final class RemoteFileBrowserMacTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
    }
}

final class RemoteFileBrowserMacInlineEditingTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { RemoteFileBrowserMacInlineEditingTextFieldCell.self }
        set {}
    }

    var onCancelOperation: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }

    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelOperation?()
    }

    func applyInlineEditingAppearance(isFocused: Bool = false, isSubmitting: Bool) {
        guard let layer else { return }

        let borderColor: NSColor
        if isSubmitting {
            borderColor = .separatorColor
        } else if isFocused {
            borderColor = .controlAccentColor
        } else {
            borderColor = .quaternaryLabelColor
        }

        layer.borderColor = borderColor.cgColor
        alphaValue = isSubmitting ? 0.8 : 1.0
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        applyInlineEditingAppearance(isFocused: true, isSubmitting: !isEditable)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        applyInlineEditingAppearance(isFocused: false, isSubmitting: !isEditable)
    }

    private func configureAppearance() {
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        textColor = .labelColor
        applyInlineEditingAppearance(isSubmitting: false)
    }
}

final class RemoteFileBrowserMacInlineEditingTextFieldCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 3

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        insetBounds(rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: insetBounds(rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: insetBounds(rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func insetBounds(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: horizontalInset, dy: verticalInset)
    }
}
#endif
