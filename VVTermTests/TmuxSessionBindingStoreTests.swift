import Testing
import Foundation
@testable import VVTerm

// Test Context:
// These tests protect tmux session binding persistence used to reconnect terminal
// panes to managed tmux sessions. Fakes use isolated storage and no remote tmux;
// update only when binding persistence semantics intentionally change.

struct TmuxSessionBindingStoreTests {
    private func makeStore() -> (TmuxSessionBindingStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return (TmuxSessionBindingStore(defaults: suite), suite)
    }

    @Test func setThenGetRoundTrips() {
        let (store, _) = makeStore()
        let id = UUID()
        store.set(TmuxSessionBinding(sessionName: "dev", ownership: "external", multiplexer: "zmx"), for: id)
        let got = store.binding(for: id)
        #expect(got?.sessionName == "dev")
        #expect(got?.ownership == "external")
        #expect(got?.multiplexer == "zmx")
    }

    @Test func removeDeletes() {
        let (store, _) = makeStore()
        let id = UUID()
        store.set(TmuxSessionBinding(sessionName: "x", ownership: "managed", multiplexer: "tmux"), for: id)
        store.remove(for: id)
        #expect(store.binding(for: id) == nil)
    }

    @Test func persistsAcrossInstances() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let id = UUID()
        TmuxSessionBindingStore(defaults: suite).set(
            TmuxSessionBinding(sessionName: "keep", ownership: "external", multiplexer: "tmux"), for: id)
        let reloaded = TmuxSessionBindingStore(defaults: suite)
        #expect(reloaded.binding(for: id)?.sessionName == "keep")
    }
}
