import Foundation

struct TerminalConnectionSurfaceSize: Equatable, Sendable {
    let columns: Int
    let rows: Int
}

@MainActor
protocol TerminalConnectionSurface: AnyObject {
    func connectionSurfaceSize() -> TerminalConnectionSurfaceSize?
    func writeConnectionOutput(_ data: Data)
    func connectionSurfaceExited(_ exitCode: UInt32)
}

extension GhosttyTerminalView: TerminalConnectionSurface {
    func connectionSurfaceSize() -> TerminalConnectionSurfaceSize? {
        guard let size = terminalSize() else { return nil }
        return TerminalConnectionSurfaceSize(
            columns: Int(size.columns),
            rows: Int(size.rows)
        )
    }

    func writeConnectionOutput(_ data: Data) {
        writeOutput(data)
    }

    func connectionSurfaceExited(_ exitCode: UInt32) {
        externalExited(exitCode)
    }
}

@MainActor
final class TerminalSurfaceRegistry {
    private struct TestSurface {
        let pause: () -> Void
        let cleanup: () -> Void
    }

    private var surfaces: [TerminalEntityID: GhosttyTerminalView] = [:]
    private var testSurfaces: [TerminalEntityID: TestSurface] = [:]
    private var accessOrder: [TerminalEntityID] = []

    var count: Int {
        surfaces.count + testSurfaces.count
    }

    var entityIds: Set<TerminalEntityID> {
        Set(surfaces.keys).union(testSurfaces.keys)
    }

    var allSurfaces: [GhosttyTerminalView] {
        Array(surfaces.values)
    }

    func register(_ surface: GhosttyTerminalView, for entityId: TerminalEntityID) {
        surfaces[entityId] = surface
        testSurfaces.removeValue(forKey: entityId)
        touch(entityId)
    }

    func surface(for entityId: TerminalEntityID) -> GhosttyTerminalView? {
        surfaces[entityId]
    }

    func accessedSurface(for entityId: TerminalEntityID) -> GhosttyTerminalView? {
        guard let surface = surfaces[entityId] else { return nil }
        touch(entityId)
        return surface
    }

    func hasSurface(for entityId: TerminalEntityID) -> Bool {
        surfaces[entityId] != nil || testSurfaces[entityId] != nil
    }

    func detachSurface(for entityId: TerminalEntityID, cleanup: Bool) {
        if cleanup {
            cleanupSurface(for: entityId)
        } else {
            surfaces[entityId]?.pauseRendering()
            testSurfaces[entityId]?.pause()
        }
    }

    @discardableResult
    func removeSurface(for entityId: TerminalEntityID, cleanup: Bool) -> Bool {
        let hadSurface = hasSurface(for: entityId)
        if cleanup {
            cleanupSurface(for: entityId)
        } else {
            surfaces.removeValue(forKey: entityId)
            testSurfaces.removeValue(forKey: entityId)
            removeFromAccessOrder(entityId)
        }
        return hadSurface
    }

    func removeAll(cleanup: Bool) -> [GhosttyTerminalView] {
        let removedSurfaces = Array(surfaces.values)
        let removedTestSurfaces = Array(testSurfaces.values)
        surfaces.removeAll()
        testSurfaces.removeAll()
        accessOrder.removeAll()

        guard cleanup else { return removedSurfaces }
        for surface in removedSurfaces {
            surface.cleanup()
        }
        for testSurface in removedTestSurfaces {
            testSurface.cleanup()
        }
        return removedSurfaces
    }

    func touch(_ entityId: TerminalEntityID) {
        removeFromAccessOrder(entityId)
        accessOrder.append(entityId)
    }

    func removeFromAccessOrder(_ entityId: TerminalEntityID) {
        accessOrder.removeAll { $0 == entityId }
    }

    func evictOldest(
        maxCount: Int,
        preserving preservedEntityId: TerminalEntityID?,
        onEvict: (TerminalEntityID) -> Void
    ) {
        while count >= maxCount, let oldestId = accessOrder.first {
            if oldestId == preservedEntityId {
                accessOrder.removeFirst()
                accessOrder.append(oldestId)
                continue
            }

            accessOrder.removeFirst()
            cleanupSurface(for: oldestId)
            onEvict(oldestId)
        }
    }

    private func cleanupSurface(for entityId: TerminalEntityID) {
        if let surface = surfaces.removeValue(forKey: entityId) {
            #if os(iOS)
            surface.onKeyboardBrowseModeChange = nil
            surface.onFindNavigatorVisibilityChange = nil
            #endif
            surface.cleanup()
        }
        if let testSurface = testSurfaces.removeValue(forKey: entityId) {
            testSurface.cleanup()
        }
        removeFromAccessOrder(entityId)
    }
}

#if DEBUG
extension TerminalSurfaceRegistry {
    func registerForTesting(
        entityId: TerminalEntityID,
        pause: @escaping () -> Void,
        cleanup: @escaping () -> Void
    ) {
        testSurfaces[entityId] = TestSurface(pause: pause, cleanup: cleanup)
        surfaces.removeValue(forKey: entityId)
        touch(entityId)
    }
}
#endif
