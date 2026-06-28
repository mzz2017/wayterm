#if os(iOS)
import Foundation
import UIKit

@MainActor
final class TerminalIOSInputRuntime {
    typealias ToolbarGhosttyKeySender = (
        _ key: Ghostty.Input.Key,
        _ mods: Ghostty.Input.Mods,
        _ text: String?,
        _ unshiftedCodepoint: UInt32?,
        _ invalidateLocalSession: Bool
    ) -> Void

    struct ToolbarRoutingContext {
        let hasLocalTextInputSession: Bool
        let invalidateLocalTextInputSession: () -> Void
        let deleteBackward: () -> Void
        let moveCursorLeft: () -> Void
        let moveCursorRight: () -> Void
        let moveCursorToStart: () -> Void
        let moveCursorToEnd: () -> Void
        let sendGhosttyKey: ToolbarGhosttyKeySender
    }

    struct ToolbarCustomActionContext {
        let sendText: (String) -> Void
        let sendKeyPress: (Ghostty.Input.Key) -> Void
        let sendGhosttyKey: ToolbarGhosttyKeySender
    }

    struct GhosttyKeyMapping {
        let key: Ghostty.Input.Key
        let text: String?
        let codepoint: UInt32
        let requiresShift: Bool
    }

    struct ModifierState {
        let ctrl: Bool
        let alt: Bool
        let command: Bool
        let shift: Bool

        static let none = ModifierState(ctrl: false, alt: false, command: false, shift: false)

        var hasCommandRoutingModifier: Bool {
            ctrl || alt || command
        }
    }

    enum IMEInsertRoute {
        case ignore
        case interpretPendingHardwareKey(String)
        case routeToolbarKey(TerminalKey, suppressUnexpectedResign: Bool)
        case interceptRichPaste(fallbackModifiers: ModifierState)
        case commitTextToIMEProxy(String)
        case sendGhosttyKey(Ghostty.Input.Key, Ghostty.Input.Mods, String?, UInt32, commitMarkedTextFirst: Bool)
        case sendAnsiData(Data)
    }

    struct IMEInsertExecutionContext {
        let consumeModifiers: () -> ModifierState
        let interpretPendingHardwareKey: (String) -> Bool
        let routeToolbarKey: (TerminalKey) -> Void
        let interceptRichPaste: () -> Bool
        let invalidateLocalTextInputSession: () -> Void
        let commitTextToIMEProxy: (String) -> Void
        let commitMarkedTextIfNeeded: () -> Void
        let sendGhosttyKey: (Ghostty.Input.Key, Ghostty.Input.Mods, String?, UInt32) -> Void
        let sendAnsiData: (Data) -> Void
        let sendText: (String) -> Void
    }

    struct TerminalInputExecutionContext {
        let invalidateLocalTextInputSession: () -> Void
        let sendText: (String) -> Void
        let sendGhosttyKey: (Ghostty.Input.Key, Ghostty.Input.Mods, String?, UInt32) -> Void
    }

    struct TerminalTextInputExecutionContext {
        let sendRawText: (String, Bool) -> Void
        let sendGhosttyKey: (Ghostty.Input.Key, Ghostty.Input.Mods, String?, UInt32, Bool) -> Void
    }

    struct TerminalTextInputEffectExecutionContext {
        let textWillChange: () -> Void
        let selectionWillChange: () -> Void
        let textDidChange: () -> Void
        let selectionDidChange: () -> Void
        let syncPreedit: (String?) -> Void
        let terminalTextInput: TerminalTextInputExecutionContext
        let sendGhosttyKeyPress: (Ghostty.Input.Key) -> Void
    }

    private var renderedPreeditText: String?
    private var isIMEProxyProgrammaticResignAllowed = false
    private var suppressUnexpectedIMEProxyResignUntil = 0.0

    func sendKeyPress(
        _ key: Ghostty.Input.Key,
        sendEvent: (Ghostty.Input.KeyEvent) -> Void
    ) {
        sendEvent(.init(key: key, action: .press))
        sendEvent(.init(key: key, action: .release))
    }

    func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String?,
        unshiftedCodepoint: UInt32,
        sendEvent: (Ghostty.Input.KeyEvent) -> Void
    ) {
        sendEvent(
            .init(
                key: key,
                action: .press,
                text: text,
                composing: false,
                mods: mods,
                consumedMods: [],
                unshiftedCodepoint: unshiftedCodepoint
            )
        )
        sendEvent(
            .init(
                key: key,
                action: .release,
                text: nil,
                composing: false,
                mods: mods,
                consumedMods: [],
                unshiftedCodepoint: unshiftedCodepoint
            )
        )
    }

    func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e,
        surface: ghostty_surface_t
    ) -> Bool {
        guard let event = Ghostty.Input.KeyEvent(uiKey: key, action: ghosttyInputAction(action))
        else {
            return false
        }
        return event.withCValue { cEvent in
            ghostty_surface_key(surface, cEvent)
        }
    }

    func handleToolbarKey(_ key: TerminalKey, context: ToolbarRoutingContext) {
        sendToolbarKey(key, accumulatedMods: [], context: context)
    }

    func handleToolbarCustomAction(_ action: TerminalAccessoryCustomAction, context: ToolbarCustomActionContext) {
        switch action.kind {
        case .command:
            context.sendText(action.commandContent)
            if action.commandSendMode == .insertAndEnter {
                context.sendKeyPress(.enter)
            }
        case .shortcut:
            guard let key = Ghostty.Input.Key(rawValue: action.shortcutKey.rawValue) else { return }
            let mods = action.shortcutModifiers.ghosttyModifiers
            let text: String?
            if action.shortcutModifiers.control || action.shortcutModifiers.alternate || action.shortcutModifiers.command {
                text = nil
            } else if action.shortcutModifiers.shift {
                text = action.shortcutKey.shiftedText ?? action.shortcutKey.unshiftedText
            } else {
                text = action.shortcutKey.unshiftedText
            }

            let codepoint = action.shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
            sendToolbarGhosttyKey(
                key,
                mods: mods,
                text: text,
                unshiftedCodepoint: codepoint,
                context: context
            )
        }
    }

    func ghosttyKeyMapping(for character: Character) -> GhosttyKeyMapping? {
        let string = String(character)

        for shortcutKey in TerminalAccessoryShortcutKey.allCases {
            if shortcutKey.unshiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return GhosttyKeyMapping(
                    key: ghosttyKey,
                    text: shortcutKey.unshiftedText,
                    codepoint: codepoint,
                    requiresShift: false
                )
            }

            if shortcutKey.shiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return GhosttyKeyMapping(
                    key: ghosttyKey,
                    text: shortcutKey.shiftedText,
                    codepoint: codepoint,
                    requiresShift: true
                )
            }
        }

        return nil
    }

    func terminalKey(forKeyCommandInput input: String) -> TerminalKey? {
        switch input {
        case UIKeyCommand.inputEscape:
            return .escape
        case UIKeyCommand.inputUpArrow:
            return .arrowUp
        case UIKeyCommand.inputDownArrow:
            return .arrowDown
        case UIKeyCommand.inputLeftArrow:
            return .arrowLeft
        case UIKeyCommand.inputRightArrow:
            return .arrowRight
        case UIKeyCommand.inputHome:
            return .home
        case UIKeyCommand.inputEnd:
            return .end
        case UIKeyCommand.inputPageUp:
            return .pageUp
        case UIKeyCommand.inputPageDown:
            return .pageDown
        default:
            return nil
        }
    }

    func ghosttyModifiers(from mods: (ctrl: Bool, alt: Bool, command: Bool, shift: Bool)) -> Ghostty.Input.Mods {
        ghosttyModifiers(from: ModifierState(ctrl: mods.ctrl, alt: mods.alt, command: mods.command, shift: mods.shift))
    }

    func ghosttyModifiers(from mods: ModifierState) -> Ghostty.Input.Mods {
        var ghostMods: Ghostty.Input.Mods = []
        if mods.ctrl { ghostMods.insert(.ctrl) }
        if mods.alt { ghostMods.insert(.alt) }
        if mods.command { ghostMods.insert(.super) }
        if mods.shift { ghostMods.insert(.shift) }
        return ghostMods
    }

    func imeInsertRoute(
        for text: String,
        modifiers: ModifierState,
        hasPendingSystemTextInputHardwareKey: Bool,
        fromIMEComposition: Bool,
        allowRichPasteInterception: Bool = true
    ) -> IMEInsertRoute {
        imeInsertRoute(
            for: text,
            modifiers: { modifiers },
            hasPendingSystemTextInputHardwareKey: hasPendingSystemTextInputHardwareKey,
            fromIMEComposition: fromIMEComposition,
            allowRichPasteInterception: allowRichPasteInterception
        )
    }

    func imeInsertRoute(
        for text: String,
        modifiers consumeModifiers: () -> ModifierState,
        hasPendingSystemTextInputHardwareKey: Bool,
        fromIMEComposition: Bool,
        allowRichPasteInterception: Bool = true
    ) -> IMEInsertRoute {
        let normalized = text.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return .ignore }
        if let key = terminalKey(forKeyCommandInput: normalized) {
            return .routeToolbarKey(key, suppressUnexpectedResign: isEscapeKey(key))
        }
        if normalized.hasPrefix("UIKeyInput") {
            return .ignore
        }

        if !fromIMEComposition, hasPendingSystemTextInputHardwareKey {
            return .interpretPendingHardwareKey(normalized)
        }

        let mods = consumeModifiers()
        if allowRichPasteInterception,
           mods.ctrl,
           normalized.compare("v", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return .interceptRichPaste(fallbackModifiers: mods)
        }
        if normalized == "\n" || normalized == "\r" {
            return .sendGhosttyKey(.enter, ghosttyModifiers(from: mods), nil, 0, commitMarkedTextFirst: true)
        }
        if normalized == "\t" {
            return .sendGhosttyKey(.tab, ghosttyModifiers(from: mods), nil, 0, commitMarkedTextFirst: true)
        }

        guard mods.hasCommandRoutingModifier else {
            return .commitTextToIMEProxy(normalized)
        }
        guard let firstChar = normalized.first else { return .ignore }

        if let mapping = ghosttyKeyMapping(for: firstChar) {
            var ghostMods = ghosttyModifiers(from: mods)
            if mapping.requiresShift {
                ghostMods.insert(.shift)
            }
            return .sendGhosttyKey(
                mapping.key,
                ghostMods,
                nil,
                mapping.codepoint,
                commitMarkedTextFirst: false
            )
        }

        if mods.command {
            return .ignore
        }

        var data = Data()
        if mods.alt {
            data.append(0x1B)
        }
        if mods.ctrl, let controlChar = TerminalControlKey.controlCharacter(for: firstChar) {
            data.append(contentsOf: String(controlChar).utf8)
        } else {
            data.append(contentsOf: String(firstChar).utf8)
        }
        return .sendAnsiData(data)
    }

    func handleIMEInsertText(
        _ text: String,
        fromIMEComposition: Bool,
        hasPendingSystemTextInputHardwareKey: Bool,
        context: IMEInsertExecutionContext
    ) -> Bool {
        let normalized = text.precomposedStringWithCanonicalMapping
        let route = imeInsertRoute(
            for: normalized,
            modifiers: context.consumeModifiers,
            hasPendingSystemTextInputHardwareKey: hasPendingSystemTextInputHardwareKey,
            fromIMEComposition: fromIMEComposition
        )
        return executeIMEInsertRoute(route, normalizedText: normalized, context: context)
    }

    func handleControlShortcut(_ char: Character, context: TerminalInputExecutionContext) {
        let lower = String(char).lowercased()
        if let key = Ghostty.Input.Key(rawValue: lower) {
            let codepoint = lower.unicodeScalars.first?.value ?? 0
            context.sendGhosttyKey(key, [.ctrl], lower, codepoint)
            return
        }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            context.sendText(String(controlChar))
        }
    }

    func handleSpecialKey(_ key: TerminalSpecialKey, context: TerminalInputExecutionContext) {
        let shouldInvalidateSession: Bool = switch key {
        case .arrowLeft, .arrowRight, .home, .end, .escape:
            false
        default:
            true
        }
        if shouldInvalidateSession {
            context.invalidateLocalTextInputSession()
        }

        switch key {
        case .enter:
            context.sendText(String(Character(UnicodeScalar(UInt8(0x0D)))))
        case .backspace:
            context.sendText(String(Character(UnicodeScalar(UInt8(0x7F)))))
        default:
            context.sendText(TerminalSpecialKeySequence.escapeSequence(for: key))
        }
    }

    func handleControlKey(_ char: Character, context: TerminalInputExecutionContext) {
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            context.sendText(String(controlChar))
        }
    }

    func handleTerminalInputText(_ text: String, context: TerminalTextInputExecutionContext) {
        let normalized = text.precomposedStringWithCanonicalMapping
        guard normalized.count == 1, let character = normalized.first else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false, context: context)
            return
        }
        guard let mapping = ghosttyKeyMapping(for: character) else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false, context: context)
            return
        }

        var mods: Ghostty.Input.Mods = []
        if mapping.requiresShift {
            mods.insert(.shift)
        }
        context.sendGhosttyKey(
            mapping.key,
            mods,
            mapping.text,
            mapping.codepoint,
            false
        )
    }

    func handleTerminalTextInputEffects(
        _ effects: [TerminalTextInputModel.Effect],
        context: TerminalTextInputEffectExecutionContext
    ) {
        for effect in effects {
            switch effect {
            case .willTextChange:
                context.textWillChange()
            case .willSelectionChange:
                context.selectionWillChange()
            case .didTextChange:
                context.textDidChange()
            case .didSelectionChange:
                context.selectionDidChange()
            case let .syncPreedit(text):
                context.syncPreedit(text)
            case let .sendText(text):
                handleTerminalInputText(text, context: context.terminalTextInput)
            case let .sendBackspaces(count):
                for _ in 0..<count {
                    context.sendGhosttyKeyPress(.backspace)
                }
            case let .moveCursor(delta):
                let key: Ghostty.Input.Key = delta < 0 ? .arrowLeft : .arrowRight
                for _ in 0..<abs(delta) {
                    context.sendGhosttyKeyPress(key)
                }
            case let .sendSpecialKey(key):
                switch key {
                case .enter:
                    context.sendGhosttyKeyPress(.enter)
                case .tab:
                    context.sendGhosttyKeyPress(.tab)
                case .backspace:
                    context.sendGhosttyKeyPress(.backspace)
                }
            }
        }
    }

    @discardableResult
    func syncVisiblePreedit(
        _ text: String?,
        inputModePrimaryLanguage: String?,
        surface: ghostty_surface_t?
    ) -> Bool {
        let visibleText: String?
        if let text, !text.isEmpty {
            let normalized = text.precomposedStringWithCanonicalMapping
            visibleText = TerminalVisiblePreeditPolicy.shouldDisplay(
                normalized,
                inputModePrimaryLanguage: inputModePrimaryLanguage
            ) ? normalized : nil
        } else {
            visibleText = nil
        }

        guard visibleText != renderedPreeditText else { return false }
        renderedPreeditText = visibleText

        guard let surface else { return false }
        syncPreedit(visibleText, surface: surface)
        return true
    }

    func canResignIMEProxy(isTextInputSessionEligible: Bool) -> Bool {
        if isIMEProxyProgrammaticResignAllowed || !isTextInputSessionEligible {
            return true
        }
        return !shouldSuppressUnexpectedIMEProxyResign
    }

    func suppressUnexpectedIMEProxyResign() {
        suppressUnexpectedIMEProxyResignUntil = Date.timeIntervalSinceReferenceDate + 0.35
    }

    func performProgrammaticIMEProxyResign(_ resign: () -> Bool) -> Bool {
        let previous = isIMEProxyProgrammaticResignAllowed
        isIMEProxyProgrammaticResignAllowed = true
        defer { isIMEProxyProgrammaticResignAllowed = previous }
        return resign()
    }

    func syncPreedit(_ text: String?, surface: ghostty_surface_t) {
        guard let text, !text.isEmpty else {
            ghostty_surface_preedit(surface, nil, 0)
            return
        }

        let len = text.utf8CString.count
        guard len > 0 else {
            ghostty_surface_preedit(surface, nil, 0)
            return
        }
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(len - 1))
        }
    }

    func imePoint(surface: ghostty_surface_t) -> CGRect {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    private func ghosttyInputAction(_ action: ghostty_input_action_e) -> Ghostty.Input.Action {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            return .press
        case GHOSTTY_ACTION_RELEASE:
            return .release
        case GHOSTTY_ACTION_REPEAT:
            return .repeat
        default:
            return .press
        }
    }

    private var shouldSuppressUnexpectedIMEProxyResign: Bool {
        Date.timeIntervalSinceReferenceDate < suppressUnexpectedIMEProxyResignUntil
    }

    private func executeIMEInsertRoute(
        _ route: IMEInsertRoute,
        normalizedText: String,
        context: IMEInsertExecutionContext
    ) -> Bool {
        switch route {
        case .ignore:
            return true
        case .interpretPendingHardwareKey(let text):
            if context.interpretPendingHardwareKey(text) {
                return true
            }

            let fallbackRoute = imeInsertRoute(
                for: text,
                modifiers: context.consumeModifiers,
                hasPendingSystemTextInputHardwareKey: false,
                fromIMEComposition: false
            )
            return executeIMEInsertRoute(fallbackRoute, normalizedText: text, context: context)
        case .routeToolbarKey(let key, let suppressUnexpectedResign):
            if suppressUnexpectedResign {
                suppressUnexpectedIMEProxyResign()
            }
            context.routeToolbarKey(key)
            return true
        case .interceptRichPaste(let fallbackModifiers):
            if context.interceptRichPaste() {
                context.invalidateLocalTextInputSession()
                return true
            }

            let fallbackRoute = imeInsertRoute(
                for: normalizedText,
                modifiers: fallbackModifiers,
                hasPendingSystemTextInputHardwareKey: false,
                fromIMEComposition: false,
                allowRichPasteInterception: false
            )
            return executeIMEInsertRoute(fallbackRoute, normalizedText: normalizedText, context: context)
        case .commitTextToIMEProxy(let text):
            context.commitTextToIMEProxy(text)
            return true
        case .sendGhosttyKey(let key, let mods, let text, let unshiftedCodepoint, let commitMarkedTextFirst):
            if commitMarkedTextFirst {
                context.commitMarkedTextIfNeeded()
            }
            context.sendGhosttyKey(key, mods, text, unshiftedCodepoint)
            sendRemainingIMEInsertTextIfNeeded(after: normalizedText, sendText: context.sendText)
            return true
        case .sendAnsiData(let data):
            context.sendAnsiData(data)
            sendRemainingIMEInsertTextIfNeeded(after: normalizedText, sendText: context.sendText)
            return true
        }
    }

    private func sendRemainingIMEInsertTextIfNeeded(after normalized: String, sendText: (String) -> Void) {
        guard normalized.count > 1 else { return }
        sendText(String(normalized.dropFirst()))
    }

    private func sendRawTerminalInputText(
        _ text: String,
        invalidateLocalSession: Bool,
        context: TerminalTextInputExecutionContext
    ) {
        let terminalText = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        guard !Data(terminalText.utf8).isEmpty else { return }
        context.sendRawText(terminalText, invalidateLocalSession)
    }

    private func isEscapeKey(_ key: TerminalKey) -> Bool {
        if case .escape = key {
            return true
        }
        return false
    }

    private func sendToolbarKey(
        _ key: TerminalKey,
        accumulatedMods: Ghostty.Input.Mods,
        context: ToolbarRoutingContext
    ) {
        switch key {
        case .modified(let baseKey, let mods):
            sendToolbarKey(baseKey, accumulatedMods: accumulatedMods.union(mods), context: context)
        case .escape:
            if accumulatedMods.isEmpty, context.hasLocalTextInputSession {
                context.invalidateLocalTextInputSession()
            }
            sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false, context: context)
        case .tab:
            sendToolbarGhosttyKey(.tab, mods: accumulatedMods, context: context)
        case .enter:
            sendToolbarGhosttyKey(.enter, mods: accumulatedMods, context: context)
        case .backspace:
            if accumulatedMods.isEmpty, context.hasLocalTextInputSession {
                context.deleteBackward()
            } else {
                sendToolbarGhosttyKey(.backspace, mods: accumulatedMods, context: context)
            }
        case .delete:
            sendToolbarGhosttyKey(.delete, mods: accumulatedMods, context: context)
        case .insert:
            sendToolbarGhosttyKey(.insert, mods: accumulatedMods, context: context)
        case .arrowUp:
            sendToolbarGhosttyKey(.arrowUp, mods: accumulatedMods, context: context)
        case .arrowDown:
            sendToolbarGhosttyKey(.arrowDown, mods: accumulatedMods, context: context)
        case .arrowLeft:
            if accumulatedMods.isEmpty, context.hasLocalTextInputSession {
                context.moveCursorLeft()
            } else {
                sendToolbarGhosttyKey(.arrowLeft, mods: accumulatedMods, context: context)
            }
        case .arrowRight:
            if accumulatedMods.isEmpty, context.hasLocalTextInputSession {
                context.moveCursorRight()
            } else {
                sendToolbarGhosttyKey(.arrowRight, mods: accumulatedMods, context: context)
            }
        case .home:
            if accumulatedMods.isEmpty, context.hasLocalTextInputSession {
                context.moveCursorToStart()
            } else {
                sendToolbarGhosttyKey(.home, mods: accumulatedMods, context: context)
            }
        case .end:
            if accumulatedMods.isEmpty, context.hasLocalTextInputSession {
                context.moveCursorToEnd()
            } else {
                sendToolbarGhosttyKey(.end, mods: accumulatedMods, context: context)
            }
        case .pageUp:
            sendToolbarGhosttyKey(.pageUp, mods: accumulatedMods, context: context)
        case .pageDown:
            sendToolbarGhosttyKey(.pageDown, mods: accumulatedMods, context: context)
        case .f1:
            sendToolbarGhosttyKey(.f1, mods: accumulatedMods, context: context)
        case .f2:
            sendToolbarGhosttyKey(.f2, mods: accumulatedMods, context: context)
        case .f3:
            sendToolbarGhosttyKey(.f3, mods: accumulatedMods, context: context)
        case .f4:
            sendToolbarGhosttyKey(.f4, mods: accumulatedMods, context: context)
        case .f5:
            sendToolbarGhosttyKey(.f5, mods: accumulatedMods, context: context)
        case .f6:
            sendToolbarGhosttyKey(.f6, mods: accumulatedMods, context: context)
        case .f7:
            sendToolbarGhosttyKey(.f7, mods: accumulatedMods, context: context)
        case .f8:
            sendToolbarGhosttyKey(.f8, mods: accumulatedMods, context: context)
        case .f9:
            sendToolbarGhosttyKey(.f9, mods: accumulatedMods, context: context)
        case .f10:
            sendToolbarGhosttyKey(.f10, mods: accumulatedMods, context: context)
        case .f11:
            sendToolbarGhosttyKey(.f11, mods: accumulatedMods, context: context)
        case .f12:
            sendToolbarGhosttyKey(.f12, mods: accumulatedMods, context: context)
        case .ctrlC:
            sendToolbarControlShortcut(.c, letter: "c", mods: accumulatedMods, context: context)
        case .ctrlD:
            sendToolbarControlShortcut(.d, letter: "d", mods: accumulatedMods, context: context)
        case .ctrlZ:
            sendToolbarControlShortcut(.z, letter: "z", mods: accumulatedMods, context: context)
        case .ctrlL:
            sendToolbarControlShortcut(.l, letter: "l", mods: accumulatedMods, context: context)
        case .ctrlA:
            sendToolbarControlShortcut(.a, letter: "a", mods: accumulatedMods, context: context)
        case .ctrlE:
            sendToolbarControlShortcut(.e, letter: "e", mods: accumulatedMods, context: context)
        case .ctrlK:
            sendToolbarControlShortcut(.k, letter: "k", mods: accumulatedMods, context: context)
        case .ctrlU:
            sendToolbarControlShortcut(.u, letter: "u", mods: accumulatedMods, context: context)
        }
    }

    private func sendToolbarGhosttyKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32? = nil,
        invalidateLocalSession: Bool = true,
        context: ToolbarRoutingContext
    ) {
        context.sendGhosttyKey(key, mods, text, unshiftedCodepoint, invalidateLocalSession)
    }

    private func sendToolbarGhosttyKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32? = nil,
        invalidateLocalSession: Bool = true,
        context: ToolbarCustomActionContext
    ) {
        context.sendGhosttyKey(key, mods, text, unshiftedCodepoint, invalidateLocalSession)
    }

    private func sendToolbarControlShortcut(
        _ key: Ghostty.Input.Key,
        letter: String,
        mods: Ghostty.Input.Mods,
        context: ToolbarRoutingContext
    ) {
        var mergedMods = mods
        mergedMods.insert(.ctrl)
        let codepoint = letter.unicodeScalars.first?.value ?? 0
        sendToolbarGhosttyKey(key, mods: mergedMods, text: nil, unshiftedCodepoint: codepoint, context: context)
    }
}
#endif
