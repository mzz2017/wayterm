#if os(iOS)
import UIKit

// MARK: - Keyboard Accessory View

extension GhosttyTerminalView {
    private static var keyboardToolbarKey: UInt8 = 0

    var keyboardToolbar: TerminalInputAccessoryView? {
        get { objc_getAssociatedObject(self, &Self.keyboardToolbarKey) as? TerminalInputAccessoryView }
        set { objc_setAssociatedObject(self, &Self.keyboardToolbarKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var shouldHideKeyboardAccessoryBar: Bool {
        hasHardwareKeyboardAttached || keyboardFocusPolicy.isBrowsing
    }

    @discardableResult
    func sendReturnKey() -> Bool {
        guard canRouteTerminalInput else { return false }
        routeToolbarKey(.enter)
        return true
    }

    func resolvedInputAccessoryView() -> UIView? {
        guard !isFindNavigatorActive, !shouldHideKeyboardAccessoryBar else {
            return nil
        }
        if keyboardToolbar == nil {
            let toolbar = TerminalInputAccessoryView(onKey: { [weak self] key in
                self?.routeToolbarKey(key)
            }, onCustomAction: { [weak self] action in
                self?.routeToolbarCustomAction(action)
            }, onVoice: onVoiceButtonTapped, onDismissKeyboard: { [weak self] in
                self?.dismissKeyboardFromToolbar()
            })
            keyboardToolbar = toolbar
        } else {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
        return keyboardToolbar
    }

    override var inputAccessoryView: UIView? {
        resolvedInputAccessoryView()
    }

    func routeToolbarKey(_ key: TerminalKey, accumulatedMods: Ghostty.Input.Mods = []) {
        let routedKey = accumulatedMods.isEmpty ? key : TerminalKey.modified(key, mods: accumulatedMods)
        inputRuntime.handleToolbarKey(routedKey, context: toolbarRoutingContext())
    }

    private func routeToolbarCustomAction(_ action: TerminalAccessoryCustomAction) {
        inputRuntime.handleToolbarCustomAction(action, context: toolbarCustomActionContext())
    }

    private func toolbarRoutingContext() -> TerminalIOSInputRuntime.ToolbarRoutingContext {
        TerminalIOSInputRuntime.ToolbarRoutingContext(
            hasLocalTextInputSession: hasLocalTextInputSession,
            invalidateLocalTextInputSession: { [weak self] in
                self?.invalidateLocalTextInputSession()
            },
            deleteBackward: { [weak self] in
                self?.imeProxyTextView.deleteBackward()
            },
            moveCursorLeft: { [weak self] in
                self?.moveIMEProxyCursorLeft()
            },
            moveCursorRight: { [weak self] in
                self?.moveIMEProxyCursorRight()
            },
            moveCursorToStart: { [weak self] in
                self?.moveIMEProxyCursorToStart()
            },
            moveCursorToEnd: { [weak self] in
                self?.moveIMEProxyCursorToEnd()
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint, invalidateLocalSession in
                self?.sendToolbarRoutedGhosttyKey(
                    key,
                    mods: mods,
                    text: text,
                    unshiftedCodepoint: unshiftedCodepoint,
                    invalidateLocalSession: invalidateLocalSession
                )
            }
        )
    }

    private func toolbarCustomActionContext() -> TerminalIOSInputRuntime.ToolbarCustomActionContext {
        TerminalIOSInputRuntime.ToolbarCustomActionContext(
            sendText: { [weak self] text in
                self?.sendText(text)
            },
            sendKeyPress: { [weak self] key in
                self?.sendKeyPress(key)
            },
            sendGhosttyKey: { [weak self] key, mods, text, unshiftedCodepoint, invalidateLocalSession in
                self?.sendToolbarRoutedGhosttyKey(
                    key,
                    mods: mods,
                    text: text,
                    unshiftedCodepoint: unshiftedCodepoint,
                    invalidateLocalSession: invalidateLocalSession
                )
            }
        )
    }

    private func sendToolbarRoutedGhosttyKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String?,
        unshiftedCodepoint: UInt32?,
        invalidateLocalSession: Bool
    ) {
        let codepoint = unshiftedCodepoint ?? text?.unicodeScalars.first?.value ?? 0
        sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: codepoint,
            invalidateLocalSession: invalidateLocalSession
        )
    }
}
#endif
