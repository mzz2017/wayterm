#if os(iOS)
import Foundation
import UIKit

@MainActor
final class TerminalIOSInputRuntime {
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
}
#endif
