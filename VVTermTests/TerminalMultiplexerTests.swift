import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal multiplexer domain rules such as tmux/mosh mode
// selection and value normalization. They use pure model values; update only
// when supported multiplexer semantics intentionally change.

struct TerminalMultiplexerTests {
    @Test func legacyTrueMapsToTmux() {
        #expect(TerminalMultiplexer.fromLegacyTmuxEnabled(true) == .tmux)
    }

    @Test func legacyFalseMapsToNone() {
        #expect(TerminalMultiplexer.fromLegacyTmuxEnabled(false) == .none)
    }

    @Test func isEnabledReflectsKind() {
        #expect(TerminalMultiplexer.none.isEnabled == false)
        #expect(TerminalMultiplexer.tmux.isEnabled == true)
        #expect(TerminalMultiplexer.zmx.isEnabled == true)
    }

    @Test func roundTripsRawValue() {
        for m in TerminalMultiplexer.allCases {
            #expect(TerminalMultiplexer(rawValue: m.rawValue) == m)
        }
    }
}
