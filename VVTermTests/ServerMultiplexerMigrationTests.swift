import Testing
import Foundation
@testable import VVTerm

// Test Context:
// These tests protect migration of legacy server multiplexer fields into the
// current domain model. They use encoded fixture data and no network access;
// update only when the persisted migration contract intentionally changes.

struct ServerMultiplexerMigrationTests {
    private func decode(_ json: String) throws -> Server {
        try JSONDecoder().decode(Server.self, from: Data(json.utf8))
    }

    private let base = """
    "id":"\(UUID().uuidString)","workspaceId":"\(UUID().uuidString)",
    "name":"s","host":"h","port":22,"username":"u","authMethod":"password",
    "tags":[],"isFavorite":false,"requiresBiometricUnlock":false,
    "createdAt":0,"updatedAt":0
    """

    @Test func decodesNewMultiplexerField() throws {
        let s = try decode("{\(base),\"multiplexerOverride\":\"zmx\"}")
        #expect(s.multiplexerOverride == .zmx)
    }

    @Test func migratesLegacyTmuxEnabledTrue() throws {
        let s = try decode("{\(base),\"tmuxEnabledOverride\":true}")
        #expect(s.multiplexerOverride == .tmux)
    }

    @Test func migratesLegacyTmuxEnabledFalse() throws {
        let s = try decode("{\(base),\"tmuxEnabledOverride\":false}")
        #expect(s.multiplexerOverride == TerminalMultiplexer.none)
    }

    @Test func nilWhenNeitherPresent() throws {
        let s = try decode("{\(base)}")
        #expect(s.multiplexerOverride == nil)
    }
}
