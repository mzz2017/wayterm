#if os(iOS)
import UIKit

nonisolated enum TerminalHardwareKeyRepeatPolicy {
    private static let repeatableKeyCodes: Set<UIKeyboardHIDUsage> = [
        .keyboardDeleteOrBackspace,
        .keyboardDeleteForward,
        .keyboardUpArrow,
        .keyboardDownArrow,
        .keyboardLeftArrow,
        .keyboardRightArrow,
        .keyboardHome,
        .keyboardEnd,
        .keyboardPageUp,
        .keyboardPageDown,
    ]

    private static let blockedModifiers: UIKeyModifierFlags = [.command, .control, .alternate]

    static func shouldRepeat(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
        repeatableKeyCodes.contains(keyCode) && modifiers.intersection(blockedModifiers).isEmpty
    }
}

@MainActor
final class TerminalIOSKeyRepeatRuntime {
    typealias CanRouteInput = @MainActor () -> Bool
    typealias SendDirectRepeat = @MainActor (UIKey) -> Bool
    typealias SendFallbackRepeat = @MainActor (Ghostty.Input.Key, UIKeyModifierFlags) -> Void
    typealias RequestRender = @MainActor () -> Void

    private var timer: DispatchSourceTimer?
    private var repeatingHardwareKey: UIKey?
    private var repeatingFallbackKey: Ghostty.Input.Key?
    private var repeatingFallbackModifiers: UIKeyModifierFlags = []
    private var repeatingKeyCode: UInt16?

    deinit {
        timer?.cancel()
    }

    func start(
        for key: UIKey,
        fallbackKey: Ghostty.Input.Key?,
        canRouteInput: @escaping CanRouteInput,
        sendDirectRepeat: @escaping SendDirectRepeat,
        sendFallbackRepeat: @escaping SendFallbackRepeat,
        requestRender: @escaping RequestRender
    ) {
        guard TerminalHardwareKeyRepeatPolicy.shouldRepeat(
            keyCode: key.keyCode,
            modifiers: key.modifierFlags
        ) else { return }

        stop()

        repeatingHardwareKey = key
        repeatingFallbackKey = fallbackKey
        repeatingFallbackModifiers = key.modifierFlags
        repeatingKeyCode = UInt16(key.keyCode.rawValue)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleRepeatTick(
                    canRouteInput: canRouteInput,
                    sendDirectRepeat: sendDirectRepeat,
                    sendFallbackRepeat: sendFallbackRepeat,
                    requestRender: requestRender
                )
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        repeatingHardwareKey = nil
        repeatingFallbackKey = nil
        repeatingFallbackModifiers = []
        repeatingKeyCode = nil
    }

    func isRepeating(keyCode: UInt16) -> Bool {
        repeatingKeyCode == keyCode
    }

    private func handleRepeatTick(
        canRouteInput: CanRouteInput,
        sendDirectRepeat: SendDirectRepeat,
        sendFallbackRepeat: SendFallbackRepeat,
        requestRender: RequestRender
    ) {
        guard canRouteInput() else {
            stop()
            return
        }

        if let repeatKey = repeatingHardwareKey,
           sendDirectRepeat(repeatKey) {
            requestRender()
            return
        }

        if let fallbackKey = repeatingFallbackKey {
            sendFallbackRepeat(fallbackKey, repeatingFallbackModifiers)
        }
        requestRender()
    }
}
#endif
