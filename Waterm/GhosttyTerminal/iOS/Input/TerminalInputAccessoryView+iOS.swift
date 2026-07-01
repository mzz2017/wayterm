//
//  TerminalInputAccessoryView+iOS.swift
//  Waterm
//
//  UIKit keyboard accessory toolbar for iOS Ghostty terminal input.
//

#if os(iOS)
import UIKit
import CoreImage
import SwiftUI

// MARK: - Native UIKit Input Accessory View with Glass Effect

class TerminalInputAccessoryView: UIInputView {
    private let onKey: (TerminalKey) -> Void
    private let onCustomAction: (TerminalAccessoryCustomAction) -> Void
    private let onDismissKeyboard: () -> Void
    var onVoice: (() -> Void)? {
        didSet {
            updateLeadingButtonsState()
        }
    }
    private var ctrlActive = false
    private var altActive = false
    private var commandActive = false
    private var shiftActive = false
    private weak var ctrlButton: UIButton?
    private weak var altButton: UIButton?
    private weak var commandButton: UIButton?
    private weak var shiftButton: UIButton?
    private weak var voiceButton: UIButton?
    private weak var dismissKeyboardButton: UIButton?
    private weak var leadingButtonsStack: UIStackView?
    private weak var leadingButtonsSeparatorView: UIView?
    private weak var backgroundEffectView: UIVisualEffectView?
    private weak var dynamicItemsStack: UIStackView?
    private var scrollLeadingToLeadingButtonsConstraint: NSLayoutConstraint?
    private var scrollLeadingToEdgeConstraint: NSLayoutConstraint?
    nonisolated private let observerTokens = NotificationObserverTokens()
    nonisolated private let keyRepeatOwner = TerminalInputKeyRepeatOwner()

    init(
        onKey: @escaping (TerminalKey) -> Void,
        onCustomAction: @escaping (TerminalAccessoryCustomAction) -> Void,
        onVoice: (() -> Void)? = nil,
        onDismissKeyboard: @escaping () -> Void
    ) {
        self.onKey = onKey
        self.onCustomAction = onCustomAction
        self.onVoice = onVoice
        self.onDismissKeyboard = onDismissKeyboard
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48), inputViewStyle: .keyboard)
        setupView()
        observeThemeChanges()
        observeAccessoryProfileChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        observerTokens.invalidateAll()
        keyRepeatOwner.stop()
    }

    private func setupView() {
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear

        let blur = UIVisualEffectView(effect: nil)
        blur.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(blur, at: 0)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        backgroundEffectView = blur
        updateBackgroundEffect()

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        let leadingStack = UIStackView()
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.axis = .horizontal
        leadingStack.spacing = 8
        leadingStack.alignment = .center
        leadingStack.distribution = .fill
        addSubview(leadingStack)
        leadingButtonsStack = leadingStack

        let voice = makeIconButton(icon: "mic.fill") { [weak self] in
            self?.onVoice?()
        }
        voice.accessibilityLabel = String(localized: "Voice input")
        voiceButton = voice
        leadingStack.addArrangedSubview(voice)

        let dismissKeyboard = makeIconButton(icon: "keyboard.chevron.compact.down") { [weak self] in
            self?.onDismissKeyboard()
        }
        dismissKeyboard.accessibilityLabel = String(localized: "Hide keyboard")
        dismissKeyboardButton = dismissKeyboard
        leadingStack.addArrangedSubview(dismissKeyboard)

        let leadingButtonsSeparator = makeSeparator()
        leadingButtonsSeparatorView = leadingButtonsSeparator
        addSubview(leadingButtonsSeparator)

        let leadingToButtons = scrollView.leadingAnchor.constraint(equalTo: leadingButtonsSeparator.trailingAnchor, constant: 10)
        let leadingToEdge = scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        scrollLeadingToLeadingButtonsConstraint = leadingToButtons
        scrollLeadingToEdgeConstraint = leadingToEdge

        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            leadingButtonsSeparator.leadingAnchor.constraint(equalTo: leadingStack.trailingAnchor, constant: 10),
            leadingButtonsSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingToButtons,
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -16)
        ])

        // Modifier buttons (always first, separated)
        let ctrl = makeModifierButton(title: String(localized: "Ctrl")) { [weak self] in
            self?.ctrlActive.toggle()
            self?.updateModifierState()
        }
        let alt = makeModifierButton(title: String(localized: "Alt")) { [weak self] in
            self?.altActive.toggle()
            self?.updateModifierState()
        }
        let shift = makeModifierButton(title: String(localized: "Shift")) { [weak self] in
            self?.shiftActive.toggle()
            self?.updateModifierState()
        }
        ctrlButton = ctrl
        altButton = alt
        shiftButton = shift
        stack.addArrangedSubview(ctrl)
        stack.addArrangedSubview(alt)
        stack.addArrangedSubview(shift)
        stack.addArrangedSubview(makeSeparator())

        let dynamicStack = UIStackView()
        dynamicStack.translatesAutoresizingMaskIntoConstraints = false
        dynamicStack.axis = .horizontal
        dynamicStack.spacing = 8
        dynamicStack.alignment = .center
        // Keep intrinsic widths for text buttons and let UIScrollView handle overflow.
        dynamicStack.setContentHuggingPriority(.required, for: .horizontal)
        dynamicStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(dynamicStack)
        dynamicItemsStack = dynamicStack

        rebuildAccessoryItems()
        updateLeadingButtonsState()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateBackgroundEffect()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBackgroundEffect()
    }

    private func updateBackgroundEffect() {
        guard let backgroundEffectView else { return }
        let backgroundColor = resolveThemeBackgroundColor()
        updateInterfaceStyle(for: backgroundColor)
        backgroundEffectView.effect = nil
        backgroundEffectView.backgroundColor = backgroundColor
    }

    private func updateInterfaceStyle(for backgroundColor: UIColor) {
        if #available(iOS 13.0, *) {
            let resolved = backgroundColor.resolvedColor(with: traitCollection)
            if let isDark = isDarkBackgroundColor(resolved) {
                overrideUserInterfaceStyle = isDark ? .dark : .light
            } else {
                let style = window?.traitCollection.userInterfaceStyle ?? traitCollection.userInterfaceStyle
                overrideUserInterfaceStyle = style == .unspecified ? .unspecified : style
            }
        }
    }

    private func isDarkBackgroundColor(_ color: UIColor) -> Bool? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            return luminance < 0.55
        }

        if #available(iOS 13.0, *) {
            let ciColor = CIColor(color: color)
            let luminance = (0.2126 * ciColor.red) + (0.7152 * ciColor.green) + (0.0722 * ciColor.blue)
            return luminance < 0.55
        }

        return nil
    }

    private func observeThemeChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateBackgroundEffect()
                self?.updateLeadingButtonsState()
            }
        }
        observerTokens.append(token)
    }

    private func observeAccessoryProfileChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: .terminalAccessoryProfileDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildAccessoryItems()
            }
        }
        observerTokens.append(token)
    }

    private func rebuildAccessoryItems() {
        guard let dynamicItemsStack else { return }

        for arrangedSubview in dynamicItemsStack.arrangedSubviews {
            dynamicItemsStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        let profile = TerminalAccessoryPreferencesManager.shared.profile
        let customActionsByID = Dictionary(uniqueKeysWithValues: profile.customActions.filter { !$0.isDeleted }.map { ($0.id, $0) })

        for item in profile.layout.activeItems {
            switch item {
            case .system(let actionID):
                guard let button = makeSystemActionButton(for: actionID) else { continue }
                dynamicItemsStack.addArrangedSubview(button)
            case .custom(let actionID):
                guard let action = customActionsByID[actionID] else { continue }
                let button = makeCustomActionButton(for: action)
                dynamicItemsStack.addArrangedSubview(button)
            }
        }
    }

    private func makeSystemActionButton(for actionID: TerminalAccessorySystemActionID) -> UIButton? {
        if actionID == .commandModifier {
            let button = makeModifierButton(title: actionID.toolbarTitle) { [weak self] in
                self?.commandActive.toggle()
                self?.updateModifierState()
            }
            button.accessibilityLabel = actionID.listTitle
            commandButton = button
            updateModifierButton(button, isActive: commandActive)
            return button
        }

        guard let terminalKey = terminalKey(for: actionID) else { return nil }

        let button: UIButton
        if let iconName = actionID.iconName {
            if actionID.isRepeatable {
                button = makeRepeatableIconButton(icon: iconName, key: terminalKey)
            } else {
                button = makeIconButton(icon: iconName) { [weak self] in
                    self?.sendKey(terminalKey)
                }
            }
        } else if actionID.isRepeatable {
            button = makeRepeatablePillButton(title: actionID.toolbarTitle, key: terminalKey)
        } else {
            button = makePillButton(title: actionID.toolbarTitle) { [weak self] in
                self?.sendKey(terminalKey)
            }
        }

        button.accessibilityLabel = actionID.listTitle
        return button
    }

    private func makeCustomActionButton(for action: TerminalAccessoryCustomAction) -> UIButton {
        let visibleTitle = String(action.title.prefix(12))
        let title = visibleTitle.isEmpty ? action.kind.title : visibleTitle
        let button = makePillButton(title: title) { [weak self] in
            self?.sendCustomAction(action)
        }
        button.accessibilityLabel = action.title
        return button
    }

    private func terminalKey(for actionID: TerminalAccessorySystemActionID) -> TerminalKey? {
        switch actionID {
        case .commandModifier: return nil
        case .escape: return .escape
        case .tab: return .tab
        case .shiftTab: return .tab.withShift()
        case .enter: return .enter
        case .backspace: return .backspace
        case .delete: return .delete
        case .insert: return .insert
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .f1: return .f1
        case .f2: return .f2
        case .f3: return .f3
        case .f4: return .f4
        case .f5: return .f5
        case .f6: return .f6
        case .f7: return .f7
        case .f8: return .f8
        case .f9: return .f9
        case .f10: return .f10
        case .f11: return .f11
        case .f12: return .f12
        case .ctrlC: return .ctrlC
        case .ctrlD: return .ctrlD
        case .ctrlZ: return .ctrlZ
        case .ctrlL: return .ctrlL
        case .ctrlA: return .ctrlA
        case .ctrlE: return .ctrlE
        case .ctrlK: return .ctrlK
        case .ctrlU: return .ctrlU
        case .unknown: return nil
        }
    }

    private func resolveThemeBackgroundColor() -> UIColor {
        let defaults = UserDefaults.standard

        let usePerAppearance = defaults.object(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) as? Bool ?? true
        let darkTheme = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? "Aizen Dark"
        let lightTheme = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameLightKey) ?? "Aizen Light"
        let themeName: String
        if usePerAppearance {
            themeName = traitCollection.userInterfaceStyle == .dark ? darkTheme : lightTheme
        } else {
            themeName = darkTheme
        }

        let fallbackHex = traitCollection.userInterfaceStyle == .dark ? "#000000" : "#FFFFFF"
        let resolved = TerminalThemeBackgroundResolver.initialBackground(
            defaults: defaults,
            themeName: themeName,
            fallbackHex: fallbackHex
        )
        if !resolved.usedFallback {
            return UIColor(resolved.color)
        }

        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .systemBackground
        }
    }

    private func makePillButton(title: String, onTap: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .center
        button.clipsToBounds = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium)])
            )
            config.baseForegroundColor = .label
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.setTitleColor(.label, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16
        button.addAction(UIAction { _ in
            onTap()
        }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeRepeatablePillButton(title: String, key: TerminalKey) -> UIButton {
        let button = RepeatableKeyButton(type: .system)
        button.key = key
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .center
        button.clipsToBounds = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium)])
            )
            config.baseForegroundColor = .label
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.setTitleColor(.label, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16

        button.addTarget(self, action: #selector(repeatButtonDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpOutside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchCancel)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchDragExit)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeIconButton(icon: String, onTap: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16
        button.addAction(UIAction { _ in
            onTap()
        }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeRepeatableIconButton(icon: String, key: TerminalKey) -> UIButton {
        let button = RepeatableKeyButton(type: .system)
        button.key = key
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16

        button.addTarget(self, action: #selector(repeatButtonDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpOutside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchCancel)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchDragExit)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeModifierButton(title: String, onTap: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .center
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)])
            )
            config.baseForegroundColor = .secondaryLabel
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.setTitleColor(.secondaryLabel, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.08)
                : UIColor.black.withAlphaComponent(0.04)
        }
        button.layer.cornerRadius = 14
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
        button.addAction(UIAction { _ in
            onTap()
        }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])

        return button
    }

    private func makeSeparator() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator.withAlphaComponent(0.4)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 18)
        ])
        return view
    }

    private func sendKey(_ key: TerminalKey) {
        var modifiedKey = key
        if ctrlActive {
            modifiedKey = modifiedKey.withCtrl()
        }
        if altActive {
            modifiedKey = modifiedKey.withAlt()
        }
        if commandActive {
            modifiedKey = modifiedKey.withCommand()
        }
        if shiftActive {
            modifiedKey = modifiedKey.withShift()
        }
        if ctrlActive || altActive || commandActive || shiftActive {
            ctrlActive = false
            altActive = false
            commandActive = false
            shiftActive = false
            updateModifierState()
        }
        onKey(modifiedKey)
    }

    private func sendCustomAction(_ action: TerminalAccessoryCustomAction) {
        if ctrlActive || altActive || commandActive || shiftActive {
            ctrlActive = false
            altActive = false
            commandActive = false
            shiftActive = false
            updateModifierState()
        }
        onCustomAction(action)
    }

    @objc private func repeatButtonDown(_ sender: RepeatableKeyButton) {
        startKeyRepeat(for: sender.key)
    }

    @objc private func repeatButtonUp(_ sender: RepeatableKeyButton) {
        stopKeyRepeat()
    }

    private func startKeyRepeat(for key: TerminalKey) {
        stopKeyRepeat()
        sendKey(key)
        keyRepeatOwner.start(key: key) { [weak self] repeatingKey in
            self?.sendKey(repeatingKey)
        }
    }

    private func stopKeyRepeat() {
        keyRepeatOwner.stop()
    }

    func consumeModifiers() -> (ctrl: Bool, alt: Bool, command: Bool, shift: Bool) {
        let ctrl = ctrlActive
        let alt = altActive
        let command = commandActive
        let shift = shiftActive
        if ctrl || alt || command || shift {
            ctrlActive = false
            altActive = false
            commandActive = false
            shiftActive = false
            updateModifierState()
        }
        return (ctrl, alt, command, shift)
    }

    private func updateModifierState() {
        UIView.animate(withDuration: 0.2) {
            self.updateModifierButton(self.ctrlButton, isActive: self.ctrlActive)
            self.updateModifierButton(self.altButton, isActive: self.altActive)
            self.updateModifierButton(self.commandButton, isActive: self.commandActive)
            self.updateModifierButton(self.shiftButton, isActive: self.shiftActive)
        }
    }

    private func updateModifierButton(_ button: UIButton?, isActive: Bool) {
        guard let button else { return }
        if isActive {
            button.backgroundColor = .systemBlue
            button.layer.borderColor = UIColor.clear.cgColor
            if #available(iOS 15.0, *), var config = button.configuration {
                config.baseForegroundColor = .white
                button.configuration = config
            } else {
                button.setTitleColor(.white, for: .normal)
            }
        } else {
            button.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.08)
                    : UIColor.black.withAlphaComponent(0.04)
            }
            button.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
            if #available(iOS 15.0, *), var config = button.configuration {
                config.baseForegroundColor = .secondaryLabel
                button.configuration = config
            } else {
                button.setTitleColor(.secondaryLabel, for: .normal)
            }
        }
    }

    private func updateLeadingButtonsState() {
        let defaults = UserDefaults.standard
        let voiceEnabled = (defaults.object(forKey: "terminalVoiceButtonEnabled") as? Bool ?? true) && onVoice != nil
        let dismissEnabled = defaults.object(forKey: "terminalKeyboardDismissButtonEnabled") as? Bool ?? true
        let hasVisibleLeadingButton = voiceEnabled || dismissEnabled

        voiceButton?.isHidden = !voiceEnabled
        voiceButton?.isEnabled = voiceEnabled
        voiceButton?.alpha = 1.0

        dismissKeyboardButton?.isHidden = !dismissEnabled
        dismissKeyboardButton?.isEnabled = dismissEnabled
        dismissKeyboardButton?.alpha = 1.0

        leadingButtonsStack?.isHidden = !hasVisibleLeadingButton
        leadingButtonsSeparatorView?.isHidden = !hasVisibleLeadingButton
        scrollLeadingToLeadingButtonsConstraint?.isActive = hasVisibleLeadingButton
        scrollLeadingToEdgeConstraint?.isActive = !hasVisibleLeadingButton
        setNeedsLayout()
    }
}

private final class RepeatableKeyButton: UIButton {
    var key: TerminalKey = .backspace
}

#endif
