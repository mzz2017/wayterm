import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal accessory preference persistence, defaults, and
// CloudKit sync task ownership. Fakes use isolated storage plus controlled
// cloud/drain gates, with no keyboard UI or real CloudKit. Update these tests
// only when preference storage or the TerminalAccessories application owner for
// cloud sync intentionally changes.

@MainActor
final class TerminalAccessoryPreferencesManagerTests: XCTestCase {
    private var syncWasEnabledObject: Any?
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        syncWasEnabledObject = UserDefaults.standard.object(forKey: SyncSettings.enabledKey)
        UserDefaults.standard.set(false, forKey: SyncSettings.enabledKey)

        defaultsSuiteName = "TerminalAccessoryPreferencesManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        if let syncWasEnabledObject {
            UserDefaults.standard.set(syncWasEnabledObject, forKey: SyncSettings.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncSettings.enabledKey)
        }

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        syncWasEnabledObject = nil
        super.tearDown()
    }

    func testCreateCustomActionPersistsAndUpdatesProfileMetadata() throws {
        let manager = TerminalAccessoryPreferencesManager(defaults: defaults)

        let action = try manager.createCustomAction(
            title: "List Files",
            kind: .command,
            commandContent: "ls -la",
            commandSendMode: .insertAndEnter,
            shortcutKey: .l,
            shortcutModifiers: .init(control: true)
        )

        XCTAssertEqual(manager.customActions.map(\.id), [action.id])
        XCTAssertEqual(manager.profile.lastWriterDeviceId, DeviceIdentity.id)
        XCTAssertEqual(manager.profile.customActions.first?.commandContent, "ls -la")
        XCTAssertNotNil(defaults.data(forKey: TerminalAccessoryProfile.defaultsKey))
    }

    func testResetToDefaultLayoutRestoresActiveItems() {
        let manager = TerminalAccessoryPreferencesManager(defaults: defaults)
        manager.removeActiveItem(.system(.escape))

        XCTAssertNotEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)

        manager.resetToDefaultLayout()

        XCTAssertEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)
        XCTAssertEqual(manager.profile.lastWriterDeviceId, DeviceIdentity.id)
    }

    func testCustomActionLimitUsesInjectedProStatus() {
        let freeManager = TerminalAccessoryPreferencesManager(
            defaults: defaults,
            dependencies: TerminalAccessoryPreferencesDependencies(isPro: { false })
        )
        let proManager = TerminalAccessoryPreferencesManager(
            defaults: defaults,
            dependencies: TerminalAccessoryPreferencesDependencies(isPro: { true })
        )

        XCTAssertEqual(
            freeManager.customActionLimit,
            FreeTierLimits.maxCustomActions,
            "Free tier accessory limits should come from the injected entitlement provider."
        )
        XCTAssertEqual(
            proManager.customActionLimit,
            TerminalAccessoryProfile.maxCustomActions,
            "Pro accessory limits should come from the injected entitlement provider."
        )
    }

    func testCreateCustomActionTracksThroughInjectedAnalytics() throws {
        var trackedKinds: [TerminalAccessoryCustomActionKind] = []
        let manager = TerminalAccessoryPreferencesManager(
            defaults: defaults,
            dependencies: TerminalAccessoryPreferencesDependencies(
                isPro: { true },
                trackCustomActionCreated: { kind in
                    trackedKinds.append(kind)
                }
            )
        )

        _ = try manager.createCustomAction(
            title: "List Files",
            kind: .command,
            commandContent: "ls -la",
            commandSendMode: .insertAndEnter,
            shortcutKey: .l,
            shortcutModifiers: .init(control: true)
        )

        XCTAssertEqual(
            trackedKinds,
            [.command],
            "Custom action analytics should be emitted through the injected analytics dependency."
        )
    }

    func testStartupCloudSyncTracksCloudMergeAndPendingDrainUntilCompletion() async throws {
        UserDefaults.standard.set(true, forKey: SyncSettings.enabledKey)
        let cloudProfileSync = FakeTerminalAccessoryCloudProfileSync()
        let syncCoordinator = FakeTerminalAccessoryPendingSyncCoordinator()

        // Given startup sync is enabled with fake CloudKit and drain work that
        // remain pending until the test releases each phase.
        let manager = TerminalAccessoryPreferencesManager(
            defaults: defaults,
            cloudProfileSync: cloudProfileSync,
            syncCoordinator: syncCoordinator,
            startObservers: false
        )

        await cloudProfileSync.waitUntilSyncStarted()
        XCTAssertTrue(
            manager.hasPendingStartupCloudSyncForTesting,
            "Startup accessory sync must remain tracked while CloudKit merge is pending."
        )

        await cloudProfileSync.finishSync()
        await syncCoordinator.waitUntilDrainStarted()
        XCTAssertTrue(
            manager.hasPendingStartupCloudSyncForTesting,
            "Startup accessory sync must remain tracked while pending mutation drain is pending."
        )

        await syncCoordinator.finishDrain()
        await manager.waitForStartupCloudSyncForTesting()

        XCTAssertFalse(
            manager.hasPendingStartupCloudSyncForTesting,
            "TerminalAccessoryPreferencesManager should clear startup sync tracking after cloud merge and drain finish."
        )
    }

    func testStartupCloudSyncDoesNotApplyCloudResultAfterSyncIsDisabled() async throws {
        UserDefaults.standard.set(true, forKey: SyncSettings.enabledKey)
        let remoteAction = TerminalAccessoryCustomAction(
            title: "Remote Only",
            kind: .command,
            commandContent: "uptime",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let remoteProfile = TerminalAccessoryProfile(
            schemaVersion: TerminalAccessoryProfile.schemaVersion,
            layout: TerminalAccessoryProfile.defaultValue.layout,
            customActions: [remoteAction],
            updatedAt: Date(timeIntervalSince1970: 100),
            lastWriterDeviceId: "remote-device"
        )
        let cloudProfileSync = FakeTerminalAccessoryCloudProfileSync(resolvedProfile: remoteProfile)
        let syncCoordinator = FakeTerminalAccessoryPendingSyncCoordinator(blocksDrain: false)

        // Given startup CloudKit work is already awaiting a remote result.
        let manager = TerminalAccessoryPreferencesManager(
            defaults: defaults,
            cloudProfileSync: cloudProfileSync,
            syncCoordinator: syncCoordinator,
            startObservers: false
        )
        await cloudProfileSync.waitUntilSyncStarted()

        // When sync is disabled before the CloudKit await resumes.
        UserDefaults.standard.set(false, forKey: SyncSettings.enabledKey)
        await cloudProfileSync.finishSync()
        await manager.waitForStartupCloudSyncForTesting()

        // Then the stale remote result must not be merged into local state.
        XCTAssertTrue(
            manager.customActions.isEmpty,
            "A cloud result that resumes after sync is disabled should be dropped instead of changing local accessories."
        )
    }

    func testCloudSyncObserversUseTrackedApplicationTasks() throws {
        // Given the TerminalAccessories application owner source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent(
                "VVTerm/Features/TerminalAccessories/Application/TerminalAccessoryPreferencesManager.swift"
            )
        )

        // Then startup and observer-triggered CloudKit work must go through
        // named tracked task helpers instead of anonymous callback-owned Tasks.
        XCTAssertFalse(
            source.contains("Task {\n            await syncWithCloud()\n            await syncCoordinator.drainPendingMutations()"),
            "Startup accessory sync should be owned by a stored manager task."
        )
        XCTAssertFalse(
            source.contains("Task { @MainActor [weak self] in\n                await self?.syncWithCloudIfNeededForForeground()"),
            "Foreground accessory sync should be owned by a stored manager task."
        )
        XCTAssertFalse(
            source.contains("await self.syncWithCloud()\n                } else {\n                    self.pendingSyncTask?.cancel()"),
            "Sync-toggle accessory sync should be owned by a stored manager task."
        )
        XCTAssertFalse(
            source.contains("Task { @MainActor [weak self] in\n                guard let self,\n                      let resolvedProfile else"),
            "Cloud resolution application should be owned by a stored manager task."
        )
        XCTAssertTrue(
            source.contains("startStartupCloudSync"),
            "TerminalAccessoryPreferencesManager should expose a named startup sync tracking helper."
        )
        XCTAssertTrue(
            source.contains("startForegroundCloudSync"),
            "Foreground accessory sync should go through a named tracked task helper."
        )
        XCTAssertTrue(
            source.contains("startSyncToggleCloudSync"),
            "Sync-toggle accessory sync should go through a named tracked task helper."
        )
        XCTAssertTrue(
            source.contains("startCloudResolutionApply"),
            "Cloud resolution should go through a named tracked task helper."
        )
    }

    func testLiveCloudSyncDependenciesStayOutsidePreferencesManager() throws {
        // Given the TerminalAccessories application owner and App live wiring source.
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent(
                "VVTerm/Features/TerminalAccessories/Application/TerminalAccessoryPreferencesManager.swift"
            )
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent(
                "VVTerm/App/TerminalAccessoryPreferencesLiveDependencies.swift"
            )
        )

        // Then live CloudKit singletons should be wired at the App boundary, not
        // hidden inside the feature manager constructor.
        XCTAssertFalse(
            managerSource.contains("CloudKitManager.shared"),
            "TerminalAccessoryPreferencesManager should receive CloudKit profile sync through injected dependencies."
        )
        XCTAssertFalse(
            managerSource.contains("CloudKitSyncCoordinator.shared"),
            "TerminalAccessoryPreferencesManager should receive pending sync coordination through injected dependencies."
        )
        XCTAssertTrue(
            liveDependencySource.contains("cloudProfileSync: CloudKitManager.shared"),
            "App live wiring should provide CloudKit profile sync for terminal accessories."
        )
        XCTAssertTrue(
            liveDependencySource.contains("syncCoordinator: CloudKitSyncCoordinator.shared"),
            "App live wiring should provide CloudKit pending sync coordination for terminal accessories."
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

@MainActor
private final class FakeTerminalAccessoryCloudProfileSync: TerminalAccessoryCloudProfileSyncing {
    private let syncGate = TerminalAccessorySyncGate()
    private let resolvedProfile: TerminalAccessoryProfile?

    init(resolvedProfile: TerminalAccessoryProfile? = nil) {
        self.resolvedProfile = resolvedProfile
    }

    func syncTerminalAccessoryProfile(_ profile: TerminalAccessoryProfile) async throws -> TerminalAccessoryProfile {
        await syncGate.markStartedAndWait()
        return resolvedProfile ?? profile
    }

    func waitUntilSyncStarted() async {
        await syncGate.waitUntilStarted()
    }

    func finishSync() async {
        await syncGate.open()
    }
}

@MainActor
private final class FakeTerminalAccessoryPendingSyncCoordinator: TerminalAccessoryPendingSyncCoordinating {
    private let drainGate = TerminalAccessorySyncGate()
    private let blocksDrain: Bool
    private(set) var enqueuedProfiles: [TerminalAccessoryProfile] = []

    init(blocksDrain: Bool = true) {
        self.blocksDrain = blocksDrain
    }

    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) {
        enqueuedProfiles.append(profile)
    }

    func drainPendingMutations() async {
        guard blocksDrain else { return }
        await drainGate.markStartedAndWait()
    }

    func waitUntilDrainStarted() async {
        await drainGate.waitUntilStarted()
    }

    func finishDrain() async {
        await drainGate.open()
    }
}

private actor TerminalAccessorySyncGate {
    private var started = false
    private var isOpen = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWait() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
