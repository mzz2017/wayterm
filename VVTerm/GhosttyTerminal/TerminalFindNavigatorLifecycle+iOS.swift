//
//  TerminalFindNavigatorLifecycle+iOS.swift
//  VVTerm
//
//  Native find navigator lifecycle state for iOS Ghostty terminal.
//

#if os(iOS)
struct TerminalFindNavigatorLifecycle {
    private(set) var isActive = false
    private(set) var suppressedGhosttySearchEndCount = 0
    private var restoreTerminalFocusAfterEnd = false

    mutating func begin(restoreTerminalFocus: Bool) {
        if isActive {
            restoreTerminalFocusAfterEnd = restoreTerminalFocusAfterEnd || restoreTerminalFocus
        } else {
            restoreTerminalFocusAfterEnd = restoreTerminalFocus
        }
        isActive = true
    }

    mutating func end() -> Bool {
        isActive = false
        let shouldRestoreFocus = restoreTerminalFocusAfterEnd
        restoreTerminalFocusAfterEnd = false
        return shouldRestoreFocus
    }

    mutating func suppressNextGhosttySearchEnd() {
        suppressedGhosttySearchEndCount += 1
    }

    mutating func cancelSuppressedGhosttySearchEnd() {
        guard suppressedGhosttySearchEndCount > 0 else { return }
        suppressedGhosttySearchEndCount -= 1
    }

    mutating func consumeSuppressedGhosttySearchEnd() -> Bool {
        guard suppressedGhosttySearchEndCount > 0 else { return false }
        suppressedGhosttySearchEndCount -= 1
        return true
    }
}

#endif
