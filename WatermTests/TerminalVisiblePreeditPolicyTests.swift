import Testing
@testable import Waterm

// Test Context:
// These tests protect visible preedit policy for marked text in terminal input.
// They use pure policy values and no platform IME; update only when intended IME
// display behavior changes.

struct TerminalVisiblePreeditPolicyTests {
    @Test
    func hidesEnglishMarkedText() {
        #expect(TerminalVisiblePreeditPolicy.shouldDisplay("hello", inputModePrimaryLanguage: "en-US") == false)
    }

    @Test
    func hidesCyrillicMarkedText() {
        #expect(TerminalVisiblePreeditPolicy.shouldDisplay("привет", inputModePrimaryLanguage: "ru-RU") == false)
    }

    @Test
    func showsChineseRomanizedPreeditIncludingSpaces() {
        #expect(TerminalVisiblePreeditPolicy.shouldDisplay("ni hao", inputModePrimaryLanguage: "zh-Hans") == true)
    }

    @Test
    func showsJapaneseRomanizedPreedit() {
        #expect(TerminalVisiblePreeditPolicy.shouldDisplay("nihon", inputModePrimaryLanguage: "ja-JP") == true)
    }

    @Test
    func showsNativeHangulPreedit() {
        #expect(TerminalVisiblePreeditPolicy.shouldDisplay("한", inputModePrimaryLanguage: "ko-KR") == true)
    }

    @Test
    func hidesWhitespaceOnlyMarkedText() {
        #expect(TerminalVisiblePreeditPolicy.shouldDisplay("   ", inputModePrimaryLanguage: "zh-Hans") == false)
    }
}
