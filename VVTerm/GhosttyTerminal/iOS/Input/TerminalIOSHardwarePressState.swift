#if os(iOS)
import UIKit

struct TerminalIOSHardwarePressRelease {
    let fallbackKey: Ghostty.Input.Key?
    let fallbackModifiers: UIKeyModifierFlags
}

@MainActor
final class TerminalIOSHardwarePressState {
    private var ghosttyPressKeyCodes: Set<UInt16> = []
    private var fallbackPresses: [UInt16: (key: Ghostty.Input.Key, modifiers: UIKeyModifierFlags)] = [:]
    private var systemTextInputKeyCodes: Set<UInt16> = []
    private var pendingSystemTextInputHardwareKeys: [UIKey] = []

    var hasGhosttyPresses: Bool {
        !ghosttyPressKeyCodes.isEmpty
    }

    var pendingSystemTextInputHardwareKeyCount: Int {
        pendingSystemTextInputHardwareKeys.count
    }

    func clear() {
        ghosttyPressKeyCodes.removeAll()
        fallbackPresses.removeAll()
        systemTextInputKeyCodes.removeAll()
        pendingSystemTextInputHardwareKeys.removeAll()
    }

    func clearPendingSystemTextInputHardwareKeys() {
        pendingSystemTextInputHardwareKeys.removeAll()
    }

    func recordSystemTextInputPress(keyCode: UInt16) {
        systemTextInputKeyCodes.insert(keyCode)
    }

    func appendPendingSystemTextInputHardwareKey(_ key: UIKey) {
        pendingSystemTextInputHardwareKeys.append(key)
    }

    func consumePendingSystemTextInputHardwareKey() -> UIKey? {
        guard !pendingSystemTextInputHardwareKeys.isEmpty else { return nil }
        return pendingSystemTextInputHardwareKeys.removeFirst()
    }

    func discardPendingSystemTextInputHardwareKey() {
        guard !pendingSystemTextInputHardwareKeys.isEmpty else { return }
        pendingSystemTextInputHardwareKeys.removeFirst()
    }

    func removeUnconsumedPendingSystemTextInputHardwareKeys(after pendingCount: Int) {
        guard pendingSystemTextInputHardwareKeys.count > pendingCount else { return }
        pendingSystemTextInputHardwareKeys.removeSubrange(pendingCount...)
    }

    func recordDirectGhosttyPress(keyCode: UInt16) {
        ghosttyPressKeyCodes.insert(keyCode)
        fallbackPresses.removeValue(forKey: keyCode)
    }

    func recordFallbackGhosttyPress(
        keyCode: UInt16,
        fallbackKey: Ghostty.Input.Key,
        modifiers: UIKeyModifierFlags
    ) {
        ghosttyPressKeyCodes.insert(keyCode)
        fallbackPresses[keyCode] = (fallbackKey, modifiers)
    }

    func recordInterpretedHardwareKey(keyCode: UInt16) {
        ghosttyPressKeyCodes.insert(keyCode)
        systemTextInputKeyCodes.remove(keyCode)
    }

    func releaseGhosttyPress(
        keyCode: UInt16,
        defaultModifiers: UIKeyModifierFlags
    ) -> TerminalIOSHardwarePressRelease? {
        guard ghosttyPressKeyCodes.remove(keyCode) != nil else {
            removeUntrackedPress(keyCode: keyCode)
            return nil
        }

        let fallbackPress = fallbackPresses.removeValue(forKey: keyCode)
        return TerminalIOSHardwarePressRelease(
            fallbackKey: fallbackPress?.key,
            fallbackModifiers: fallbackPress?.modifiers ?? defaultModifiers
        )
    }

    func cancelPress(keyCode: UInt16) {
        ghosttyPressKeyCodes.remove(keyCode)
        fallbackPresses.removeValue(forKey: keyCode)
        systemTextInputKeyCodes.remove(keyCode)
    }

    private func removeUntrackedPress(keyCode: UInt16) {
        fallbackPresses.removeValue(forKey: keyCode)
        systemTextInputKeyCodes.remove(keyCode)
    }
}
#endif
