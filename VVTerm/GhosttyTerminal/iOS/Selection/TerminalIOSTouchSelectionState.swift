#if os(iOS)
import Foundation

@MainActor
final class TerminalIOSTouchSelectionState {
    private var anchor: TerminalGridPoint?
    private var seed: TerminalGridSelection?
    private(set) var selection: TerminalGridSelection?

    var hasSelection: Bool {
        selection != nil
    }

    func clear() {
        anchor = nil
        seed = nil
        selection = nil
    }

    @discardableResult
    func setSelection(_ selection: TerminalGridSelection?) -> Bool {
        anchor = nil
        seed = nil
        self.selection = selection?.normalized
        return true
    }

    @discardableResult
    func begin(wordSelection: TerminalGridSelection?, point: TerminalGridPoint?) -> Bool {
        if let wordSelection {
            let normalized = wordSelection.normalized
            anchor = nil
            seed = normalized
            selection = normalized
            return true
        }

        guard let point else { return false }
        anchor = point
        seed = nil
        selection = TerminalGridSelection(start: point, end: point)
        return true
    }

    @discardableResult
    func update(to point: TerminalGridPoint) -> Bool {
        if anchor == nil, let normalizedSeed = seed?.normalized {
            if point < normalizedSeed.start {
                anchor = normalizedSeed.end
            } else if point > normalizedSeed.end {
                anchor = normalizedSeed.start
            } else {
                selection = normalizedSeed
                return true
            }
        }

        guard let anchor else { return false }
        selection = TerminalGridSelection(start: anchor, end: point).normalized
        return true
    }

    @discardableResult
    func updateHandle(_ kind: TerminalTouchSelectionHandleKind, to point: TerminalGridPoint) -> Bool {
        guard var selection = selection?.normalized else { return false }

        switch kind {
        case .start:
            selection.start = point
        case .end:
            selection.end = point
        }

        self.selection = selection.normalized
        return true
    }
}
#endif
