#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    // MARK: - Text Input from Software Keyboard
    
    /// Send text to the terminal (called from keyboard toolbar or software keyboard)
    func sendText(_ text: String) {
        guard canRouteTerminalInput else { return }
        surfaceOwner.sendText(text)
        requestRender()
    }
    
    func pasteTextFromClipboard() {
        guard canRouteTerminalInput else { return }
        if let surface = surfaceOwner.liveSurfaceHandle {
            GhosttyClipboardBridge.publishReadSnapshot(
                surface: surface,
                string: Clipboard.readString() ?? ""
            )
        }
        _ = surfaceOwner.perform(action: "paste_from_clipboard")
        requestRender()
    }
    
    private func sendRawTerminalText(_ text: String, invalidateLocalSession: Bool) {
        guard canRouteTerminalInput else { return }
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
    
        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        if let writeCallback {
            writeCallback(data)
        } else {
            surfaceOwner.sendText(text)
        }
        requestRender()
    }
    
    private func terminalTextInputExecutionContext() -> TerminalIOSInputRuntime.TerminalTextInputExecutionContext {
        TerminalIOSInputRuntime.TerminalTextInputExecutionContext(
            sendRawText: { [weak self] text, invalidateLocalSession in
                self?.sendRawTerminalText(text, invalidateLocalSession: invalidateLocalSession)
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint, invalidateLocalSession in
                self?.sendModifiedKey(
                    key,
                    mods: mods,
                    text: text,
                    unshiftedCodepoint: unshiftedCodepoint,
                    invalidateLocalSession: invalidateLocalSession
                )
            }
        )
    }
    
    func terminalTextInputEffectExecutionContext() -> TerminalIOSInputRuntime.TerminalTextInputEffectExecutionContext {
        TerminalIOSInputRuntime.TerminalTextInputEffectExecutionContext(
            textWillChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.textWillChange(self)
            },
            selectionWillChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.selectionWillChange(self)
            },
            textDidChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.textDidChange(self)
            },
            selectionDidChange: { [weak self] in
                guard let self else { return }
                self.nativeTextInputDelegate?.selectionDidChange(self)
            },
            syncPreedit: { [weak self] text in
                self?.syncIMEPreedit(text)
            },
            terminalTextInput: terminalTextInputExecutionContext(),
            sendGhosttyKeyPress: { [weak self] key in
                self?.sendKeyPress(key)
            }
        )
    }
    
    func handleIMEProxyInsertText(_ text: String, fromIMEComposition: Bool = false) -> Bool {
        guard canRouteTerminalInput else { return true }
        if isNativeSelectionTextInputContext {
            clearNativeSelectionStateForTerminalInput()
        }
    
        return inputRuntime.handleIMEInsertText(
            text,
            fromIMEComposition: fromIMEComposition,
            hasPendingSystemTextInputHardwareKey: !fromIMEComposition && pendingSystemTextInputHardwareKeyCount > 0,
            context: imeInsertExecutionContext()
        )
    }
    
    private func consumeIMEProxyModifierState() -> TerminalIOSInputRuntime.ModifierState {
        let mods = keyboardToolbar?.consumeModifiers() ?? (ctrl: false, alt: false, command: false, shift: false)
        return TerminalIOSInputRuntime.ModifierState(
            ctrl: mods.ctrl,
            alt: mods.alt,
            command: mods.command,
            shift: mods.shift
        )
    }
    
    private func imeInsertExecutionContext() -> TerminalIOSInputRuntime.IMEInsertExecutionContext {
        TerminalIOSInputRuntime.IMEInsertExecutionContext(
            consumeModifiers: { [weak self] in
                self?.consumeIMEProxyModifierState() ?? .none
            },
            interpretPendingHardwareKey: { [weak self] text in
                guard let self,
                      let key = self.consumePendingSystemTextInputHardwareKey(),
                      self.sendInterpretedHardwareKeyText(text, for: key)
                else {
                    return false
                }
                self.invalidateLocalTextInputSession()
                return true
            },
            routeToolbarKey: { [weak self] key in
                self?.routeToolbarKey(key)
            },
            interceptRichPaste: { [weak self] in
                self?.interceptRichPasteIfNeeded() ?? false
            },
            invalidateLocalTextInputSession: { [weak self] in
                self?.invalidateLocalTextInputSession()
            },
            commitTextToIMEProxy: { [weak self] text in
                // Plain text goes into the persistent local document; the text
                // input model reconciles it with the terminal by sending the delta.
                self?.imeProxyTextView.insertCommittedText(text)
            },
            commitMarkedTextIfNeeded: { [weak self] in
                self?.commitIMEProxyMarkedTextIfNeeded()
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint in
                self?.sendModifiedKey(key, mods: mods, text: text, unshiftedCodepoint: unshiftedCodepoint)
            },
            sendAnsiData: { [weak self] data in
                self?.sendAnsiSequence(data)
            },
            sendText: { [weak self] text in
                self?.sendText(text)
            }
        )
    }
    
    private func commitIMEProxyMarkedTextIfNeeded() {
        guard imeProxyMarkedRange() != nil else { return }
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.unmarkText()
        }
        syncTextInputModelFromIMEProxy()
    }
    
    func sendKeyPress(_ key: Ghostty.Input.Key) {
        guard canRouteTerminalInput else { return }
        guard surfaceOwner.hasLiveSurface else { return }
        surfaceOwner.sendKeyPress(key, using: inputRuntime)
        requestRender()
    }
    
    private func sendAnsiSequence(_ data: Data) {
        guard canRouteTerminalInput else { return }
        invalidateLocalTextInputSession()
        let text = String(decoding: data, as: UTF8.self)
        sendText(text)
    }
    
    var currentIMEPrimaryLanguage: String? {
        imeProxyTextView.textInputMode?.primaryLanguage ?? textInputMode?.primaryLanguage
    }
    
    func syncIMEPreedit(_ text: String?) {
        if surfaceOwner.syncVisiblePreedit(
            text,
            inputModePrimaryLanguage: currentIMEPrimaryLanguage,
            using: inputRuntime
        ) {
            requestRender()
        }
    }
    
    func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0,
        invalidateLocalSession: Bool = true
    ) {
        guard canRouteTerminalInput else { return }
        guard surfaceOwner.hasLiveSurface else { return }
        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        surfaceOwner.sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: unshiftedCodepoint,
            using: inputRuntime
        )
        requestRender()
    }
    
    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard surfaceOwner.hasLiveSurface else { return }
        inputRuntime.handleSpecialKey(key, context: terminalInputExecutionContext())
    }
    
    /// Send control key combination (e.g., Ctrl+C)
    func sendControlKey(_ char: Character) {
        guard surfaceOwner.hasLiveSurface else { return }
        inputRuntime.handleControlKey(char, context: terminalInputExecutionContext())
    }
    
    private func terminalInputExecutionContext() -> TerminalIOSInputRuntime.TerminalInputExecutionContext {
        TerminalIOSInputRuntime.TerminalInputExecutionContext(
            invalidateLocalTextInputSession: { [weak self] in
                self?.invalidateLocalTextInputSession()
            },
            sendText: { [weak self] text in
                self?.sendText(text)
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint in
                self?.sendModifiedKey(key, mods: mods, text: text, unshiftedCodepoint: unshiftedCodepoint)
            }
        )
    }
}
#endif
