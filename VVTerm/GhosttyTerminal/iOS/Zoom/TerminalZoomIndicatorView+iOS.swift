//
//  TerminalZoomIndicatorView+iOS.swift
//  VVTerm
//
//  UIKit zoom indicator view for iOS Ghostty terminal.
//

#if os(iOS)
import UIKit

final class TerminalZoomIndicatorView: UIVisualEffectView {
    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let stackView = UIStackView()

    override init(effect: UIVisualEffect? = UIBlurEffect(style: .systemChromeMaterialDark)) {
        super.init(effect: effect)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .center

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        titleLabel.textAlignment = .center
        titleLabel.text = TerminalZoomPresentation.indicatorTitle

        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 3
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(valueLabel)
        stackView.addArrangedSubview(titleLabel)
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -18),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(fontSize: Double) {
        valueLabel.text = TerminalZoomPresentation.formattedFontSize(fontSize)
    }
}

#endif
