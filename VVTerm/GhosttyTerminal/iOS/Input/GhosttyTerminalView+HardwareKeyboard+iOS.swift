#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    // MARK: - Keyboard Input (Hardware Keyboard)
    
    override var keyCommands: [UIKeyCommand]? {
        // Keep keyCommands nil; handle command shortcuts in pressesBegan.
        return nil
    }
    
    func handleIMEProxyNavigationCommand(_ command: UIKeyCommand) {
        guard canRouteTerminalInput else { return }
        guard let input = command.input,
              let key = inputRuntime.terminalKey(forKeyCommandInput: input) else { return }
        if case .escape = key {
            inputRuntime.suppressUnexpectedIMEProxyResign()
        }
        let mods = Ghostty.Input.Mods(uiKeyModifiers: command.modifierFlags)
        routeToolbarKey(key, accumulatedMods: mods)
    }
    
    private func handlePasteShortcut(_ key: UIKey) -> Bool {
        let input = key.charactersIgnoringModifiers.lowercased()
        guard input == "v" else { return false }
    
        if key.modifierFlags.contains(.command) {
            performPasteAction(requestRenderAfterward: true)
            return true
        }
    
        if key.modifierFlags.contains(.control), interceptRichPasteIfNeeded() {
            return true
        }
    
        return false
    }
    
    @discardableResult
    func interceptRichPasteIfNeeded() -> Bool {
        richPasteInterceptor?(self) == true
    }
    
    func performPasteAction(requestRenderAfterward: Bool = false) {
        invalidateLocalTextInputSession()
        if interceptRichPasteIfNeeded() {
            clearSelectionAfterPaste()
            if requestRenderAfterward {
                requestRender()
            }
            return
        }
    
        pasteTextFromClipboard()
        clearSelectionAfterPaste()
        if requestRenderAfterward {
            requestRender()
        }
    }
    
    private func handleCommandShortcut(_ key: UIKey) -> Bool {
        guard key.modifierFlags.contains(.command) else { return false }
        let input = key.charactersIgnoringModifiers.lowercased()
        switch input {
        case "c":
            if canPerformAction(#selector(copy(_:)), withSender: nil) {
                copy(nil)
            }
            return true
        case "f":
            if canPerformAction(#selector(find(_:)), withSender: nil) {
                find(nil)
                return true
            }
            return false
        default:
            return false
        }
    }
    
    private func fallbackHardwareKey(for key: UIKey) -> Ghostty.Input.Key? {
        switch key.keyCode {
        case .keyboardLeftShift:
            return .shiftLeft
        case .keyboardRightShift:
            return .shiftRight
        case .keyboardCapsLock:
            return .capsLock
        case .keyboardReturnOrEnter:
            return .enter
        case .keyboardDeleteOrBackspace:
            return .backspace
        case .keyboardDeleteForward:
            return .delete
        case .keyboardTab:
            return .tab
        case .keyboardEscape:
            return .escape
        case .keyboardUpArrow:
            return .arrowUp
        case .keyboardDownArrow:
            return .arrowDown
        case .keyboardLeftArrow:
            return .arrowLeft
        case .keyboardRightArrow:
            return .arrowRight
        case .keyboardHome:
            return .home
        case .keyboardEnd:
            return .end
        case .keyboardPageUp:
            return .pageUp
        case .keyboardPageDown:
            return .pageDown
        default:
            break
        }
    
        let candidates = [key.charactersIgnoringModifiers, key.characters]
        for candidate in candidates where !candidate.isEmpty {
            switch candidate {
            case "UIKeyInputEscape":
                return .escape
            case "UIKeyInputUpArrow":
                return .arrowUp
            case "UIKeyInputDownArrow":
                return .arrowDown
            case "UIKeyInputLeftArrow":
                return .arrowLeft
            case "UIKeyInputRightArrow":
                return .arrowRight
            case "UIKeyInputHome":
                return .home
            case "UIKeyInputEnd":
                return .end
            case "UIKeyInputPageUp":
                return .pageUp
            case "UIKeyInputPageDown":
                return .pageDown
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
                continue
            }
        }
    
        return nil
    }
    
    private func startKeyRepeat(for key: UIKey) {
        keyRepeatRuntime.start(
            for: key,
            fallbackKey: fallbackHardwareKey(for: key),
            canRouteInput: { [weak self] in
                self?.canRouteTerminalInput == true
            },
            sendDirectRepeat: { [weak self] repeatKey in
                guard let self else { return false }
                return self.surfaceOwner.sendDirectHardwareKeyEvent(
                    repeatKey,
                    action: GHOSTTY_ACTION_REPEAT,
                    using: self.inputRuntime
                )
            },
            sendFallbackRepeat: { [weak self] fallbackKey, modifiers in
                guard let self else { return }
                self.surfaceOwner.sendKeyEvent(
                    self.fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .repeat,
                        modifiers: modifiers
                    )
                )
            },
            requestRender: { [weak self] in
                self?.requestRender()
            }
        )
    }
    
    func stopKeyRepeat() {
        keyRepeatRuntime.stop()
    }
    
    private func fallbackHardwareEvent(
        key: Ghostty.Input.Key,
        action: Ghostty.Input.Action,
        modifiers: UIKeyModifierFlags
    ) -> Ghostty.Input.KeyEvent {
        let mods = Ghostty.Input.Mods(uiKeyModifiers: modifiers)
        let consumedMods = Ghostty.Input.Mods(
            uiKeyModifiers: modifiers.subtracting([.control, .command])
        )
        return .init(
            key: key,
            action: action,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: consumedMods,
            unshiftedCodepoint: 0
        )
    }
    
    private func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e
    ) -> Bool {
        surfaceOwner.sendDirectHardwareKeyEvent(key, action: action, using: inputRuntime)
    }
    
    private func shouldRoutePressToSystemTextInput(_ key: UIKey) -> Bool {
        let keyProducesText = !(key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty)
        return TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
            hasControlModifier: key.modifierFlags.contains(.control),
            hasAlternateModifier: key.modifierFlags.contains(.alternate),
            hasCommandModifier: key.modifierFlags.contains(.command),
            hasActiveIMEComposition: textInputModel.hasActiveIMEComposition,
            isSystemTextInputToggleKey: key.keyCode == .keyboardCapsLock,
            hasTerminalFallbackKey: fallbackHardwareKey(for: key) != nil,
            keyProducesText: keyProducesText
        )
    }

    func processHardwarePressesBegan(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard surfaceOwner.hasLiveSurface else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
        guard canRouteTerminalInput else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
    
        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            markHardwareKeyboardDetectedFromKeyPress()
            if handlePasteShortcut(key) {
                result.didHandleGhosttyInput = true
                continue
            }
            if handleCommandShortcut(key) { continue }
            if key.modifierFlags.contains(.command) {
                result.forwardedToSystem.insert(press)
                continue
            }
            if isNativeSelectionTextInputContext {
                clearNativeSelectionStateForTerminalInput()
            }
            if textInputModel.hasActiveIMEComposition, key.keyCode == .keyboardEscape {
                invalidateLocalTextInputSession()
                result.didHandleGhosttyInput = true
                continue
            }
            if shouldRoutePressToSystemTextInput(key) {
                let keyCode = UInt16(key.keyCode.rawValue)
                let keyProducesText = !(key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty)
                hardwarePressState.recordSystemTextInputPress(keyCode: keyCode)
                if TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                    keyProducesText: keyProducesText,
                    hasControlModifier: key.modifierFlags.contains(.control),
                    hasAlternateModifier: key.modifierFlags.contains(.alternate),
                    hasCommandModifier: key.modifierFlags.contains(.command),
                    hasActiveIMEComposition: textInputModel.hasActiveIMEComposition,
                    isSystemTextInputToggleKey: key.keyCode == .keyboardCapsLock
                ) {
                    hardwarePressState.appendPendingSystemTextInputHardwareKey(key)
                }
                result.forwardedToSystem.insert(press)
                continue
            }
    
            let keyCode = UInt16(key.keyCode.rawValue)
            if hasLocalTextInputSession {
                invalidateLocalTextInputSession()
            }
            if sendDirectHardwareKeyEvent(key, action: GHOSTTY_ACTION_PRESS) {
                hardwarePressState.recordDirectGhosttyPress(keyCode: keyCode)
                startKeyRepeat(for: key)
                result.didHandleGhosttyInput = true
            } else if let fallbackKey = fallbackHardwareKey(for: key) {
                surfaceOwner.sendKeyEvent(
                    fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .press,
                        modifiers: key.modifierFlags
                    )
                )
                hardwarePressState.recordFallbackGhosttyPress(
                    keyCode: keyCode,
                    fallbackKey: fallbackKey,
                    modifiers: key.modifierFlags
                )
                startKeyRepeat(for: key)
                result.didHandleGhosttyInput = true
            }
        }
    
        return result
    }

    func processHardwarePressesEnded(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard surfaceOwner.hasLiveSurface else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
        guard canRouteTerminalInput || hardwarePressState.hasGhosttyPresses else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
    
        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            let keyCode = UInt16(key.keyCode.rawValue)
            guard let release = hardwarePressState.releaseGhosttyPress(
                keyCode: keyCode,
                defaultModifiers: key.modifierFlags
            ) else {
                result.forwardedToSystem.insert(press)
                continue
            }
            if keyRepeatRuntime.isRepeating(keyCode: keyCode) {
                stopKeyRepeat()
            }

            if sendDirectHardwareKeyEvent(key, action: GHOSTTY_ACTION_RELEASE) {
                result.didHandleGhosttyInput = true
            } else if let fallbackKey = release.fallbackKey {
                surfaceOwner.sendKeyEvent(
                    fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .release,
                        modifiers: release.fallbackModifiers
                    )
                )
                result.didHandleGhosttyInput = true
            }
        }
    
        return result
    }
    
    func processHardwarePressesCancelled(_ presses: Set<UIPress>) {
        for press in presses {
            guard let key = press.key else { continue }
            let keyCode = UInt16(key.keyCode.rawValue)
            hardwarePressState.cancelPress(keyCode: keyCode)
        }
        stopKeyRepeat()
    }
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if shouldRedirectNativeSelectionPressesToTerminalInput(presses) {
            guard exitNativeSelectionTextInputContextForTerminalInput() else {
                super.pressesBegan(presses, with: event)
                return
            }
            imeProxyTextView.pressesBegan(presses, with: event)
            return
        }
    
        let pendingCount = pendingSystemTextInputHardwareKeyCount
        let result = processHardwarePressesBegan(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesBegan(result.forwardedToSystem, with: event)
            removeUnconsumedPendingSystemTextInputHardwareKeys(after: pendingCount)
        }
    
        if result.didHandleGhosttyInput {
            requestRender()
        }
    }
    
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let result = processHardwarePressesEnded(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesEnded(result.forwardedToSystem, with: event)
        }
    
        if result.didHandleGhosttyInput {
            requestRender()
        }
    }
    
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        processHardwarePressesCancelled(presses)
    }

}
#endif
