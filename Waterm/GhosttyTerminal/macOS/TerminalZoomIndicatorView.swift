//
//  TerminalZoomIndicatorView.swift
//  Waterm
//
//  macOS terminal zoom indicator presentation.
//

#if os(macOS)
import AppKit

final class TerminalZoomIndicatorView: NSVisualEffectView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: TerminalZoomPresentation.indicatorTitle)
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.alignment = .center

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        titleLabel.alignment = .center

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 3
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(valueLabel)
        stackView.addArrangedSubview(titleLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(fontSize: Double) {
        valueLabel.stringValue = TerminalZoomPresentation.formattedFontSize(fontSize)
    }
}

#endif
