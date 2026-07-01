import Testing
@testable import Waterm

// Test Context:
// These tests protect the Ghostty runtime app userdata boundary. Ghostty may
// call app-level C callbacks from runtime-owned threads, so userdata must point
// at an explicit callback context that can be invalidated before the app handle
// is freed. Fakes do not initialize libghostty; update these tests only if
// app-level runtime callbacks move to a different stable owner.

@MainActor
struct GhosttyAppCallbackContextTests {
    @Test
    func contextResolvesAppFromUserdataUntilInvalidated() {
        // Given a Ghostty app wrapper that has not started libghostty.
        let app = Ghostty.App(autoStart: false)
        let context = GhosttyAppCallbackContext(app: app)

        // When Ghostty calls back with the context userdata pointer.
        let resolved = GhosttyAppCallbackContext.app(fromUserdata: context.opaquePointer)

        // Then callbacks can recover the app owner without using a raw App
        // userdata pointer.
        #expect(resolved === app)

        // When the app owner invalidates callback userdata during cleanup.
        context.invalidate()

        // Then late callbacks fail closed instead of resolving a released app.
        #expect(GhosttyAppCallbackContext.app(fromUserdata: context.opaquePointer) == nil)
        #expect(GhosttyAppCallbackContext.app(fromUserdata: nil) == nil)
    }
}
