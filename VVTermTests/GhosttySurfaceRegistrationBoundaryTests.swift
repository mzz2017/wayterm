import Foundation
import Testing

// Test Context:
// These source-boundary tests protect Ghostty surface registration ownership.
// Platform terminal views may create and use a surface, but registration with
// Ghostty.App should be owned by a focused lease so cleanup and deinit fallback
// stay consistent across iOS and macOS. Update these tests only if surface
// tracking intentionally moves to another lifecycle owner.

@Suite(.serialized)
struct GhosttySurfaceRegistrationBoundaryTests {
    @Test
    func platformTerminalViewsDelegateSurfaceRegistrationToLease() throws {
        let root = try sourceRoot()
        let iOSSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let macOSSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/macOS/GhosttyTerminalView+macOS.swift")
        )
        let macOSLifecycleSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/macOS/TerminalMacOSSurfaceLifecycleRuntime.swift")
        )
        let iOSSurfaceSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/GhosttyTerminalView+SurfaceRuntime+iOS.swift")
        )
        let iOSSurfaceOwnerSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )
        let registrationSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/Surface/GhosttySurfaceRegistration.swift")
        )
        let iOSLifecycleSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceLifecycleRuntime.swift")
        )

        // Given both platform terminal views create Ghostty surfaces.
        #expect(iOSSource.contains("let surfaceRegistration = GhosttySurfaceRegistration()"))
        #expect(macOSSource.contains("private let surfaceRegistration = GhosttySurfaceRegistration()"))
        #expect(iOSSurfaceOwnerSource.contains("surfaceRegistration.register(cSurface"))
        #expect(macOSSource.contains("surfaceRegistration.register(cSurface"))
        #expect(iOSSurfaceSource.contains("surfaceRegistration: surfaceRegistration"))
        #expect(iOSLifecycleSource.contains("surfaceRegistration.unregister()"))
        #expect(macOSLifecycleSource.contains("surfaceRegistration.unregister()"))
        #expect(iOSSource.contains("surfaceRegistration.unregisterLaterFromDeinit()"))
        #expect(macOSSource.contains("surfaceRegistration.unregisterLaterFromDeinit()"))

        // Then platform views do not own Ghostty.App registration references
        // or duplicate registration teardown policy.
        #expect(!iOSSource.contains("SurfaceReference"))
        #expect(!macOSSource.contains("SurfaceReference"))
        #expect(!iOSSource.contains("registerSurface"))
        #expect(!macOSSource.contains("registerSurface"))
        #expect(!iOSSource.contains("unregisterSurface"))
        #expect(!macOSSource.contains("unregisterSurface"))
        #expect(
            !iOSSurfaceSource.contains("surfaceRegistration.register(cSurface"),
            "iOS surface runtime should pass the registration lease to the surface owner instead of registering raw surfaces directly."
        )

        #expect(registrationSource.contains("final class GhosttySurfaceRegistration: @unchecked Sendable"))
        #expect(
            registrationSource.contains("private let lock = NSLock()"),
            "Surface registration should protect its app/reference lease state for nonisolated deinit fallback."
        )
        #expect(
            registrationSource.contains("takeReference()"),
            "Surface registration teardown should atomically take and clear the current lease before unregistering."
        )
        #expect(registrationSource.contains("func register(_ surface: ghostty_surface_t"))
        #expect(registrationSource.contains("func unregister()"))
        #expect(registrationSource.contains("func unregisterLaterFromDeinit()"))
        #expect(registrationSource.contains("appWrapper.registerSurface"))
        #expect(registrationSource.contains("appWrapper.unregisterSurface"))
        #expect(registrationSource.contains("GhosttySurfaceDeferredUnregisterTaskRegistry"))
        #expect(registrationSource.contains("waitForDeferredUnregisters()"))
        #expect(
            registrationSource.contains("return Self.deferredUnregisterTasks.track"),
            "Deinit fallback unregister should publish a tracked task that tests and later lifecycle paths can await."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
