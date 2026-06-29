#if os(iOS)
import UIKit

final class TerminalNativeTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

final class TerminalNativeTextRange: UITextRange {
    let startPosition: TerminalNativeTextPosition
    let endPosition: TerminalNativeTextPosition

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startPosition.offset == endPosition.offset }

    var nsRange: NSRange {
        NSRange(location: startPosition.offset, length: endPosition.offset - startPosition.offset)
    }

    init(start: Int, end: Int) {
        let lowerBound = min(start, end)
        let upperBound = max(start, end)
        self.startPosition = TerminalNativeTextPosition(offset: lowerBound)
        self.endPosition = TerminalNativeTextPosition(offset: upperBound)
        super.init()
    }
}

final class TerminalNativeSelectionRect: UITextSelectionRect {
    private let storedRect: CGRect
    private let storedContainsStart: Bool
    private let storedContainsEnd: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        self.storedRect = rect
        self.storedContainsStart = containsStart
        self.storedContainsEnd = containsEnd
        super.init()
    }

    override var rect: CGRect { storedRect }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { storedContainsStart }
    override var containsEnd: Bool { storedContainsEnd }
    override var isVertical: Bool { false }

    @available(iOS 17.4, *)
    override var transform: CGAffineTransform { .identity }
}

struct TerminalNativeFindDecoration {
    let range: NSRange
    let style: UITextSearchFoundTextStyle
}

final class TerminalNativeFindOverlayView: UIView {
    struct Highlight {
        let rect: CGRect
        let style: UITextSearchFoundTextStyle
    }

    var highlights: [Highlight] = [] {
        didSet {
            isHidden = highlights.isEmpty
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isHidden = true
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        for highlight in highlights where highlight.style == .found {
            let path = UIBezierPath(roundedRect: highlight.rect.insetBy(dx: 1, dy: 2), cornerRadius: 4)
            context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.16).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }

        for highlight in highlights where highlight.style == .highlighted {
            let path = UIBezierPath(roundedRect: highlight.rect.insetBy(dx: 1, dy: 1), cornerRadius: 4)
            context.setFillColor(UIColor.systemOrange.withAlphaComponent(0.24).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()

            context.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1)
            context.addPath(path.cgPath)
            context.strokePath()
        }
    }
}

extension TerminalNativeTextSearchOptions {
    init(_ options: UITextSearchOptions) {
        self.init(
            compareOptions: options.stringCompareOptions,
            wordMatchMethod: WordMatchMethod(options.wordMatchMethod)
        )
    }
}

private extension TerminalNativeTextSearchOptions.WordMatchMethod {
    init(_ method: UITextSearchOptions.WordMatchMethod) {
        switch method {
        case .contains:
            self = .contains
        case .startsWith:
            self = .startsWith
        case .fullWord:
            self = .fullWord
        @unknown default:
            self = .contains
        }
    }
}

extension TerminalNativeTextSnapshot {
    func nativeRange(from range: UITextRange?) -> NSRange? {
        guard let range = range as? TerminalNativeTextRange else { return nil }
        return clampedRange(range.nsRange)
    }

    func nativeRange(_ range: NSRange?) -> TerminalNativeTextRange? {
        guard let range else { return nil }
        let clamped = clampedRange(range)
        return TerminalNativeTextRange(start: clamped.location, end: clamped.location + clamped.length)
    }

    func selectionRects(for range: NSRange) -> [TerminalNativeSelectionRect] {
        selectionRectFrames(for: range).map { frame in
            TerminalNativeSelectionRect(
                rect: frame.rect,
                containsStart: frame.containsStart,
                containsEnd: frame.containsEnd
            )
        }
    }

    func searchRanges(query: String, options: UITextSearchOptions) -> [NSRange] {
        searchRanges(query: query, options: TerminalNativeTextSearchOptions(options))
    }
}
#endif
