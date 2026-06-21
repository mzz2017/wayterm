# Swift Best Practice Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor VVTerm so Swift-owned long-lived resources have stable application or infrastructure owners, lifecycle work is awaitable or tracked, SwiftUI only sends user intent, and SSH/libssh2 behavior is testable without real network access.

**Architecture:** Move SSH shell lifecycle out of SwiftUI representable coordinators and into `Features/TerminalSessions/Application` runtimes. Wrap libssh2 and other external resources behind small actors/services in `Core/SSH`, then expose leases or command executors to TerminalSessions, RemoteFiles, Stats, and rich paste instead of sharing raw `SSHClient` ownership. Execute in safety-first phases: prevent stale shell registration, make close/open ordering awaitable, then move ownership and remove duplicated state.

**Tech Stack:** Swift, SwiftUI, UIKit/AppKit representables, Swift concurrency, actors, libssh2, OpenSSL, MoshCore, CloudKit, Keychain, XCTest, Xcode iOS simulator.

## Global Constraints

- Follow `docs/engineering/swift-best-practices.md` for all Swift, SwiftUI, Apple-platform, SSH, C/FFI, lifecycle, and concurrency changes.
- Feature-first architecture remains binding: app-owned code lands in `Features`, `Core`, or `App` based on ownership.
- Domain code remains value-semantic and pure where possible; runtime ownership belongs in `Application`, `Infrastructure`, services, actors, or stores.
- SwiftUI `View`, `UIViewRepresentable`, `NSViewRepresentable`, and Coordinator must not be the sole owner of SSH clients, sockets, shell tasks, file handles, timers, or background workers.
- UI sends intent only: open, close, retry, disconnect, trust host, install tmux/mosh, resize, send input.
- Lifecycle-critical work such as disconnect, close, retry, reconnect, auth, save, delete, sync, and cleanup must be awaited or tracked.
- Avoid untracked `Task {}` and `Task.detached {}` for lifecycle-critical work. If a call site cannot await, store or return a `Task` and make later operations wait on it.
- Non-trivial lifecycle state must be explicit; do not infer business lifecycle from view existence, optional object presence, selected tab, or cached terminal surfaces.
- C/FFI pointer lifetimes must stay local and obvious; raw C error codes must be logged before translation.
- libssh2 handles must not be shared simultaneously. `libssh2_init` uses process-global state and must remain serialized.
- Bug fixes and refactors require regression tests when feasible. Test lifecycle ordering, not only UI symptoms.
- Unit test files must include test context: protected behavior, target invariant, fake assumptions, and when the test should be updated instead of treated as a regression.
- iOS simulator focused tests use `ENABLE_DEBUG_DYLIB=NO`, `-parallel-testing-enabled NO`, and `-skip-testing:VVTermUITests`.
- Do not claim tests pass unless the test command actually completed.
- Commit atomically. Each commit must represent one invariant, boundary move, or documentation update.

---

## Scope Decision

This is a whole-project refactor objective, but the implementation must be split into independently reviewable phases. The first implementation wave is limited to SSH/resource lifecycle because it is the current user-visible failure path and the highest-risk deviation from the Swift rules. Later waves cover Core SSH/FFI, RemoteFiles/Stats shared connection usage, terminal surfaces, and general cleanup.

If a task reveals that this plan is wrong or too broad, update this file first, commit the plan correction, and then continue.

## Current Evidence

Read-only explorers and local inspection found the following highest-priority issues:

- `SSHTerminalWrapper` and split-pane `TerminalView` coordinators create and hold `SSHClient`, `shellTask`, and `shellId`, so SwiftUI lifecycle is still part of business lifecycle.
- `SSHConnectionRunner` lives in a UI file and owns connect, retry, start shell, stream, title parsing, process exit, and failure state transitions.
- Late shell registration can still be accepted after a session or pane has closed because `registerSSHClient` does not reject closed entities by generation.
- `ConnectionSessionManager` and `TerminalTabManager` duplicate terminal registry, SSH shell registry, connection state, tmux state, runtime title, selected server view, and connected server state.
- Split pane teardown is behind tab teardown. `TerminalView` still uses `Task.detached` in `cancelShell()` and `deinit`, and it does not always disconnect the client.
- `ConnectionState` lacks `closing`, `suspended`, and `authenticating` states; `connectedServerIds` can mean "has tab" rather than "has live transport".
- `ConnectionSessionManager` imports AppKit/UIKit and holds `GhosttyTerminalView`; terminal surface eviction can trigger SSH teardown.
- Core SSH timeout wrappers do not interrupt blocking C calls by themselves. Double-close and `nonisolated(unsafe)` abort paths need targeted tests.
- `SSHAuthenticationGate` serializes public-key auth but cancellation while waiting is not modeled.
- Remote tmux and mosh helpers collapse cancellation, timeout, and missing capability into similar outcomes.

## External Reference Constraints

- Swift structured concurrency scopes child task lifetimes, propagates cancellation, and cancellation is cooperative. Use structured tasks where parent operations must wait for child work.
- Swift API Design Guidelines require clarity at use sites, side-effectful method names as imperative verb phrases, and Boolean names that read as assertions.
- Apple documents `dismantleUIView` as custom view cleanup. Treat it as UI-surface cleanup, not as the only path that closes business resources.
- Apple documents `Data.withUnsafeBytes` pointers as valid only for the closure lifetime.
- libssh2 documents `libssh2_init` as process-global and not thread safe. VVTerm already serializes initialization; keep that invariant.
- libssh2 documents thread safety as "do not share handles simultaneously"; all session/channel/SFTP access must stay behind one owner.
- libssh2 documents `libssh2_session_free` as freeing all resources and typically being called after disconnect. Close channels and SFTP before freeing.

## Target File Structure

Create or modify these files over the refactor. Keep each file focused.

- Create `VVTerm/Features/TerminalSessions/Domain/TerminalEntityID.swift`
  - Defines `TerminalEntityID: Hashable, Sendable` with `.session(UUID)` and `.pane(UUID)`.
- Create `VVTerm/Features/TerminalSessions/Domain/TerminalEntityConnectionState.swift`
  - Defines explicit runtime states shared by sessions and panes.
- Create `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRuntime.swift`
  - Per entity actor that owns `SSHClient`, shell id, connect task, close task, generation, and runtime callbacks.
- Create `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRegistry.swift`
  - Main-actor store for runtimes, entity generations, start gates, close tracking, and server-level teardown waits.
- Create `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift`
  - Moves `SSHConnectionRunner` out of UI and accepts application-layer hooks.
- Create `VVTerm/Features/TerminalSessions/Application/TerminalSurfaceRegistry.swift`
  - Owns terminal UI surfaces separately from shell/client lifecycle.
- Create `VVTerm/Core/SSH/RemoteConnectionLease.swift`
  - Borrowed/owned lease type for RemoteFiles, Stats, and rich paste.
- Create `VVTerm/Core/SSH/RemoteCommandExecuting.swift`
  - Protocol for tmux/mosh/files/stats operations that need command execution but not raw client ownership.
- Create `VVTerm/Core/SSH/RemoteConnectionLeaseProvider.swift`
  - Application/Core boundary for resolving borrowed terminal leases or creating owned feature leases without each feature constructing `SSHClient` directly.
- Create `VVTerm/Features/RemoteFiles/Infrastructure/SFTPRemoteFileClient.swift`
  - RemoteFiles-owned capability protocol for SFTP/file operations; `SSHClient` conforms in infrastructure without leaking raw-client policy into application or UI.
- Create `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
  - Testable boundary for socket/libssh2 calls and raw error capture.
- Create `VVTermTests/Features/TerminalSessions/TerminalConnectionRegistryTests.swift`
  - Tests generation, stale registration rejection, close wait, duplicate start, and open-after-close ordering.
- Create `VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift`
  - Tests runtime state machine, connect/retry/close sequencing with fake SSH.
- Create `VVTermTests/Core/SSH/SSHAuthenticationGateCancellationTests.swift`
  - Tests cancellation-aware auth gate behavior.
- Create `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
  - Tests fd/session cleanup and raw error mapping using fakes.
- Create `VVTermTests/Features/RemoteFiles/SSHSFTPAdapterTests.swift`
  - Tests RemoteFiles lease ownership, operation serialization, and disconnect waiting without real network access.
- Create `VVTermTests/Features/Stats/ServerStatsCollectorLifecycleTests.swift`
  - Tests Stats start/stop/restart lease ordering and borrowed-client ownership without real network access.
- Modify `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
  - Becomes session domain orchestration and UI intent facade; no direct SSH client ownership after the runtime registry lands.
- Modify `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
  - Uses the shared runtime registry for panes; no detached pane teardown.
- Modify `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
  - Creates/attaches `GhosttyTerminalView`; no `SSHClient()` and no business teardown in coordinator/deinit.
- Modify `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
  - Same as above for panes.
- Modify `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
  - Sends retry/retrust/install intent to application use cases.
- Modify `VVTerm/Core/SSH/SSHClient.swift`
  - Shrinks toward high-level facade over `LibSSH2SessionDriver`, auth service, and mosh owner.
- Modify `VVTerm/Core/SSH/SSHAuthenticationGate.swift`
  - Add cancellation-aware waiters.
- Modify `VVTerm/Core/SSH/RemoteTmuxManager.swift` and `VVTerm/Core/SSH/RemoteMoshManager.swift`
  - Depend on `RemoteCommandExecuting` and preserve cancellation/timeout distinctions.
- Modify `VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift`
  - Use `RemoteConnectionLease`, no untracked owned-client disconnect.
- Modify `VVTerm/Features/Stats/Application/ServerStatsCollector.swift`
  - Use `RemoteConnectionLease`, no raw shared-client lifetime assumptions.

## Execution Rules

For every task:

- Start in an isolated worktree when executing the plan.
- Run `git status --short` before editing.
- Write or update the failing test first.
- Run the focused test and confirm the expected red failure.
- Implement the smallest production change that satisfies the test.
- Run the focused test again.
- Run `git diff --check`.
- Commit only the files listed in that task.
- If `xcodebuild test` hangs before XCTest output, stop it, record the exact command and symptom, then run `build-for-testing` only as compile evidence.

Focused test command template:

```bash
xcodebuild test \
  -project VVTerm.xcodeproj \
  -scheme VVTerm \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -skip-testing:VVTermUITests \
  -only-testing:VVTermTests/<TestClass> \
  ENABLE_DEBUG_DYLIB=NO
```

Compile fallback:

```bash
xcodebuild build-for-testing \
  -project VVTerm.xcodeproj \
  -scheme VVTerm \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -skip-testing:VVTermUITests \
  ENABLE_DEBUG_DYLIB=NO
```

## Shared Test Support

Create shared async test helpers when the first task needs them, preferably in `VVTermTests/TestSupport/AsyncTestHelpers.swift`. If the target does not currently include a `TestSupport` group, add the file to `VVTermTests` and keep the declarations `internal`.

Use this exact helper code for cancellation and throwing assertions:

```swift
import XCTest

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected error, got success" : message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

actor AsyncProbe {
    private var isMarked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        isMarked = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if isMarked {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

actor AsyncFlag {
    private var storage = false

    var value: Bool {
        storage
    }

    func setTrue() {
        storage = true
    }
}
```

Task-local fakes must be defined in the test file that first uses them:

- `TerminalConnectionRunnerProbe` in `VVTermTests/Features/TerminalSessions/TerminalConnectionRunnerTests.swift`
- `RecordingTerminalSSHClient` in `VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift`
- `RecordingLibSSH2SessionDriver` in `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
- `FakeRemoteCommandExecutor` and `InMemoryKnownHostsStore` in the tmux, mosh, and known-host tests that introduce the corresponding protocols

Use this fake client for runtime ordering tests:

```swift
actor RecordingTerminalSSHClientStorage {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

final class RecordingTerminalSSHClient: FakeTerminalSSHClient {
    private let storage = RecordingTerminalSSHClientStorage()
    private let shellId = UUID()

    var events: [String] {
        get async { await storage.events }
    }

    func connect() async throws {
        await storage.append("connect")
    }

    func startShell() async throws -> UUID {
        await storage.append("startShell")
        return shellId
    }

    func closeShell(_ shellId: UUID) async {
        await storage.append("closeShell")
    }

    func disconnect() async {
        await storage.append("disconnect")
    }
}
```

---

## Task 1: Reject Late Shell Registration

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/SSHShellRegistry.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalConnectionRegistryTests.swift`
- Test: `VVTermTests/ConnectionSessionManagerOpenTests.swift`

**Interfaces:**
- Produces:
  - `struct SSHShellRegistry.Generation: Hashable, Sendable`
  - `mutating func beginStart(for entityId: UUID, serverId: UUID, client: SSHClient, now: Date) -> StartResult`
  - `mutating func closeEntity(_ entityId: UUID) -> CloseResult`
  - `mutating func register(..., generation: Generation) -> RegisterResult`
  - `RegisterResult.rejectedShellToClose: (client: SSHClient, shellId: UUID)?`
- Consumes:
  - Existing `SSHShellRegistry.register`, `tryBeginStart`, `finishStart`, and `unregister`.

- [x] **Step 1: Write failing tests for closed entity registration**

Add this test class:

```swift
import XCTest
@testable import VVTerm

final class TerminalConnectionRegistryTests: XCTestCase {
    func testClosedSessionRejectsLateShellRegistration() {
        var registry = SSHShellRegistry(staleThreshold: 120)
        let entityId = UUID()
        let serverId = UUID()
        let oldClient = SSHClient()
        let oldStart = registry.tryBeginStart(for: entityId, serverId: serverId, client: oldClient)

        _ = registry.unregister(for: entityId)

        let result = registry.register(
            client: oldClient,
            shellId: UUID(),
            for: entityId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil,
            generation: oldStart.generation
        )

        XCTAssertFalse(result.accepted)
        XCTAssertNotNil(result.rejectedShellToClose)
        XCTAssertNil(registry.client(for: entityId))
    }

    func testOlderGenerationCannotReplaceNewerShell() {
        var registry = SSHShellRegistry(staleThreshold: 120)
        let entityId = UUID()
        let serverId = UUID()
        let oldClient = SSHClient()
        let newClient = SSHClient()
        let oldStart = registry.tryBeginStart(for: entityId, serverId: serverId, client: oldClient)

        _ = registry.closeEntity(entityId)
        let newStart = registry.tryBeginStart(for: entityId, serverId: serverId, client: newClient)
        let newShellId = UUID()
        let accepted = registry.register(
            client: newClient,
            shellId: newShellId,
            for: entityId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil,
            generation: newStart.generation
        )

        let rejected = registry.register(
            client: oldClient,
            shellId: UUID(),
            for: entityId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil,
            generation: oldStart.generation
        )

        XCTAssertTrue(accepted.accepted)
        XCTAssertFalse(rejected.accepted)
        XCTAssert(registry.client(for: entityId) === newClient)
        XCTAssertEqual(registry.shellId(for: entityId), newShellId)
    }
}
```

- [x] **Step 2: Run red test**

Run:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalConnectionRegistryTests ENABLE_DEBUG_DYLIB=NO
```

Expected: fail to compile because `generation`, `closeEntity`, and `rejectedShellToClose` do not exist.

- [x] **Step 3: Implement generation guard**

Update `SSHShellRegistry` with generation values stored per entity. `closeEntity` increments the generation and removes registration/start. `tryBeginStart` returns the current generation. `register` accepts only the current generation and only when a start exists for the same client.

Minimum API shape:

```swift
struct Generation: Hashable, Sendable {
    fileprivate let rawValue: UInt64
}

struct RegisterResult: Sendable {
    let accepted: Bool
    let staleIncomingShell: (client: SSHClient, shellId: UUID)?
    let replacedShell: (client: SSHClient, shellId: UUID)?
    let rejectedShellToClose: (client: SSHClient, shellId: UUID)?
}

struct StartResult: Sendable {
    let started: Bool
    let staleContext: StartContext?
    let generation: Generation
}
```

- [x] **Step 4: Thread generation through managers**

Add generation arguments to `ConnectionSessionManager.registerSSHClient` and `TerminalTabManager.registerSSHClient`. Store generation returned from `tryBeginShellStart` in the caller until shell registration. In this task, keep existing `SSHConnectionRunner` placement unchanged.

- [x] **Step 5: Run green test**

Run the same focused command. Expected: `TerminalConnectionRegistryTests` passes.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/SSHShellRegistry.swift \
  VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift \
  VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift \
  VVTermTests/Features/TerminalSessions/TerminalConnectionRegistryTests.swift \
  VVTermTests/ConnectionSessionManagerOpenTests.swift
git commit -m "fix: reject stale terminal shell registrations"
```

## Task 2: Make Session and Pane Close Awaitable

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabComponents.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift`
- Test: `VVTermTests/ConnectionSessionManagerOpenTests.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `func closeSessionAndWait(_ session: ConnectionSession, notingSessionEnd: Bool) async`
  - `func closePaneAndWait(_ paneId: UUID) async`
  - `func disconnectServerAndWait(_ serverId: UUID) async` on both managers, with shared semantics.
- Consumes:
  - Task 1 generation guard and existing `unregisterSSHClient`.

- [x] **Step 1: Write failing tests**

Add tests:

```swift
@MainActor
func testCloseSessionAndWaitWaitsForShellTeardownAndUnregister() async {
    let manager = ConnectionSessionManager.shared
    await manager.resetForTesting()
    let serverId = UUID()
    let session = ConnectionSession(serverId: serverId, title: "Tencent", connectionState: .connected)
    let client = SSHClient()
    manager.sessions = [session]
    manager.registerSSHClient(client, shellId: UUID(), for: session.id, serverId: serverId, skipTmuxLifecycle: true)

    var teardownFinished = false
    manager.registerShellCancelHandler({ _ in
        try? await Task.sleep(for: .milliseconds(50))
        teardownFinished = true
    }, for: session.id)

    await manager.closeSessionAndWait(session, notingSessionEnd: false)

    XCTAssertTrue(teardownFinished)
    XCTAssertNil(manager.sshClient(forSessionId: session.id))
    XCTAssertFalse(manager.sessions.contains { $0.id == session.id })
}
```

Add pane equivalent to `ConnectionLifecycleIntegrationTests` using `TerminalTabManager.shared`.

- [x] **Step 2: Run red tests**

Run:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionSessionManagerOpenTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
```

Expected: fail to compile because `closeSessionAndWait` and `closePaneAndWait` do not exist.

- [x] **Step 3: Implement awaitable close APIs**

Keep existing synchronous `closeSession` as a UI intent wrapper:

```swift
func closeSession(_ session: ConnectionSession, notingSessionEnd: Bool = true) {
    Task { @MainActor in
        await closeSessionAndWait(session, notingSessionEnd: notingSessionEnd)
    }
}
```

Move current close body into `closeSessionAndWait` and await unregister plus shell teardown before returning. Mirror this pattern in `TerminalTabManager`.

- [x] **Step 4: Replace UI close call sites that can await**

For UI button handlers that are sync, call the wrapper. For async flows like disconnect, call `await closeSessionAndWait` or `await disconnectServerAndWait`.

- [x] **Step 5: Run green tests**

Run the focused command from Step 2. Expected: tests pass.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift \
  VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift \
  VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabComponents.swift \
  VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift \
  VVTermTests/ConnectionSessionManagerOpenTests.swift \
  VVTermTests/ConnectionLifecycleIntegrationTests.swift
git commit -m "fix: make terminal close teardown awaitable"
```

## Task 3: Extract TerminalConnectionRunner from UI

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalConnectionRunnerTests.swift`

**Interfaces:**
- Produces:
  - `struct TerminalConnectionRunner`
  - `struct TerminalConnectionCallbacks`
  - `func run(configuration: TerminalConnectionConfiguration, callbacks: TerminalConnectionCallbacks) async`
- Consumes:
  - Existing `SSHConnectionRunner.run` behavior.

- [x] **Step 1: Write failing tests**

Create a runner test with fake callbacks that verify non-retryable auth failures are not retried:

```swift
final class TerminalConnectionRunnerTests: XCTestCase {
    func testNonRetryableAuthenticationFailureDoesNotRetry() async {
        let probe = TerminalConnectionRunnerProbe(errors: [SSHError.authenticationFailed])
        await TerminalConnectionRunner.runForTesting(probe: probe)
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)
        let finalState = await probe.finalState
        XCTAssertEqual(finalState, .failed("Authentication failed"))
    }
}
```

- [x] **Step 2: Run red test**

Run:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalConnectionRunnerTests ENABLE_DEBUG_DYLIB=NO
```

Expected: fail to compile because the runner file and testing probe do not exist.

- [x] **Step 3: Move runner unchanged**

Move `SSHConnectionRunner` from `SSHTerminalWrapper.swift` to `TerminalConnectionRunner.swift`. Rename it to `TerminalConnectionRunner`. Keep behavior identical except for names.

- [x] **Step 4: Update UI imports/usages**

Replace `SSHConnectionRunner.run` with `TerminalConnectionRunner.run` in tab and pane code.

- [x] **Step 5: Run green tests and compile**

Run the focused runner test. Then run:

```bash
xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift \
  VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift \
  VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift \
  VVTermTests/Features/TerminalSessions/TerminalConnectionRunnerTests.swift
git commit -m "refactor: move terminal connection runner to application layer"
```

## Task 4: Introduce Terminal Entity State

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Domain/TerminalEntityID.swift`
- Create: `VVTerm/Features/TerminalSessions/Domain/TerminalEntityConnectionState.swift`
- Modify: `VVTerm/Features/TerminalSessions/Domain/ConnectionSession.swift`
- Modify: `VVTerm/Features/TerminalSessions/Domain/TerminalTab.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalEntityStateTests.swift`

**Interfaces:**
- Produces:
  - `enum TerminalEntityID: Hashable, Sendable`
  - `enum TerminalEntityConnectionState: Hashable, Sendable`
  - states: `.idle`, `.connecting`, `.authenticating`, `.verifyingHostKey`, `.startingShell`, `.streaming`, `.closing`, `.suspended`, `.disconnected`, `.failed(String)`
  - computed properties `isOpening`, `isConnected`, `isClosing`, `isTerminalReusable`
- Consumes:
  - Existing `ConnectionState`.

- [x] **Step 1: Write failing tests**

```swift
final class TerminalEntityStateTests: XCTestCase {
    func testClosingIsNotReusableOrConnected() {
        let state = TerminalEntityConnectionState.closing
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.isClosing)
        XCTAssertFalse(state.isTerminalReusable)
    }

    func testStreamingIsConnectedAndReusable() {
        let state = TerminalEntityConnectionState.streaming
        XCTAssertTrue(state.isConnected)
        XCTAssertFalse(state.isClosing)
        XCTAssertTrue(state.isTerminalReusable)
    }
}
```

- [x] **Step 2: Run red test**

Expected: compile failure because the new types do not exist.

- [x] **Step 3: Add new domain types**

Add exact state enum and mapping helpers:

```swift
extension TerminalEntityConnectionState {
    init(connectionState: ConnectionState) {
        switch connectionState {
        case .connecting: self = .connecting
        case .reconnecting: self = .connecting
        case .connected: self = .streaming
        case .disconnected, .idle: self = .disconnected
        case .failed(let message): self = .failed(message)
        }
    }
}
```

- [x] **Step 4: Keep compatibility**

Do not remove `ConnectionState` in this task. Add bridging only. Existing UI behavior must remain unchanged.

- [x] **Step 5: Run tests**

Run `TerminalEntityStateTests`, `ConnectionSessionDomainTests`, and `TerminalSplitNodeTests`.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Domain/TerminalEntityID.swift \
  VVTerm/Features/TerminalSessions/Domain/TerminalEntityConnectionState.swift \
  VVTerm/Features/TerminalSessions/Domain/ConnectionSession.swift \
  VVTerm/Features/TerminalSessions/Domain/TerminalTab.swift \
  VVTermTests/Features/TerminalSessions/TerminalEntityStateTests.swift
git commit -m "refactor: add explicit terminal entity state"
```

## Task 5: Add TerminalConnectionRuntime Actor

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRuntime.swift`
- Create: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRegistry.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift`

**Interfaces:**
- Produces:
  - `actor TerminalConnectionRuntime`
  - `@MainActor final class TerminalConnectionRegistry`
  - `func open(configuration: TerminalConnectionConfiguration) async`
  - `func close(mode: ShellTeardownMode) async`
  - `func suspend() async`
  - `func send(_ data: Data) async throws`
  - `func resize(cols: Int, rows: Int) async throws`
- Consumes:
  - `TerminalEntityID`, `TerminalEntityConnectionState`, `TerminalConnectionRunner`.

- [x] **Step 1: Write fake SSH protocol and tests**

Define testing-only protocol in the test file:

```swift
protocol FakeTerminalSSHClient: AnyObject {
    var events: [String] { get async }
    func connect() async throws
    func startShell() async throws -> UUID
    func closeShell(_ shellId: UUID) async
    func disconnect() async
}
```

Test:

```swift
func testCloseWaitsForShellCloseAndDisconnect() async {
    let fake = RecordingTerminalSSHClient()
    let runtime = TerminalConnectionRuntime(entityId: .session(UUID()), clientFactory: { fake })

    await runtime.open(configuration: .testing)
    await runtime.close(mode: .fullDisconnect)

    let events = await fake.events
    XCTAssertEqual(events, ["connect", "startShell", "closeShell", "disconnect"])
}
```

- [x] **Step 2: Run red test**

Expected: compile failure because runtime and testing configuration do not exist.

- [x] **Step 3: Implement runtime with injected client**

The runtime owns a single client instance and tracks `connectTask`, `shellId`, and `state`. `close(mode:)` cancels connect, closes shell if present, disconnects when requested, and only returns after cleanup.

- [x] **Step 4: Implement registry**

`TerminalConnectionRegistry` stores `[TerminalEntityID: TerminalConnectionRuntime]`, maps server IDs to entity IDs, and exposes `waitForServerTeardown(_:)`.

- [x] **Step 5: Run focused tests**

Run `TerminalConnectionRuntimeTests` and `TerminalConnectionRegistryTests`.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TerminalConnectionRuntime.swift \
  VVTerm/Features/TerminalSessions/Application/TerminalConnectionRegistry.swift \
  VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift
git commit -m "refactor: add terminal connection runtime owner"
```

## Task 6: Move Tab SSH Ownership Out of Coordinators

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift`
- Test: `VVTermTests/ConnectionSessionManagerOpenTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift`

**Interfaces:**
- Produces:
  - `func attachSurface(_ terminal: GhosttyTerminalView, to sessionId: UUID) async`
  - `func detachSurface(from sessionId: UUID, reason: TerminalSurfaceDetachReason) async`
  - `func sendInput(_ data: Data, to sessionId: UUID) async`
  - `func resizeSession(_ sessionId: UUID, cols: Int, rows: Int) async`
- Consumes:
  - Task 5 runtime registry.

- [x] **Step 1: Write failing test**

Add a test that no `SSHClient` is created by coordinator by injecting a runtime factory into `ConnectionSessionManager` and asserting `attachSurface` starts the runtime.

- [x] **Step 2: Run red test**

Expected: compile failure for missing attach/send/resize API.

- [x] **Step 3: Change `SSHTerminalWrapper.Coordinator`**

Remove `let sshClient: SSHClient`, `var shellTask`, and `var shellId` from both macOS and iOS coordinators. `sendToSSH`, resize callbacks, and onReady call manager APIs only.

- [x] **Step 4: Move rich paste client resolution**

`TerminalRichPasteSupport` resolves a `RemoteConnectionLease` or command executor from the manager, not the coordinator's client.

- [x] **Step 5: Run tests and compile**

Run `ConnectionSessionManagerOpenTests`, `TerminalConnectionRuntimeTests`, and `build-for-testing`.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift \
  VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift \
  VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift \
  VVTermTests/ConnectionSessionManagerOpenTests.swift \
  VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift
git commit -m "refactor: move tab SSH ownership to runtime"
```

## Task 7: Move Split Pane SSH Ownership Out of Coordinators

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift`

**Interfaces:**
- Produces:
  - `func attachSurface(_ terminal: GhosttyTerminalView, toPane paneId: UUID) async`
  - `func detachSurface(fromPane paneId: UUID, reason: TerminalSurfaceDetachReason) async`
  - `func sendInput(_ data: Data, toPane paneId: UUID) async`
  - `func resizePane(_ paneId: UUID, cols: Int, rows: Int) async`
- Consumes:
  - Shared runtime registry from Task 5.

- [x] **Step 1: Write failing tests**

Add tests that closing a pane waits for runtime close and that late pane shell registration is rejected after close.

- [x] **Step 2: Run red tests**

Expected: compile failure or failing assertions because pane close is not awaitable yet.

- [x] **Step 3: Remove pane coordinator SSH ownership**

Remove `SSHClient`, `shellTask`, and `shellId` from `SSHTerminalPaneWrapper.Coordinator`. Replace `Task.detached` close paths with `await TerminalTabManager.shared.closePaneAndWait(paneId)`.

- [x] **Step 4: Use same runtime APIs as tabs**

Panes and tabs use `TerminalEntityID` to address runtime. Keep pane-specific layout state in `TerminalTabManager`.

- [x] **Step 5: Run focused tests**

Run `ConnectionLifecycleIntegrationTests` and `TerminalConnectionRuntimeTests`.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift \
  VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift \
  VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift \
  VVTermTests/ConnectionLifecycleIntegrationTests.swift \
  VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift
git commit -m "refactor: move pane SSH ownership to runtime"
```

## Task 8: Extract Terminal Surface Registry

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Application/TerminalSurfaceRegistry.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/TerminalSurfaceTeardownTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class TerminalSurfaceRegistry`
  - `func register(_ surface: GhosttyTerminalView, for entityId: TerminalEntityID)`
  - `func detachSurface(for entityId: TerminalEntityID, cleanup: Bool)`
  - `func surface(for entityId: TerminalEntityID) -> GhosttyTerminalView?`
- Consumes:
  - Existing terminal view dictionaries in managers.

- [x] **Step 1: Write failing surface tests**

Add tests proving surface detach does not close SSH runtime by itself and repeated cleanup is idempotent.

- [x] **Step 2: Run red test**

Expected: fail because `TerminalSurfaceRegistry` does not exist.

- [x] **Step 3: Move terminal view storage**

Move `terminalViews`, access order, browse/find state callbacks, and cleanup into `TerminalSurfaceRegistry`. Managers keep state and intent methods only.

- [x] **Step 4: Keep SwiftUI lifecycle surface-only**

`dismantleUIView`, `dismantleNSView`, and coordinator `deinit` can detach or pause surfaces, but they must not close SSH. Closing SSH happens through explicit app-layer close intent.

- [x] **Step 5: Run tests**

Run `TerminalSurfaceTeardownTests`, `ConnectionSessionManagerOpenTests`, and `ConnectionLifecycleIntegrationTests`.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TerminalSurfaceRegistry.swift \
  VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift \
  VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift \
  VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift \
  VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift \
  VVTermTests/TerminalSurfaceTeardownTests.swift
git commit -m "refactor: separate terminal surface lifecycle"
```

## Task 9: Make Authentication Gate Cancellation-Aware

**Files:**
- Modify: `VVTerm/Core/SSH/SSHAuthenticationGate.swift`
- Test: `VVTermTests/SSHAuthenticationGateTests.swift`
- Test: `VVTermTests/Core/SSH/SSHAuthenticationGateCancellationTests.swift`

**Interfaces:**
- Produces:
  - `func withExclusiveAccess<T>(for key: String, operation: @Sendable () async throws -> T) async throws -> T`
  - Cancellation removes the waiter and throws `CancellationError`.
- Consumes:
  - Existing `SSHAuthenticationGate`.

- [x] **Step 1: Write failing cancellation tests**

```swift
final class SSHAuthenticationGateCancellationTests: XCTestCase {
    func testCancelledWaiterDoesNotRunOperation() async {
        let gate = SSHAuthenticationGate()
        let holderStarted = AsyncProbe()
        let releaseHolder = AsyncGate()
        let ranCancelledOperation = AsyncFlag()

        let holder = Task {
            try await gate.withExclusiveAccess(for: "server:user") {
                await holderStarted.mark()
                await releaseHolder.wait()
            }
        }
        await holderStarted.wait()

        let waiter = Task {
            try await gate.withExclusiveAccess(for: "server:user") {
                await ranCancelledOperation.setTrue()
            }
        }
        waiter.cancel()
        await releaseHolder.open()
        _ = try? await holder.value
        _ = try? await waiter.value

        XCTAssertFalse(await ranCancelledOperation.value)
    }
}
```

- [x] **Step 2: Run red tests**

Expected: failing assertion because canceled waiter can remain queued.

- [x] **Step 3: Implement cancellable waiter IDs**

Store waiters by UUID per key. Use `withTaskCancellationHandler` to remove a canceled waiter. Resume only live waiters.

- [x] **Step 4: Preserve existing behavior**

Run existing overlap tests to prove same-key serialization and different-key parallelism remain.

- [x] **Step 5: Commit**

```bash
git add VVTerm/Core/SSH/SSHAuthenticationGate.swift \
  VVTermTests/SSHAuthenticationGateTests.swift \
  VVTermTests/Core/SSH/SSHAuthenticationGateCancellationTests.swift
git commit -m "fix: make SSH auth gate cancellation-aware"
```

## Task 10: Add Testable libssh2 Session Boundary

**Files:**
- Create: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
- Test: `VVTermTests/SSHErrorRetryableTests.swift`

**Interfaces:**
- Produces:
  - `protocol LibSSH2SessionDriving`
  - `struct LibSSH2RawError: Error, Equatable`
  - `struct LibSSH2SessionDriver: LibSSH2SessionDriving`
  - driver methods for init, handshake, auth, channel open, SFTP, disconnect, free.
- Consumes:
  - Existing direct libssh2 calls in `SSHSession`.

- [x] **Step 1: Write failing fd cleanup test**

```swift
func testSessionInitFailureClosesSocketExactlyOnce() async {
    let fake = RecordingLibSSH2SessionDriver(sessionInitResult: .failure(-1))
    let session = SSHSession(config: .testing, driver: fake)

    await XCTAssertThrowsErrorAsync(try await session.connect())

    let closeCount = await fake.closeCount(for: .configuredSocket)
    XCTAssertEqual(closeCount, 1)
}
```

- [x] **Step 2: Run red test**

Expected: compile failure because driver injection does not exist.

- [x] **Step 3: Introduce driver without broad behavior change**

Move C calls behind driver methods. Preserve current behavior first. Then fix double-close by ensuring fd ownership transfers to exactly one cleanup path.

- [x] **Step 4: Add raw error mapping tests**

Inject handshake/auth/channel/SFTP raw codes and assert internal errors preserve operation, raw code, and last message.

- [x] **Step 5: Run focused tests**

Run `LibSSH2SessionLifecycleTests` and `SSHErrorRetryableTests`.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Core/SSH/LibSSH2SessionDriver.swift \
  VVTerm/Core/SSH/SSHClient.swift \
  VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift \
  VVTermTests/SSHErrorRetryableTests.swift
git commit -m "refactor: add testable libssh2 session boundary"
```

## Task 11: Make Blocking SSH Operations Abortable

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Modify: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`

**Interfaces:**
- Produces:
  - `func runWithTimeout(_:operation:onTimeout:) async throws`
  - `SSHSession.abort()` is invoked when connect/auth/startShell timeout occurs.
- Consumes:
  - Driver from Task 10.

- [x] **Step 1: Write failing timeout abort test**

Test that a fake blocking handshake receives abort when timeout fires.

- [x] **Step 2: Run red test**

Expected: abort count is zero.

- [x] **Step 3: Add timeout abort hook**

Change timeout wrapper so timeout calls `pendingSession.abort()` or driver socket abort before throwing `.timeout`.

- [x] **Step 4: Remove unsafe shared flag where possible**

Replace `_isAborted` and `_sessionForAbort` with a small synchronized abort state object. Keep nonisolated `abort()` only as a narrow fd-close path.

- [x] **Step 5: Run tests**

Run `LibSSH2SessionLifecycleTests` and `build-for-testing`.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Core/SSH/SSHClient.swift \
  VVTerm/Core/SSH/LibSSH2SessionDriver.swift \
  VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift
git commit -m "fix: abort SSH session on blocking timeouts"
```

## Task 12: Preserve Tmux, Mosh, and Known-Host Error Semantics

**Files:**
- Create: `VVTerm/Core/SSH/RemoteCommandExecuting.swift`
- Modify: `VVTerm/Core/SSH/RemoteTmuxManager.swift`
- Modify: `VVTerm/Core/SSH/RemoteMoshManager.swift`
- Modify: `VVTerm/Core/SSH/KnownHostsManager.swift`
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Test: `VVTermTests/RemoteTmuxManagerParserTests.swift`
- Test: `VVTermTests/RemoteMoshManagerTests.swift`
- Test: `VVTermTests/KnownHostsManagerTests.swift`

**Interfaces:**
- Produces:
  - `protocol RemoteCommandExecuting`
  - `enum RemoteCommandFailure: Error`
  - `actor KnownHostsStore`
  - `enum KnownHostVerificationResult`
- Consumes:
  - Existing tmux/mosh/known-host logic.

- [x] **Step 1: Write failing tests**

Add tests:

```swift
func testTmuxCancellationPropagatesInsteadOfBecomingUnavailable() async {
    let executor = FakeRemoteCommandExecutor(result: .failure(CancellationError()))
    await XCTAssertThrowsErrorAsync(try await RemoteTmuxManager.shared.availableBackend(using: executor, preferred: .tmux)) { error in
        XCTAssertTrue(error is CancellationError)
    }
}

func testNewHostDoesNotSaveUntilPolicyApproves() async throws {
    let store = InMemoryKnownHostsStore()
    let verifier = KnownHostVerificationService(store: store)
    let result = try await verifier.verify(host: "example.com", port: 22, key: Data([1, 2, 3]))
    guard case .newHost(let fingerprint) = result else {
        XCTFail("Expected new-host verification result")
        return
    }
    XCTAssertFalse(fingerprint.isEmpty)
    XCTAssertNil(await store.knownKey(host: "example.com", port: 22))
}
```

- [x] **Step 2: Run red tests**

Expected: cancellation is swallowed or new host auto-save behavior fails the test.

- [x] **Step 3: Introduce command executor**

Move tmux/mosh helper dependencies from raw `SSHClient` to `RemoteCommandExecuting` while keeping call sites bridged through `SSHClient`.

- [x] **Step 4: Introduce known-host service boundary**

Low-level `SSHSession` obtains a verification result and returns a typed error or requires policy callback before saving.

- [x] **Step 5: Run tests**

Run tmux, mosh, known-host, and SSH retryability tests.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Core/SSH/RemoteCommandExecuting.swift \
  VVTerm/Core/SSH/RemoteTmuxManager.swift \
  VVTerm/Core/SSH/RemoteMoshManager.swift \
  VVTerm/Core/SSH/KnownHostsManager.swift \
  VVTerm/Core/SSH/SSHClient.swift \
  VVTermTests/RemoteTmuxManagerParserTests.swift \
  VVTermTests/RemoteMoshManagerTests.swift \
  VVTermTests/KnownHostsManagerTests.swift
git commit -m "refactor: preserve remote command failure semantics"
```

## Task 13: Add RemoteConnectionLease for Cross-Feature Use

**Files:**
- Create: `VVTerm/Core/SSH/RemoteConnectionLease.swift`
- Modify: `VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift`
- Modify: `VVTerm/Features/Stats/Application/ServerStatsCollector.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift`
- Test: `VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift`
- Test: `VVTermTests/Features/Stats/ServerStatsDomainTests.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `struct RemoteConnectionLease`
  - `enum RemoteConnectionLeaseOwnership { case borrowed, owned }`
  - `func close() async`
  - `var commandExecutor: any RemoteCommandExecuting`
- Consumes:
  - Runtime registry from TerminalSessions and existing owned clients.

- [x] **Step 1: Write failing lease tests**

Test borrowed leases do not disconnect the underlying client on close, while owned leases do.

- [x] **Step 2: Run red tests**

Expected: compile failure because lease type does not exist.

- [x] **Step 3: Implement lease**

Lease owns close semantics. RemoteFiles and Stats no longer decide raw client disconnect with untracked `Task.detached`.

- [x] **Step 4: Update feature adapters**

`SSHSFTPAdapter.disconnect(serverId:)` becomes async or returns a tracked task. `ServerStatsCollector.stopCollecting()` awaits or stores owned lease close.

- [x] **Step 5: Run tests**

Run RemoteFiles, Stats, and lifecycle tests listed above.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Core/SSH/RemoteConnectionLease.swift \
  VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift \
  VVTerm/Features/Stats/Application/ServerStatsCollector.swift \
  VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift \
  VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift \
  VVTermTests/Features/Stats/ServerStatsDomainTests.swift \
  VVTermTests/ConnectionLifecycleIntegrationTests.swift
git commit -m "refactor: use remote connection leases across features"
```

## Task 14: Remove Duplicated Runtime Sources of Truth

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalAutoReconnectPolicy.swift`
- Modify: `VVTerm/Features/TerminalSessions/Domain/ConnectionSession.swift`
- Modify: `VVTerm/Features/TerminalSessions/Domain/TerminalTab.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/Features/TerminalSessions/ConnectionSessionDomainTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalSplitNodeTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalAutoReconnectPolicyTests.swift`
- Test: `VVTermTests/ConnectionSessionManagerOpenTests.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`

**Interfaces:**
- Produces:
  - One live transport/runtime truth source via `TerminalConnectionRegistry`.
  - Session and pane domain models may retain `ConnectionState` only as a user-facing display snapshot.
  - Persisted snapshots omit runtime state; restored sessions/panes reopen as disconnected display snapshots until an application-owned runtime starts.
  - `openServerIds` represents open workspace UI state; `activeServerIds`/`hasLiveRuntime` represent opening or streaming transport state.
- Consumes:
  - `TerminalEntityConnectionState`.
  - `TerminalAutoReconnectPolicy`, `TerminalManualReconnectPolicy`, and `TerminalConnectWatchdogAction`.

- [x] **Step 1: Write failing consistency tests**

Add tests that restored disconnected sessions do not make `connectedServerIds` contain the server until a runtime reaches `.streaming`.

- [x] **Step 2: Run red tests**

Expected: current restore/open semantics mark server connected too early.

- [x] **Step 3: Move runtime fields out of persisted snapshots and lifecycle decisions**

Keep persisted session/tab metadata: ids, server ids, title, working directory, tmux preference, presentation overrides. Do not persist runtime state. `ConnectionState` remains in session/pane values only as a display snapshot; lifecycle decisions derive from `TerminalConnectionRegistry`, `hasLiveRuntime`, and manager-owned shell registries.

- [x] **Step 4: Reconcile connected-server semantics**

Define:

```swift
var activeServerIds: Set<UUID> { runtimes.streamingServerIds }
var openServerIds: Set<UUID> { sessions.map(\.serverId) union tabsByServer.keys }
```

Use `openServerIds` for navigation history and `activeServerIds` for live transport indicators.

- [x] **Step 5: Run tests**

Run domain and lifecycle tests.

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift \
  VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift \
  VVTerm/Features/TerminalSessions/Domain/ConnectionSession.swift \
  VVTerm/Features/TerminalSessions/Domain/TerminalTab.swift \
  VVTermTests/Features/TerminalSessions/ConnectionSessionDomainTests.swift \
  VVTermTests/Features/TerminalSessions/TerminalSplitNodeTests.swift \
  VVTermTests/ConnectionLifecycleIntegrationTests.swift
git commit -m "refactor: unify terminal runtime state"
```

Actual commits were split into smaller reviewable slices:

- `ca53908 refactor: expose pane runtime liveness from registry`
- `875f5e4 refactor: gate auto reconnect on live runtime`
- `cf25ffe refactor: route pane reconnect through tab manager`
- `9c252d6 refactor: handle pane exit in tab manager`
- `f0f4133 refactor: gate manual retry on runtime liveness`
- `d8a191e refactor: handle connect watchdog in managers`

Task 14 verification:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,id=6B08CBD5-A6F2-402D-B431-780A0F292BCD' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,id=6B08CBD5-A6F2-402D-B431-780A0F292BCD' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalAutoReconnectPolicyTests -only-testing:VVTermTests/TerminalManualReconnectPolicyTests ENABLE_DEBUG_DYLIB=NO
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,id=6B08CBD5-A6F2-402D-B431-780A0F292BCD' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionSessionDomainTests -only-testing:VVTermTests/TerminalSplitNodeTests -only-testing:VVTermTests/ConnectionSessionManagerOpenTests ENABLE_DEBUG_DYLIB=NO
git diff --check
xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,id=6B08CBD5-A6F2-402D-B431-780A0F292BCD' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

## Task 15: Final Lifecycle Sweep

**Files:**
- Modify only files found by the audit commands below.
- Test: focused tests for every modified feature.

**Interfaces:**
- Produces:
  - No lifecycle-critical `Task.detached` without stored/awaited task.
  - No `SSHClient()` in SwiftUI representable coordinators.
  - No business close/disconnect in `dismantleUIView`, `dismantleNSView`, or coordinator `deinit`.

- [x] **Step 1: Run audit commands**

```bash
rg -n "SSHClient\\(" VVTerm/Features VVTerm/App -g '*.swift'
rg -n "Task\\.detached|Task \\{" VVTerm/Features VVTerm/Core VVTerm/App -g '*.swift'
rg -n "deinit|dismantleUIView|dismantleNSView" VVTerm/Features VVTerm/Core VVTerm/App -g '*.swift'
```

- [x] **Step 2: Classify every hit**

Write classifications into this file under "Progress Ledger". Each lifecycle-critical hit must be tied to a tracked task, awaited operation, or explicit exemption.

- [x] **Step 3: Add regression tests for remaining high-risk hits**

For every non-exempt lifecycle-critical hit, add a focused test before changing production code.

- [x] **Step 4: Remove or track remaining work**

Replace untracked task work with awaited operations, stored tasks, or application-layer lifecycle APIs.

- [x] **Step 5: Run final focused suite**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionSessionManagerOpenTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests -only-testing:VVTermTests/SSHAuthenticationGateTests ENABLE_DEBUG_DYLIB=NO
```

Then run:

```bash
xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 6: Commit**

```bash
git add docs/refactor-swift-best-practice.md VVTerm VVTermTests
git commit -m "refactor: complete Swift lifecycle cleanup"
```

## Task 16: Core Remote Connection Lease Gate

**Files:**
- Modify: `VVTerm/Core/SSH/RemoteConnectionLease.swift`
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Test: `VVTermTests/Core/SSH/RemoteConnectionLeaseTests.swift`

**Interfaces:**
- Produces:
  - `RemoteConnectionLease.withExclusiveClient<T>(_ operation: @Sendable (any RemoteConnectionLeaseClient) async throws -> T) async throws -> T`
  - `RemoteConnectionLease.close()` waits for any in-flight exclusive operation before disconnecting an owned client.
  - Concurrent `close()` calls on one lease still disconnect at most once.
- Consumes:
  - Existing `RemoteConnectionLeaseClient.disconnect()`.
  - Existing `SSHConnectionOperationService.runWithConnection(...)`.

- [x] **Step 1: Add RED lease-ordering tests**

Add these tests to `RemoteConnectionLeaseTests`:

```swift
@Test
func ownedLeaseConcurrentCloseDisconnectsClientOnce() async

@Test
func exclusiveOperationsForSameLeaseDoNotOverlap() async throws

@Test
func closeWaitsForExclusiveOperationBeforeDisconnectingOwnedClient() async throws
```

Expected first RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteConnectionLeaseTests ENABLE_DEBUG_DYLIB=NO
```

Expected failure: `RemoteConnectionLease` has no `withExclusiveClient` API, and close does not prove it waits behind an in-flight operation.

- [x] **Step 2: Implement per-lease operation serialization**

Keep the gate in the lease state actor. Do not add locks or global queues. `withExclusiveClient` must serialize operations on the same lease and must check cancellation before starting the protected operation.

- [x] **Step 3: Make close wait for the gate**

`close()` must mark the lease as closing, wait for the exclusive operation gate to drain, and then disconnect only when `ownership == .owned`. Borrowed close remains a no-op after the drain.

- [x] **Step 4: Run focused tests and diff check**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteConnectionLeaseTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 5: Commit**

```bash
git add VVTerm/Core/SSH/RemoteConnectionLease.swift VVTerm/Core/SSH/SSHClient.swift VVTermTests/Core/SSH/RemoteConnectionLeaseTests.swift
git commit -m "refactor: serialize remote connection lease operations"
```

- [x] **Step 6: API/boundary cleanup**

Before starting Task 17, review whether `withExclusiveClient` names its side effect clearly, whether the lease still exposes only the minimum mutable state, and whether the tests explain borrowed vs owned fake assumptions. Record the result in the Progress Ledger and commit it with Task 16 if not already included.

## Task 17: RemoteFiles Lease-Owned SFTP Boundary

**Files:**
- Create: `VVTerm/Features/RemoteFiles/Infrastructure/SFTPRemoteFileClient.swift`
- Modify: `VVTerm/Features/RemoteFiles/Infrastructure/SFTPRemoteFileService.swift`
- Modify: `VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift`
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift` only if disconnect task plumbing needs tightening.
- Test: `VVTermTests/Features/RemoteFiles/SSHSFTPAdapterTests.swift`
- Test: `VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift` only for returned disconnect task coverage or Test Context cleanup.

**Interfaces:**
- Produces:
  - `protocol SFTPRemoteFileClient: RemoteConnectionLeaseClient` with the file-operation methods currently forwarded by `SFTPRemoteFileService`.
  - `SSHSFTPAdapter` stores registrations as capability clients plus `RemoteConnectionLease`, not as policy-free raw `SSHClient` slots.
  - `SSHSFTPAdapter.withService(...)` runs SFTP work through `RemoteConnectionLease.withExclusiveClient`.
  - `SSHSFTPAdapter.disconnect(serverId:)` waits for in-flight owned SFTP work before closing the owned lease.
- Consumes:
  - Task 16 `RemoteConnectionLease.withExclusiveClient`.
  - Existing `RemoteFileService` API.

- [x] **Step 1: Add RED adapter lifecycle tests**

Create `SSHSFTPAdapterTests` with a `Test Context` comment and these tests:

```swift
@MainActor
@Test
func borrowedClientDisconnectDoesNotCloseTerminalOwnedClient() async throws

@MainActor
@Test
func disconnectWaitsForInFlightOwnedSFTPOperationBeforeClosingClient() async throws

@MainActor
@Test
func concurrentOperationsForSameServerAreSerializedThroughOneLease() async throws

@MainActor
@Test
func failedBorrowedOperationDropsBorrowedRegistrationBeforeRetry() async throws
```

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/SSHSFTPAdapterTests ENABLE_DEBUG_DYLIB=NO
```

Expected failure: the test seams and `SFTPRemoteFileClient` capability protocol do not exist, and disconnect does not prove it waits for in-flight adapter work.

- [x] **Step 2: Add RemoteFiles SFTP capability protocol**

Move the SFTP-facing methods into `SFTPRemoteFileClient` in RemoteFiles infrastructure. `SSHClient` should conform in this feature boundary. `SFTPRemoteFileService` should depend on `any SFTPRemoteFileClient`.

- [x] **Step 3: Route adapter operations through the lease gate**

Keep `SSHSFTPAdapter` as the stable RemoteFiles owner. It may create an owned `SSHClient` only through one narrow factory seam, and all use of that client must be inside the lease-exclusive operation.

- [x] **Step 4: Tighten disconnect ordering**

If a server has an in-flight SFTP operation, `disconnect(serverId:)` must wait for that operation to leave the lease gate before owned disconnect. Borrowed disconnect must remove RemoteFiles registration without disconnecting the terminal-owned client.

- [x] **Step 5: Run focused RemoteFiles tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/RemoteFileBrowserStoreTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/RemoteFiles/Infrastructure/SFTPRemoteFileClient.swift \
  VVTerm/Features/RemoteFiles/Infrastructure/SFTPRemoteFileService.swift \
  VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift \
  VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift \
  VVTermTests/Features/RemoteFiles/SSHSFTPAdapterTests.swift \
  VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift
git commit -m "refactor: route remote files through connection leases"
```

- [x] **Step 7: API/boundary cleanup**

Before Task 18, check that RemoteFiles application/UI code does not reason about raw `SSHClient`, that test files include the required Test Context, and that any temporary factory seams are `internal` and named by behavior. Record the result in the Progress Ledger.

## Task 18: Stats Collector Awaitable Stop

**Files:**
- Modify: `VVTerm/Features/Stats/Application/ServerStatsCollector.swift`
- Modify: `VVTerm/Features/Stats/UI/ServerStatsView.swift`
- Test: `VVTermTests/Features/Stats/ServerStatsCollectorLifecycleTests.swift`

**Interfaces:**
- Produces:
  - `ServerStatsCollector.stopCollectingAndWait() async`
  - `ServerStatsCollector.startCollecting(...)` waits for any pending stop/close before replacing the current lease.
  - `ServerStatsView` tracks or awaits collector stop work from visibility changes and disappearance.
- Consumes:
  - Existing `RemoteConnectionLease.close()`.
  - Existing `ServerStatsCollector.stopCollecting()` may remain as a synchronous intent helper only if it stores a task that a later start waits on.

- [x] **Step 1: Add RED Stats lifecycle tests**

Create `ServerStatsCollectorLifecycleTests` with a `Test Context` comment and these tests:

```swift
@MainActor
@Test
func stopCollectingAndWaitAwaitsOwnedLeaseDisconnect() async throws

@MainActor
@Test
func startCollectingWaitsForPendingStopBeforeReplacingOwnedLease() async throws

@MainActor
@Test
func stopCollectingDoesNotDisconnectBorrowedSharedClient() async throws

@MainActor
@Test
func startCollectingWaitsForFailedCollectionLeaseCloseBeforeRetry() async throws

@MainActor
@Test
func cancelledCollectionDoesNotPublishConnectionError() async throws
```

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests ENABLE_DEBUG_DYLIB=NO
```

Expected failure: `stopCollectingAndWait()` and the needed lease/test seams do not exist.

- [x] **Step 2: Add injectable lease and collection seams**

Add narrow internal test seams for creating a `RemoteConnectionLease` and running one collection loop without real network. Keep user-facing initialization unchanged.

- [x] **Step 3: Make stop awaitable**

Cancel the stored collection task, await its completion or close task, close the current lease exactly once, then clear collector state. Cancellation should not surface as a connection error.

- [x] **Step 4: Track stop from SwiftUI**

`ServerStatsView` may use `.task(id:)` and `onDisappear` only to send stop intent into the collector. Any returned lifecycle-critical task must be awaited in a SwiftUI `.task` or stored by the collector so the next start waits on it.

- [x] **Step 5: Run focused Stats lifecycle tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 6: Commit**

```bash
git add VVTerm/Features/Stats/Application/ServerStatsCollector.swift \
  VVTerm/Features/Stats/UI/ServerStatsView.swift \
  VVTermTests/Features/Stats/ServerStatsCollectorLifecycleTests.swift
git commit -m "refactor: make stats collection stop awaitable"
```

- [x] **Step 7: API/boundary cleanup**

Before Task 19, verify stop/start names read as side-effectful lifecycle APIs, `ServerStatsView` no longer drops close tasks, and restart ordering no longer depends on stale `isCollecting` alone. Record the result in the Progress Ledger.

## Task 19: Stats Command Executor Boundary

**Files:**
- Modify: `VVTerm/Core/SSH/RemoteCommandExecuting.swift`
- Modify: `VVTerm/Features/Stats/Application/ServerStatsCollector.swift`
- Modify: `VVTerm/Features/Stats/Infrastructure/Platforms/PlatformStatsCollector.swift`
- Modify: all files under `VVTerm/Features/Stats/Infrastructure/Platforms/`
- Modify: `VVTerm/Features/Stats/UI/ServerStatsView.swift`
- Test: `VVTermTests/Features/Stats/ServerStatsCollectorLifecycleTests.swift`
- Test: `VVTermTests/Features/Stats/StatsParsingUtilsTests.swift`
- Test: `VVTermTests/Features/Stats/ServerStatsDomainTests.swift`

**Interfaces:**
- Produces:
  - Stats platform collectors consume `any RemoteCommandExecuting`, not `SSHClient`.
  - Platform detection is performed through a command-executor-facing API or a Stats-owned resolver, not `SSHClient.remotePlatform()` from application code.
  - `ServerStatsView` no longer exposes `() -> SSHClient?`; it asks for a borrowed lease or feature-level stats connection provider.
- Consumes:
  - Task 18 awaitable collector lifecycle.
  - Existing platform parsing utilities.

- [x] **Step 1: Add RED command-executor tests**

Add or extend `ServerStatsCollectorLifecycleTests` with:

```swift
@MainActor
@Test
func collectorUsesCommandExecutorWithoutRawSSHClientOwnership() async throws
```

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests ENABLE_DEBUG_DYLIB=NO
```

Expected failure: platform collectors and collector seams still require `SSHClient`.

- [x] **Step 2: Move platform collectors to `RemoteCommandExecuting`**

Change `PlatformStatsCollector.collectStats` and `getSystemInfo` to accept `any RemoteCommandExecuting`. Preserve existing parsing behavior and command strings.

- [x] **Step 3: Add platform resolution behind the command boundary**

If `RemoteCommandExecuting` lacks enough information to resolve `RemotePlatform`, add a small Stats-owned resolver that runs remote commands through the executor. Do not add Stats policy to `SSHClient`.

- [x] **Step 4: Replace raw shared-client provider in Stats UI**

Rename the UI injection point from `sharedClientProvider` to a lease/provider name that describes ownership. The UI must not use `ObjectIdentifier(SSHClient)` as lifecycle truth.

- [x] **Step 5: Run focused Stats tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests -only-testing:VVTermTests/StatsParsingUtilsTests -only-testing:VVTermTests/ServerStatsDomainTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 6: Commit**

```bash
git add VVTerm/Core/SSH/RemoteCommandExecuting.swift \
  VVTerm/Features/Stats/Application/ServerStatsCollector.swift \
  VVTerm/Features/Stats/Infrastructure/Platforms \
  VVTerm/Features/Stats/UI/ServerStatsView.swift \
  VVTermTests/Features/Stats
git commit -m "refactor: decouple stats collection from raw SSH clients"
```

- [x] **Step 7: API/boundary cleanup**

Before Task 20, verify Stats Domain remains pure, platform collectors stay Infrastructure, UI only sends visibility/retry intent, and every touched Stats test file has the required Test Context header. Record the result in the Progress Ledger.

## Task 20: RemoteFiles/Stats Lease Boundary Final Sweep

**Files:**
- Modify only files found by the audit commands below.
- Test: focused RemoteFiles, Stats, and connection lifecycle tests.

**Interfaces:**
- Produces:
  - RemoteFiles and Stats no longer expose raw `SSHClient` through UI/application-facing APIs.
  - Terminal managers either keep raw client access `private`/narrow or expose borrowed `RemoteConnectionLease` providers with clear ownership names.
  - No lifecycle-critical stop/disconnect/close task is dropped by SwiftUI or feature UI.

- [x] **Step 1: Run audit commands**

```bash
rg -n "sharedStatsClient|activeSSHClient|getSSHClient|SSHClient\\(|ObjectIdentifier\\(.*SSHClient|stopCollecting\\(\\)" VVTerm/Features/RemoteFiles VVTerm/Features/Stats VVTerm/Features/TerminalSessions VVTerm/App -g '*.swift'
rg -n "RemoteConnectionLease\\(|withExclusiveClient|disconnectWhenDone: false" VVTerm/Features/RemoteFiles VVTerm/Features/Stats VVTerm/Core/SSH -g '*.swift'
rg -n "Task\\.detached|Task \\{" VVTerm/Features/RemoteFiles VVTerm/Features/Stats -g '*.swift'
```

- [x] **Step 2: Classify every hit**

Write classifications into the Progress Ledger. Every remaining raw-client hit must be private infrastructure construction, a test fake, or a temporary item assigned to the next plan wave.

- [x] **Step 3: Add regression tests for non-exempt hits**

Use the smallest focused tests in `SSHSFTPAdapterTests`, `ServerStatsCollectorLifecycleTests`, or `ConnectionLifecycleIntegrationTests`.

- [x] **Step 4: Run final focused suite**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteConnectionLeaseTests -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests -only-testing:VVTermTests/StatsParsingUtilsTests -only-testing:VVTermTests/ServerStatsDomainTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
```

Then run:

```bash
xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 5: Commit**

```bash
git add docs/refactor-swift-best-practice.md VVTerm VVTermTests
git commit -m "refactor: complete remote lease boundary cleanup"
```

## Task 21: Core SSH FFI Boundary Final Sweep

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Modify: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Modify: `VVTerm/Core/SSH/KnownHostsManager.swift`
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Modify: `VVTerm/Features/Settings/UI/TerminalSettingsView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
- Test: `VVTermTests/SSHErrorRetryableTests.swift`
- Test: `VVTermTests/KnownHostsManagerTests.swift`
- Test: `VVTermTests/ServerManagerBootstrapTests.swift`

**Interfaces:**
- Consumes:
  - `LibSSH2SessionDriving`
  - `LibSSH2RawError`
  - `KnownHostsStore`
  - `KnownHostVerificationService`
  - `SSHSession.abort()`
- Produces:
  - Every remaining allowed `NSLock`, `nonisolated(unsafe)`, and direct libssh2 C call in `Core/SSH` is classified in the Progress Ledger as a stable low-level boundary, a test fake, or a follow-up task.
  - Raw libssh2 failures used by connect/auth/channel/session teardown preserve operation, raw code, and message before translation.
  - Known-host storage has one authoritative actor-backed implementation for new application/infrastructure code; legacy synchronous access is either removed or explicitly documented as a narrow compatibility facade.

- [x] **Step 1: Run focused Core SSH audit commands**

```bash
rg -n "nonisolated\\(unsafe\\)|NSLock|DispatchQueue|libssh2_|withUnsafe|UnsafeMutable|UnsafePointer|Darwin\\.close|closeSocket|session_last_error" VVTerm/Core/SSH -g '*.swift'
rg -n "KnownHostsManager|KnownHostsStore|KnownHostVerificationService|libssh2|LibSSH2RawError|SSHError\\.libssh2|Authentication failed" VVTermTests VVTerm/Core/SSH -g '*.swift'
```

Classify each hit in the Progress Ledger before editing code. Exemptions must name the owner and invariant, for example "private process-global libssh2 init lock" or "keyboard-interactive callback context lifetime is owned by `SSHSession`".

- [x] **Step 2: Add RED auth raw-error boundary tests**

Add focused tests to `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`:

```swift
func testPublicKeyAuthFailurePreservesRawLibSSH2Error() async {
    let driver = RecordingLibSSH2SessionDriver(
        sessionInitResult: OpaquePointer(bitPattern: 0x1),
        authMethods: .methods("publickey"),
        publicKeyAuthResult: .failure(
            LibSSH2RawError(
                operation: .authentication,
                code: -19,
                message: "Callback returned error"
            )
        )
    )
    let session = SSHSession(config: .libSSH2LifecycleTest, driver: driver)

    do {
        try await session.connect()
        XCTFail("Expected raw libssh2 authentication failure")
    } catch SSHError.libssh2(let rawError) {
        XCTAssertEqual(rawError.operation, .authentication)
        XCTAssertEqual(rawError.code, -19)
        XCTAssertEqual(rawError.message, "Callback returned error")
    } catch {
        XCTFail("Expected SSHError.libssh2, got \(error)")
    }
}
```

This is intentionally an auth-boundary RED test, not a handshake test. Handshake is already behind `LibSSH2SessionDriving`; the current unprotected behavior to expose is that auth last-error details such as `-19 Callback returned error` can be collapsed into `SSHError.authenticationFailed`. If the auth audit finds a narrower unprotected libssh2 path, use the same RED shape for that path instead. Do not add a broad integration test that needs a real server.

- [x] **Step 3: Run RED tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/SSHErrorRetryableTests ENABLE_DEBUG_DYLIB=NO
```

Expected: the new auth raw-boundary assertion fails or fails to compile because `LibSSH2SessionDriving` cannot model auth methods, public-key auth, or `.authentication` raw errors yet.

- [x] **Step 4: Move one raw boundary behind `LibSSH2SessionDriving`**

Make the minimal production change for the failing test:
- Add only the driver method needed by the new test, named after the libssh2 auth operation it protects.
- Add `LibSSH2RawError.Operation.authentication` and throw `SSHError.libssh2(rawError)` internally when libssh2 reports an auth callback/protocol error distinct from a normal credential rejection.
- Keep unsafe pointers inside the driver method or inside a small non-escaping closure.
- Log or preserve `LibSSH2RawError` before converting to user-facing `SSHError`.
- Keep `SSHSession` as the owner of session/channel/socket cleanup; do not let SwiftUI, RemoteFiles, or Stats own this teardown path.

- [x] **Step 5: Reconcile known-host ownership**

If Step 1 still finds new code paths using `KnownHostsManager.shared` directly, move them to `KnownHostsStore` / `KnownHostVerificationService`. If only settings/test compatibility remains, record the compatibility reason in the Progress Ledger and add or update a test in `KnownHostsManagerTests` that protects the intended store behavior.

- [x] **Step 6: Run focused Core SSH verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/SSHErrorRetryableTests -only-testing:VVTermTests/KnownHostsManagerTests -only-testing:VVTermTests/SSHAuthenticationGateCancellationTests -only-testing:VVTermTests/ServerManagerBootstrapTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 7: Commit**

```bash
git add docs/refactor-swift-best-practice.md VVTerm/Core/SSH VVTermTests/Core/SSH VVTermTests/SSHErrorRetryableTests.swift VVTermTests/KnownHostsManagerTests.swift
git add VVTerm/Features/Servers/Application/ServerManager.swift \
  VVTerm/Features/Settings/UI/TerminalSettingsView.swift \
  VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift \
  VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift \
  VVTermTests/ServerManagerBootstrapTests.swift
git commit -m "refactor: tighten core SSH FFI boundaries"
```

## Task 22: Move Shell Channel Setup and Teardown Behind the libssh2 Driver

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Modify: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`

**Interfaces:**
- Consumes:
  - `LibSSH2SessionDriving`
  - `LibSSH2RawError`
  - `SSHSession.startShell(cols:rows:startupCommand:environment:terminalType:)`
  - `SSHSession.closeShell(_:)`
- Produces:
  - `LibSSH2RawError.Operation.channelOpen`
  - `LibSSH2RawError.Operation.channelSetEnvironment`
  - `LibSSH2RawError.Operation.channelRequestPty`
  - `LibSSH2RawError.Operation.channelProcessStartup`
  - `LibSSH2RawError.Operation.channelClose`
  - `LibSSH2RawError.Operation.channelFree`
  - Driver-owned channel setup methods, with unsafe C calls confined to `LibSSH2SessionDriver`:
    - `openSessionChannel(session:) -> OpaquePointer?`
    - `setChannelEnvironment(channel:name:value:) -> Int32`
    - `requestPty(channel:terminalType:cols:rows:) -> Int32`
    - `startShell(channel:) -> Int32`
    - `startExec(channel:command:) -> Int32`
    - `closeChannel(_:) -> Int32`
    - `freeChannel(_:) -> Int32`

- [x] **Step 1: Add RED channel setup cleanup tests**

Add tests to `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`:

```swift
func testShellPtyFailureClosesAndFreesOpenedChannel() async {
    let driver = RecordingLibSSH2SessionDriver(
        sessionInitResult: OpaquePointer(bitPattern: 0x1),
        authMethods: .methods("publickey"),
        publicKeyAuthResult: .success,
        channelOpenResult: OpaquePointer(bitPattern: 0x22),
        ptyResult: LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED
    )
    let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

    do {
        try await session.connect()
        _ = try await session.startShell(cols: 80, rows: 24)
        XCTFail("Expected PTY request failure")
    } catch SSHError.shellRequestFailed {
        // Expected.
    } catch {
        XCTFail("Expected SSHError.shellRequestFailed, got \(error)")
    }

    XCTAssertEqual(
        driver.channelEvents(),
        [.openSession, .requestPty, .close, .free],
        "PTY failure must close and free the channel that startShell opened"
    )
}
```

Add the fake support locally in `RecordingLibSSH2SessionDriver`:

```swift
enum ChannelEvent: Equatable {
    case openSession
    case setEnvironment(String)
    case requestPty
    case startShell
    case startExec(String)
    case close
    case free
}
```

- [x] **Step 2: Run RED tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests ENABLE_DEBUG_DYLIB=NO
```

Expected: compile failure because `LibSSH2SessionDriving` does not yet expose channel setup/teardown methods or channel raw-error operations.

- [x] **Step 3: Move shell channel setup/teardown C calls into the driver**

Make the minimal production change for the shared shell/exec channel setup and teardown boundary:
- Replace direct `libssh2_session_set_blocking`, `libssh2_channel_open_ex`, `libssh2_channel_setenv_ex`, `libssh2_channel_request_pty_ex`, `libssh2_channel_process_startup`, `libssh2_channel_close`, and `libssh2_channel_free` calls in `startShell`, `closeShellInternal`, `closeAllShellChannels`, `closeAllExecChannels`, `failAllExecRequests`, and `finishExecRequest` with driver methods.
- Keep `SSHSession` as the owner of `ShellChannelState`, `ExecRequest`, shell ids, continuations, and cleanup ordering.
- Preserve existing user-facing errors for normal shell startup failures.
- When a channel setup call fails with a raw libssh2 error distinct from the existing user-facing error, log or preserve the `LibSSH2RawError` before mapping to the existing `SSHError`.

- [x] **Step 4: Run GREEN tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 5: API and boundary cleanup**

Before committing:
- Verify `SSHClient.swift` no longer calls `libssh2_session_set_blocking`, `libssh2_channel_setenv_ex`, `libssh2_channel_request_pty_ex`, `libssh2_channel_process_startup`, `libssh2_channel_close`, or `libssh2_channel_free` directly in shell setup/teardown paths.
- Verify channel ownership remains in `SSHSession`; `LibSSH2SessionDriver` must not store channel pointers.
- Verify test fake channel event names describe behavior, not implementation-only line numbers.
- Record any direct channel I/O calls still deferred to Task 23 in the Progress Ledger.

- [x] **Step 6: Run focused verification and review**

```bash
rg -n "libssh2_session_set_blocking|libssh2_channel_open_ex|libssh2_channel_setenv_ex|libssh2_channel_request_pty_ex|libssh2_channel_process_startup|libssh2_channel_close|libssh2_channel_free" VVTerm/Core/SSH/SSHClient.swift VVTerm/Core/SSH/LibSSH2SessionDriver.swift
git diff --check
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
```

Expected scan result: `LibSSH2SessionDriver.swift` owns the Task 22 shell channel setup/teardown C calls. `SSHClient.swift` may still show channel I/O, exec request, SCP upload, exec upload, resize, and upload finish/drain hits assigned to Task 23; record those exact remaining ranges in the Progress Ledger before committing Task 22.

Request code review for Task 22 before committing.

- [x] **Step 7: Commit**

```bash
git add VVTerm/Core/SSH/LibSSH2SessionDriver.swift \
  VVTerm/Core/SSH/SSHClient.swift \
  VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift \
  docs/refactor-swift-best-practice.md
git commit -m "refactor: move shell channel setup behind libssh2 driver"
```

## Task 23: Move Channel I/O, Exec, Upload, and Resize Calls Behind the Driver

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Modify: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
- Test: `VVTermTests/RemoteTerminalBootstrapTests.swift`

**Interfaces:**
- Consumes:
  - Task 22 channel setup/teardown driver methods.
- Produces:
  - Driver-owned channel I/O methods:
    - `readChannel(_:, stream:into:) -> Int`
    - `writeChannel(_:, stream:bytes:offset:remaining:) -> Int`
    - `isChannelEOF(_:) -> Bool`
    - `sendChannelEOF(_:) -> Int32`
    - `waitChannelEOF(_:) -> Int32`
    - `waitChannelClosed(_:) -> Int32`
    - `channelExitStatus(_:) -> Int32`
    - `requestPtySize(channel:cols:rows:) -> Int32`
    - `handleExtendedData(channel:mode:) -> Int32`
    - `openSCPChannel(session:path:permissions:size:) -> OpaquePointer?`
    - `sessionBlockDirections(session:) -> Int32`
  - `SSHSession` remains the only owner of I/O tasks, shell state, exec request state, upload retry strategy, and cancellation.

- [x] **Step 1: Add RED channel write/EAGAIN tests**

Add a fake-driver test that starts a shell, configures `writeChannel` to return `LIBSSH2_ERROR_EAGAIN` once and then a positive byte count, calls `session.write(_:to:)`, and asserts the driver receives the expected copied bytes and retry offsets. The production driver method owns the non-escaping pointer conversion from that byte slice to `libssh2_channel_write_ex`.

- [x] **Step 2: Add RED exec startup/read tests**

Add a fake-driver test for `execute(_:)` where channel open succeeds, exec startup returns `EAGAIN` once then success, stdout returns data, EOF becomes true, and the continuation returns the expected output.

- [x] **Step 3: Move channel read/write/EOF/resize calls**

Move direct `libssh2_channel_read_ex`, `libssh2_channel_write_ex`, `libssh2_channel_eof`, `libssh2_channel_request_pty_size_ex`, `libssh2_channel_send_eof`, `libssh2_channel_wait_eof`, `libssh2_channel_wait_closed`, `libssh2_channel_get_exit_status`, `libssh2_channel_handle_extended_data2`, `libssh2_scp_send64`, and `libssh2_session_block_directions` calls from `SSHClient.swift` into `LibSSH2SessionDriver`.

- [x] **Step 4: Run focused tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/RemoteTerminalBootstrapTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 5: API and boundary cleanup**

Verify no channel I/O C calls remain in `SSHClient.swift`; raw channel pointers are still stored only in `SSHSession` state objects; upload and exec cancellation still resume continuations exactly once. Record remaining SCP/SFTP-specific calls in the Progress Ledger.

- [x] **Step 6: Request review and commit**

```bash
git add VVTerm/Core/SSH/LibSSH2SessionDriver.swift VVTerm/Core/SSH/SSHClient.swift VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift docs/refactor-swift-best-practice.md
git commit -m "refactor: route channel IO through libssh2 driver"
```

## Task 24: Move SFTP Session and Handle Operations Behind the Driver

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Modify: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
- Test: `VVTermTests/Features/RemoteFiles/SSHSFTPAdapterTests.swift`
- Test: `VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift`

**Interfaces:**
- Consumes:
  - `RemoteConnectionLease.withExclusiveClient`
  - Existing RemoteFiles SFTP adapter tests.
- Produces:
  - Driver-owned SFTP methods for init, shutdown, open, close handle, readdir, seek, read, write, stat, symlink, mkdir, setstat, rename, unlink, rmdir, statvfs, and last-error mapping.
  - `SSHSession` remains the owner of cached `sftpSession` and remote-file async operation ordering.

- [x] **Step 1: Add RED SFTP cleanup test**

Add a fake-driver test that opens an SFTP directory handle, forces a readdir failure, and asserts the handle is closed exactly once and the error maps through `RemoteFileBrowserError`.

- [x] **Step 2: Move SFTP C calls into `LibSSH2SessionDriver`**

Move `libssh2_sftp_init`, `libssh2_sftp_shutdown`, `libssh2_sftp_open_ex`, `libssh2_sftp_close_handle`, `libssh2_sftp_readdir_ex`, `libssh2_sftp_seek64`, `libssh2_sftp_read`, `libssh2_sftp_write`, `libssh2_sftp_stat_ex`, `libssh2_sftp_symlink_ex`, `libssh2_sftp_statvfs`, `libssh2_sftp_mkdir_ex`, `libssh2_sftp_rename_ex`, `libssh2_sftp_unlink_ex`, `libssh2_sftp_rmdir_ex`, and `libssh2_sftp_last_error` behind driver methods.

- [x] **Step 3: Run focused RemoteFiles verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/RemoteFileBrowserStoreTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 4: API and boundary cleanup**

Verify RemoteFiles application/UI code still depends on `SSHSFTPAdapter` or leases, not raw `SSHClient`; `SSHSession` remains the owner of cached SFTP state; `LibSSH2SessionDriver` does not store SFTP pointers; path and buffer unsafe pointers stay inside non-escaping driver calls. Request code review before committing.

- [x] **Step 5: Commit**

```bash
git add VVTerm/Core/SSH/LibSSH2SessionDriver.swift VVTerm/Core/SSH/SSHClient.swift VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift VVTermTests/Features/RemoteFiles docs/refactor-swift-best-practice.md
git commit -m "refactor: route SFTP operations through libssh2 driver"
```

## Task 25: Final Core SSH FFI Audit and Keepalive Boundary

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Modify: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Task 22 through Task 24 driver boundaries.
- Produces:
  - `sendKeepAlive(session:) -> Int32`
  - Final Progress Ledger classification of every remaining `libssh2_`, `withUnsafe`, `UnsafePointer`, `NSLock`, and `nonisolated(unsafe)` hit in `Core/SSH`.

- [x] **Step 1: Add RED keepalive driver test**

Add a fake-driver test that calls `SSHSession.sendKeepAlive()` after connect and asserts the driver method was invoked, without exposing the raw `libssh2_keepalive_send` call to `SSHClient.swift`.

- [x] **Step 2: Move keepalive and final direct session helpers**

Move `libssh2_keepalive_send` behind `LibSSH2SessionDriving`. If any remaining direct `libssh2_` calls are still in `SSHClient.swift`, either move them or record a named exemption with owner and invariant in the Progress Ledger.

- [x] **Step 3: Run final Core SSH boundary scan**

```bash
rg -n "libssh2_|withUnsafe|UnsafeMutable|UnsafePointer|NSLock|nonisolated\\(unsafe\\)" VVTerm/Core/SSH -g '*.swift'
git diff --check
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/SSHErrorRetryableTests -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/RemoteFileBrowserStoreTests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 4: Request final Core SSH FFI review and commit**

```bash
git add VVTerm/Core/SSH/LibSSH2SessionDriver.swift VVTerm/Core/SSH/SSHClient.swift VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift docs/refactor-swift-best-practice.md
git commit -m "refactor: complete core SSH FFI boundary sweep"
```

## Task 26: Whole-Plan Closure Audit and Test Context Tightening

**Files:**
- Modify: `VVTermTests/ConnectionSessionManagerOpenTests.swift`
- Modify: `VVTermTests/ServerManagerBootstrapTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Test-context rule in `docs/engineering/swift-best-practices.md`
  - Task 25 final Core SSH FFI scan classification.
- Produces:
  - Clear Given/When/Then intent and assertion messages for the remaining weak lifecycle tests.
  - A plan ledger entry that records the post-Task-25 whole-plan audit findings and confirms the next executable task.

- [x] **Step 1: Tighten lifecycle test intent**

In `ConnectionSessionManagerOpenTests.testDisconnectServerAndWaitClearsSSHRegistrationBeforeReturning`, add Given/When/Then comments and assertion messages for the lease/session/server state assertions so a future failure distinguishes lifecycle regression from a changed API contract.

In `ServerManagerBootstrapTests.knownHostRemovalCandidatesUsePostDeleteServerState`, add Given/When/Then comments and an assertion message explaining that known-host removal must use post-delete server state so shared hosts are preserved.

- [x] **Step 2: Run focused test-context verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionSessionManagerOpenTests/testDisconnectServerAndWaitClearsSSHRegistrationBeforeReturning -only-testing:VVTermTests/ServerManagerBootstrapTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 3: Run plan closure audit commands**

```bash
rg -n "^- \\[ \\]" docs/refactor-swift-best-practice.md
rg -n "TO[D]O|T[B]D|W[I]P" docs/refactor-swift-best-practice.md
rg -n "libssh2_" VVTerm/Core/SSH/SSHClient.swift VVTerm/Core/SSH/LibSSH2SessionDriver.swift
```

Expected results: before Step 5 completes, the first unchecked step is Task 26 Step 5; after Task 26 is committed, the first unchecked step is Task 27 Step 1; the stub-language scan has no output; no direct lowercase `libssh2_` calls remain in `SSHClient.swift`; direct lowercase `libssh2_` calls remain confined to `LibSSH2SessionDriver.swift`.

- [x] **Step 4: API and boundary cleanup**

Verify this task changes only test explanatory context and plan bookkeeping. Do not change production lifecycle behavior in this task.

- [x] **Step 5: Request review and commit**

```bash
git add VVTermTests/ConnectionSessionManagerOpenTests.swift VVTermTests/ServerManagerBootstrapTests.swift docs/refactor-swift-best-practice.md
git commit -m "test: tighten lifecycle test context"
```

## Task 27: RemoteConnectionLease Close Rejects Queued Work

**Files:**
- Modify: `VVTerm/Core/SSH/RemoteConnectionLease.swift`
- Test: `VVTermTests/Core/SSH/RemoteConnectionLeaseTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `RemoteConnectionLease.withExclusiveClient(_:)`
  - `RemoteConnectionLease.close()`
- Produces:
  - Close semantics where operations already in flight may finish, but queued operations that have not started are canceled once close begins.

- [x] **Step 1: Add RED queued-close test**

Add `closeRejectsQueuedOperationsAfterCloseBegins` to `RemoteConnectionLeaseTests`. Arrange one exclusive operation that blocks, start a second operation that queues, start `lease.close()`, release the first operation, then assert the second operation throws `CancellationError` and does not run its body. For an owned lease, also assert disconnect happens after the first operation finishes.

- [x] **Step 2: Run RED test**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteConnectionLeaseTests ENABLE_DEBUG_DYLIB=NO
```

Expected before implementation: FAIL because the queued operation resumes and runs after close begins, or because close waits for a queued operation that should have been canceled.

- [x] **Step 3: Implement queued-operation cancellation**

Change `RemoteConnectionLeaseState` so close marks the lease closed, waits for the active operation, cancels queued waiters that have not started, and then disconnects owned clients exactly once. Use throwing continuations or an equivalent explicit result so a resumed queued operation observes `CancellationError` and does not leave `isOperationInFlight` stuck.

- [x] **Step 4: Run focused lease verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteConnectionLeaseTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 5: API and boundary cleanup**

Verify the lease API remains small: `close()` and `withExclusiveClient(_:)` stay as the public boundary, mutable queue state remains actor-owned, and callers do not need to know whether a lease is owned or borrowed to avoid running after close.

- [x] **Step 6: Request review and commit**

```bash
git add VVTerm/Core/SSH/RemoteConnectionLease.swift VVTermTests/Core/SSH/RemoteConnectionLeaseTests.swift docs/refactor-swift-best-practice.md
git commit -m "fix: reject queued remote lease work after close"
```

## Task 28: Server and Workspace Delete Await Runtime Teardown

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Test: `VVTermTests/ServerManagerBootstrapTests.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ConnectionSessionManager.disconnectServerAndWait(_:)`
  - `TerminalTabManager.disconnectServerAndWait(_:)`
  - `RemoteFileBrowserStore.disconnect(serverId:)`
  - `ServerStatsCollector.stopCollectingAndWait()`
- Produces:
  - An application-layer deletion lifecycle hook so server/workspace deletion can await live terminal teardown before deleting credentials and metadata.

- [x] **Step 1: Add RED deletion ordering tests**

Add tests proving `ServerManager.deleteServer(_:)` invokes an injected teardown hook before keychain credential deletion and local metadata removal. Add a workspace deletion test proving each workspace server is torn down before the workspace is removed.

- [x] **Step 2: Run RED tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests ENABLE_DEBUG_DYLIB=NO
```

Expected before implementation: FAIL because `ServerManager.deleteServer(_:)` has no injected awaitable teardown boundary.

- [x] **Step 3: Add deletion teardown boundary**

Add a narrow `ServerDeletionTeardown` closure or small protocol to `ServerManager` with a default production implementation that awaits terminal session and pane disconnect for the server. Keep RemoteFiles and Stats teardown wired at the app/screen boundary if their owning stores are view-owned; do not make `ServerManager` own view-scoped stores.

- [x] **Step 4: Wire UI deletion intents through the boundary**

Keep UI button tasks as intent wrappers only. Server deletion must await the application-layer teardown boundary before credentials are removed. Workspace deletion must use the same path for each contained server.

- [x] **Step 5: Run focused deletion verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 6: API and boundary cleanup**

Verify the Servers feature sends deletion intent and does not directly orchestrate TerminalSessions internals from UI. Verify teardown is awaitable, test-injectable, and idempotent.

- [x] **Step 7: Request review and commit**

```bash
git add VVTerm/Features/Servers/Application/ServerManager.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTermTests/ServerManagerBootstrapTests.swift VVTermTests/ConnectionLifecycleIntegrationTests.swift docs/refactor-swift-best-practice.md
git commit -m "fix: await server deletion teardown"
```

## Task 29: App Termination and LRU Eviction Await Cleanup

**Files:**
- Modify: `VVTerm/App/VVTermApp.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalSurfaceTeardownTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `closeSessionAndWait(_:)`
  - `disconnectServerAndWait(_:)`
  - `scheduleSSHUnregister(for:)`
  - `trackServerTeardownTask(_:for:)`
- Produces:
  - Awaitable all-terminal teardown for app termination.
  - LRU terminal eviction cleanup tracked per server so same-server reopen waits for unregister/disconnect.

- [x] **Step 1: Add RED app termination teardown test**

Add a manager-level test proving a new `disconnectAllAndWait()` waits for each session cleanup task before returning. Include a pane equivalent for `TerminalTabManager` if the manager has open panes.

- [x] **Step 2: Add RED LRU eviction cleanup test**

Add a test that forces terminal-surface eviction, injects a registered SSH client, and asserts the evicted server's teardown task is tracked so an immediate reopen waits for unregister completion.

- [x] **Step 3: Run RED tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests ENABLE_DEBUG_DYLIB=NO
```

Expected before implementation: FAIL because `disconnectAll()` is synchronous/non-awaiting and LRU eviction discards returned unregister tasks.

RED result: `xcodebuild test ... -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests ENABLE_DEBUG_DYLIB=NO` failed to build because `ConnectionSessionManager.disconnectAllAndWait()`, `ConnectionSessionManager.registerTerminalForTesting(sessionId:)`, and `TerminalTabManager.disconnectAllAndWait()` did not exist.

- [x] **Step 4: Implement awaitable termination APIs**

Add `disconnectAllAndWait()` to session and tab managers. Update macOS and iOS app termination paths to wait for session and pane cleanup, with the existing timeout preserved as an outer guard rather than as proof that cleanup completed.

- [x] **Step 5: Track LRU eviction cleanup**

When a terminal surface is evicted, route the returned unregister task through the same server teardown tracking used by stale shell cleanup and managed tmux cleanup. Ensure shell handler cancellation is either awaited or explicitly part of the tracked cleanup task.

- [x] **Step 6: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

GREEN result: focused `xcodebuild test` passed 52 Swift Testing tests in `ConnectionLifecycleIntegrationTests` and `TerminalSurfaceTeardownTests`; `git diff --check` passed.

- [x] **Step 7: API and boundary cleanup**

Verify app delegates call application-layer teardown APIs only; no SwiftUI or app delegate code manually unregisters shell/client resources. Verify no cleanup task handles are dropped in LRU eviction.

- [x] **Step 8: Request review and commit**

```bash
git add VVTerm/App/VVTermApp.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTermTests/ConnectionLifecycleIntegrationTests.swift VVTermTests/Features/TerminalSessions/TerminalSurfaceTeardownTests.swift docs/refactor-swift-best-practice.md
git commit -m "fix: await terminal cleanup on termination"
```

## Task 30: RemoteFiles and Stats Lease Provider Boundaries

**Files:**
- Modify: `VVTerm/Core/SSH/RemoteConnectionLease.swift`
- Modify: `VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift`
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift`
- Modify: `VVTerm/Features/Stats/Application/ServerStatsCollector.swift`
- Add: `VVTerm/Features/Stats/Infrastructure/StatsSSHConnectionProvider.swift`
- Modify: `VVTerm/App/VVTermApp.swift`
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift`
- Test: `VVTermTests/Features/RemoteFiles/SSHSFTPAdapterTests.swift`
- Test: `VVTermTests/Features/Stats/ServerStatsCollectorLifecycleTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `RemoteConnectionLease`
  - `RemoteCommandExecuting`
  - existing app composition lease providers.
- Produces:
  - A named `RemoteConnectionLeaseProviding` boundary or equivalent closure type injected from composition roots.
  - RemoteFiles defaults that do not reach into `ConnectionSessionManager.shared` or `TerminalTabManager.shared`.
  - Stats owned-client creation moved behind an injected factory/provider.

- [x] **Step 1: Add RED RemoteFiles default-boundary test**

Add a test proving `SSHSFTPAdapter` without an injected borrowed provider does not consult TerminalSessions singletons. The adapter should use only injected dependencies and create owned infrastructure clients when no borrowed lease is provided.

- [x] **Step 2: Add RED Stats owned-factory boundary test**

Add a `ServerStatsCollectorLifecycleTests` case that uses a named Stats owned-connection factory boundary rather than `ServerStatsCollector.makeConnection`. The test should fail to compile until the production code exposes an injectable factory for owned stats connections outside Stats Application, proving default raw `SSHClient()` creation has moved out of `ServerStatsCollector`.

- [x] **Step 3: Run RED tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests ENABLE_DEBUG_DYLIB=NO
```

Expected before implementation: FAIL because RemoteFiles still has hidden TerminalSessions singleton defaults and Stats does not yet expose the owned-connection factory boundary needed to move default raw `SSHClient()` creation out of Stats Application.

RED result: `xcodebuild test ... -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests ENABLE_DEBUG_DYLIB=NO` failed to build because `StatsConnectionProvider` and `ServerStatsCollector(connectionProvider:)` did not exist. The RemoteFiles RED test was also in place to prove default `SSHSFTPAdapter` must not consult TerminalSessions singletons.

- [x] **Step 4: Introduce explicit lease provider boundary**

Add the narrow provider type in Core SSH or the consuming feature boundary. Inject the app-level provider from `VVTermApp.makeRemoteFileBrowserStore()` and Stats screen composition. Remove RemoteFiles infrastructure default access to TerminalSessions singletons.

- [x] **Step 5: Move Stats raw SSH fallback behind factory**

Make `ServerStatsCollector` depend on an injected connection factory/provider for owned leases. Keep the default factory in infrastructure/composition-level code, not in Stats Application policy, and keep collection code operating on `RemoteCommandExecuting`. Remove the Stats Application default that directly constructs `SSHClient()`, and move any SSH-specific `SSHConnectionOperationService` setup behind the injected owned-connection boundary.

- [x] **Step 6: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

GREEN result: focused `xcodebuild test` passed 17 Swift Testing tests across `SSHSFTPAdapterTests`, `RemoteFileBrowserStoreTests`, and `ServerStatsCollectorLifecycleTests`.

- [x] **Step 7: API and boundary cleanup**

Verify RemoteFiles Application/UI depends on RemoteFiles abstractions, not TerminalSessions singletons. Verify Stats Application does not cast `RemoteConnectionLeaseClient` to `SSHClient`. Verify production defaults live at composition or infrastructure boundaries.

- [x] **Step 8: Request review and commit**

```bash
git add VVTerm/Core/SSH/RemoteConnectionLease.swift VVTerm/Features/RemoteFiles/Infrastructure/SSHSFTPAdapter.swift VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift VVTerm/Features/Stats/Application/ServerStatsCollector.swift VVTerm/Features/Stats/Infrastructure/StatsSSHConnectionProvider.swift VVTerm/App/VVTermApp.swift VVTerm/App/iOS/iOSContentView.swift VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift VVTermTests/Features/RemoteFiles/SSHSFTPAdapterTests.swift VVTermTests/Features/Stats/ServerStatsCollectorLifecycleTests.swift docs/refactor-swift-best-practice.md
git commit -m "refactor: inject remote lease providers"
```

## Task 31: Terminal Runtime Ownership Final Cutover

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRuntime.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRegistry.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalSurfaceTeardownTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `TerminalConnectionRuntime`
  - `TerminalConnectionRegistry`
  - existing generation guards for shell registration.
- Produces:
  - Runtime/client factory ownership centralized through `TerminalConnectionRuntime` or a single runtime factory.
  - Stored runner tasks whose cancellation/finish ordering is explicit and tested.

- [x] **Step 1: Add RED stale-runner callback test**

Add a test that starts a runtime runner, closes or reconnects the same entity before the runner finishes, and asserts late callbacks cannot update state or register a shell for the old generation.

- [x] **Step 2: Add RED runtime factory ownership test**

Add a test proving session and pane managers can use an injected runtime/client factory rather than constructing raw `SSHClient()` directly in manager-local runtime state.

- [x] **Step 3: Run RED tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 4: Move raw client construction behind runtime factory**

Replace manager-local `SSHClient()` construction with an injected runtime/client factory. Keep runtime identity, shell id, shell task, and cleanup state under one owner per session or pane.

- [x] **Step 5: Make runner cancellation/finish ordering explicit**

Ensure canceling a stored runner task either awaits its finish path or routes all late callbacks through generation checks that cannot mutate closed/replaced runtime state. Keep teardown idempotent.

- [x] **Step 6: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalSurfaceTeardownTests -only-testing:VVTermTests/RemoteTerminalBootstrapTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 7: API and boundary cleanup**

Verify TerminalSessions Application has one runtime owner per terminal entity; `sharedStatsLease`, `remoteConnectionLease`, resize, retry, and close decisions use registry/runtime state rather than stale domain snapshots.

- [x] **Step 8: Request review and commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TerminalConnectionRuntime.swift VVTerm/Features/TerminalSessions/Application/TerminalConnectionRegistry.swift VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTermTests/ConnectionLifecycleIntegrationTests.swift VVTermTests/Features/TerminalSessions/TerminalSurfaceTeardownTests.swift docs/refactor-swift-best-practice.md
git commit -m "refactor: centralize terminal runtime ownership"
```

## Task 32: TerminalConnectionRunner Surface Protocol Boundary

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalSurfaceRegistry.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalConnectionRunnerTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalSurfaceTeardownTests.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Task 31 centralized runtime ownership.
  - Existing terminal surface attach/detach behavior.
- Produces:
  - A small terminal surface I/O protocol owned by TerminalSessions Application.
  - `TerminalConnectionRunner` no longer depends on concrete `GhosttyTerminalView`.

- [x] **Step 1: Add RED runner surface-boundary tests**

Add tests that run `TerminalConnectionRunner` with a fake terminal surface and assert it reads terminal size, writes stream data, and reports process exit without requiring `GhosttyTerminalView`.

- [x] **Step 2: Run RED tests**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalConnectionRunnerTests ENABLE_DEBUG_DYLIB=NO
```

RED result: failed before implementation because `TerminalConnectionSurface`, `TerminalConnectionSurfaceSize`, and the surface-oriented runner overload did not exist, and the only available `TerminalConnectionRunner.run` still required `GhosttyTerminalView`.

- [x] **Step 3: Introduce terminal surface I/O protocol**

Define a protocol with only the operations the runner needs: terminal size, stream data handling, external exit notification, and identity checks required by generation guards. Adapt `GhosttyTerminalView` at the boundary rather than passing it through the runner API.

- [x] **Step 4: Update managers to pass the protocol boundary**

`ConnectionSessionManager` and `TerminalTabManager` should attach concrete surfaces at the UI/application boundary and pass the protocol abstraction into the runner. SwiftUI representables remain surface owners only, not SSH lifecycle owners.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalSurfaceTeardownTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalConnectionRunnerTests -only-testing:VVTermTests/RemoteTerminalBootstrapTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

GREEN result: focused `xcodebuild test` succeeded; `ConnectionLifecycleIntegrationTests`, `RemoteTerminalBootstrapTests`, `TerminalSurfaceTeardownTests`, and `TerminalConnectionRunnerTests` all completed with 0 failures. `git diff --check` passed.

- [x] **Step 6: API and boundary cleanup**

Verify `TerminalConnectionRunner.swift` imports no UI-specific terminal type and that UI lifecycle callbacks still only attach/detach surfaces or send manager intent.

- [x] **Step 7: Request review and commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TerminalConnectionRunner.swift VVTerm/Features/TerminalSessions/Application/TerminalSurfaceRegistry.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTermTests/Features/TerminalSessions/TerminalConnectionRunnerTests.swift docs/refactor-swift-best-practice.md
git commit -m "refactor: decouple terminal runner from UI surface"
```

## Task 33: Repo-Wide Swift Test Context Sweep

**Files:**
- Modify: every `VVTermTests/**/*.swift` file missing the required `Test Context` header.
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Global test documentation rule from `docs/engineering/swift-best-practices.md`.
  - Existing unit tests and feature boundaries.
- Produces:
  - Every Swift unit test file has a clear `Test Context` comment describing protected behavior, target invariant, fake assumptions, and when failures should be treated as intended behavior updates rather than regressions.

- [x] **Step 1: Add RED repo-wide test-context scan**

Run a scan that lists Swift test files lacking `Test Context`. This should fail before the sweep because older test files predate the rule.

```bash
for f in $(rg --files VVTermTests -g '*.swift'); do if ! rg -q "Test Context" "$f"; then echo "$f"; fi; done
```

- [x] **Step 2: Add missing Test Context headers**

Add concise file-level context headers to every reported Swift test file. Do not change test assertions or product behavior in this task.

- [x] **Step 3: Run GREEN test-context scan**

```bash
for f in $(rg --files VVTermTests -g '*.swift'); do if ! rg -q "Test Context" "$f"; then echo "$f"; fi; done
```

Expected after implementation: no output.

- [x] **Step 4: Run compile verification**

```bash
git diff --check
xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 5: API and boundary cleanup**

Verify the task only adds test documentation comments, does not alter production behavior, and does not introduce temporary helpers or new test seams.

- [x] **Step 6: Request review and commit**

```bash
git add VVTermTests docs/refactor-swift-best-practice.md
git commit -m "test: document Swift test contexts"
```

## Task 34: Final Verification Failure Cleanup

**Files:**
- Modify: `VVTerm/Core/SSH/SSHPublicKeyDeriver.swift`
- Modify: `VVTerm/Core/SSH/SSHKeyGenerator.swift`
- Modify: `VVTermTests/SSHPublicKeyDeriverTests.swift`
- Modify: `VVTermTests/Features/TerminalAccessories/TerminalAccessoryProfileTests.swift`
- Modify: `VVTermTests/Features/RemoteFiles/RemoteFilePermissionTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Final full-suite iOS unit test output after Task 33.
  - Terminal accessory normalization spec in `docs/specs/terminal-accessory-customization.md`.
  - Existing PKCS#1 RSA public-key derivation contract.
- Produces:
  - Final verification failures are either corrected as stale test expectations or fixed at the production boundary that failed.
  - PKCS#1 RSA public-key derivation no longer depends on Security.framework importing a private key.

- [x] **Step 1: Capture RED final verification failures**

Run the full iOS unit suite and record the failing tests before changing code.

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 2: Identify root causes**

Classify each failure before editing:
- Terminal accessory profile tests had stale expectations; the spec says normalization restores defaults when active items fall below the minimum.
- Remote file permission draft expected `0740` after explicitly clearing group read from `0640`; the correct result is `0700`.
- PKCS#1 RSA public-key derivation crashed the app-hosted test process through the Security.framework private-key import path and then exposed a Data-slice indexing trap while replacing it.

- [x] **Step 3: Fix the minimal boundaries**

Update stale test expectations and replace PKCS#1 RSA derivation with pure Swift ASN.1 parsing of the private key's modulus/exponent.

- [x] **Step 4: Run focused GREEN verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalAccessoryProfileTests -only-testing:VVTermTests/RemoteFilePermissionTests -only-testing:VVTermTests/SSHPublicKeyDeriverTests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 5: Re-run final verification**

```bash
git diff --check
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

Result: `git diff --check` passed; final iOS unit verification passed with 104 XCTest tests and 282 Swift Testing tests in 46 suites.

- [x] **Step 6: Review and commit**

```bash
git add VVTerm/Core/SSH/SSHPublicKeyDeriver.swift VVTerm/Core/SSH/SSHKeyGenerator.swift VVTermTests/SSHPublicKeyDeriverTests.swift VVTermTests/Features/TerminalAccessories/TerminalAccessoryProfileTests.swift VVTermTests/Features/RemoteFiles/RemoteFilePermissionTests.swift docs/refactor-swift-best-practice.md
git commit -m "fix: stabilize RSA public key derivation"
```

## Task 35: Final Teardown Wait Hang Cleanup

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Full iOS unit test run after Task 34.
  - Existing `ConnectionLifecycleIntegrationTests.connectionManagerDisconnectServerLeavesOtherServersConnected()` coverage.
- Produces:
  - Completed server teardown tasks are removed by the waiter after `await task.value`, so a main-actor wait loop cannot starve the cleanup task responsible for removing the same entry.

- [x] **Step 1: Capture RED hang evidence**

Full-suite verification repeatedly hung in `ConnectionLifecycleIntegrationTests.connectionManagerDisconnectServerLeavesOtherServersConnected()` with a permanent `Open waiting for tab teardown cleanup` loop after `Tracking server teardown` for a session that had no shell cancel handler.

- [x] **Step 2: Identify root cause**

`waitForServerTeardownTasks` awaited completed tasks but left dictionary removal to a separate `@MainActor Task`; when the waiter immediately looped on the main actor, it could starve the cleanup task and keep seeing the already-completed entry forever.

- [x] **Step 3: Fix the waiter**

Remove each tracked teardown entry synchronously after the waiter observes `task.value`, while keeping the existing cleanup task idempotent for callers that do not explicitly wait.

- [x] **Step 4: Verify lifecycle and final suite**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

Result: lifecycle focused verification passed 55 Swift Testing tests; final iOS unit verification passed with 104 XCTest tests and 282 Swift Testing tests in 46 suites.

- [x] **Step 5: Review and commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift docs/refactor-swift-best-practice.md
git commit -m "fix: clear completed teardown waits synchronously"
```

## Task 36: Await Terminal Runner Finish on Close

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalConnectionRuntime.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `closeSessionAndWait(_:)`
  - `TerminalTabManager.closePaneAndWait(_:)`
  - `TerminalConnectionRuntime.cancelRunner()`
  - `TerminalConnectionRuntime.close()`
  - manager-owned runner task storage.
- Produces:
  - Awaitable close paths that do not return until the stored runner task and its main-actor finish path have completed or been explicitly classified as impossible to await.
  - A corrected Progress Ledger statement for Task 31: any remaining manager/runtime bridge state must be named and tested rather than claimed gone.

- [x] **Step 1: Add RED runner-close ordering tests**

Add tests proving `closeSessionAndWait(_:)` and `closePaneAndWait(_:)` wait for a delayed production runner cleanup path before returning. The test should fail because current close paths cancel/drop the stored runner task rather than awaiting its completion.

- [x] **Step 2: Run RED verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalConnectionRuntimeTests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 3: Make runner cancellation awaitable**

Move runner-task cancellation/finish ordering behind the runtime owner or expose an explicit awaitable manager path. Any nested main-actor cleanup scheduled from a runner `defer` must complete before close-and-wait reports completion.

- [x] **Step 4: Reconcile runtime ownership ledger**

Update Task 31 ledger wording so it does not overclaim that managers no longer own raw SSH client, shell id, or runner task bridge state unless the code now proves that. Remaining bridge state must be documented as a temporary boundary with an invariant and follow-up task.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalConnectionRuntimeTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 6: API and boundary cleanup**

Verify close/reconnect APIs name side effects clearly, no stored runner task is dropped before its finish path is observed, and same-server reopen waits for prior runner teardown through existing server teardown gates.

- [x] **Step 7: Request review and commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TerminalConnectionRuntime.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTermTests/ConnectionLifecycleIntegrationTests.swift VVTermTests/Features/TerminalSessions/TerminalConnectionRuntimeTests.swift docs/refactor-swift-best-practice.md
git commit -m "fix: await terminal runner finish on close"
```

## Task 37: Move Terminal Reconnect Orchestration Out of SwiftUI

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/IOSTerminalViewPolicyTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `TerminalAutoReconnectPolicy`
  - `TerminalManualReconnectPolicy`
  - `handleConnectWatchdogTimeout(...)`
  - known-host reset APIs
  - Mosh install/retry APIs.
- Produces:
  - SwiftUI terminal containers send one lifecycle intent for foreground/visibility/retry/retrust/install events.
  - Application-layer coordinators own credential loading, reconnect policy execution, watchdog timing, known-host reset, Mosh install sequencing, and retry state.

- [x] **Step 1: Add RED UI-intent boundary tests**

Add tests that prove root and split-pane reconnect/watchdog decisions can run from an application-layer API without constructing SwiftUI views. Include iOS foreground resume policy as a pure or manager-owned decision test.

- [x] **Step 2: Move root-session reconnect orchestration into Application**

Extract root terminal reconnect/watchdog/retrust/install sequencing from `TerminalContainerView` into `ConnectionSessionManager` or a narrow application coordinator. The view should call intent methods and render state only.

- [x] **Step 3: Move split-pane reconnect orchestration into Application**

Apply the same boundary to `TerminalView` and `TerminalTabManager`.

- [x] **Step 4: Move iOS foreground reconnect orchestration into Application**

`iOSContentView` should not decide whether to reconnect by combining scene phase, selected session, reconnect tokens, and terminal visibility. It should send foreground/selection intent to an application-layer API.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/IOSTerminalViewPolicyTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 6: API and boundary cleanup**

Verify SwiftUI lifecycle callbacks only attach/detach surfaces or send intent, and that application APIs expose clear side-effectful names.

- [x] **Step 7: Request review and commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift VVTerm/App/iOS/iOSContentView.swift VVTermTests/ConnectionLifecycleIntegrationTests.swift VVTermTests/IOSTerminalViewPolicyTests.swift docs/refactor-swift-best-practice.md
git commit -m "refactor: move terminal reconnect orchestration to application"
```

## Task 38: Await RemoteFiles Disconnect from iOS Server Flows

**Files:**
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift`
- Test: `VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `RemoteFileBrowserStore.disconnect(serverId:)`
  - iOS active-connection disconnect and server close flows.
- Produces:
  - iOS server/session disconnect flows either await returned RemoteFiles teardown tasks or the store internally tracks pending disconnects so later opens wait.

- [x] **Step 1: Add RED disconnect tracking test**

Add a RemoteFiles store test proving disconnect work is trackable/awaitable and that a later same-server operation waits for pending disconnect when the caller cannot await immediately.

- [x] **Step 2: Run RED verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests ENABLE_DEBUG_DYLIB=NO
```

- [x] **Step 3: Await or track iOS RemoteFiles disconnect**

Prefer awaiting returned disconnect tasks in iOS flows that already run inside async `Task`s. If a call site cannot await, move pending-disconnect tracking into the store and make later operations wait.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

- [x] **Step 5: API and boundary cleanup**

Verify RemoteFiles teardown is not dropped by iOS composition and no UI code directly closes SFTP resources.

- [x] **Step 6: Request review and commit**

```bash
git add VVTerm/App/iOS/iOSContentView.swift VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift docs/refactor-swift-best-practice.md
git commit -m "fix: await remote file disconnects on ios"
```

## Task 39: Tighten Core SSH Cancellation and Teardown Diagnostics

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift`
- Modify: `VVTerm/Core/SSH/LibSSH2SessionDriver.swift`
- Test: `VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `SSHClient.runWithTimeout(_:operation:onTimeout:)`
  - `SSHSession.disconnect()`
  - channel write retry loops
  - channel/SFTP teardown driver APIs.
- Produces:
  - Disconnect timeout abort happens from the timeout branch, not only after the timed-out operation returns.
  - Shell channel write retry loops check cancellation.
  - Close/free/shutdown failures either log raw driver operation/code/message consistently or are classified as accepted teardown diagnostics.

- [x] **Step 1: Classify disconnect timeout abort coverage**

Add a fake-driver or injectable-session test proving disconnect timeout triggers abort while teardown is still blocked.

Accepted scope decision: Task 39 does not add a direct private-helper test for `SSHClient.disconnectSSHSession(_:)`. That helper is private actor orchestration with no injectable session seam today; adding a test-only seam just for this assertion would widen the Core SSH API surface without improving production ownership. The production fix uses the existing `SSHClient.runWithTimeout(_:operation:onTimeout:)` hook, covered by `LibSSH2SessionLifecycleTests.testTimeoutAbortClosesSocketDuringBlockingHandshake`. Add a direct disconnect test when Core SSH grows an internal lifecycle helper seam for production reasons.

- [x] **Step 2: Add RED shell write cancellation test**

Add a test for repeated `LIBSSH2_ERROR_EAGAIN` write results that cancels the write task and expects cancellation instead of indefinite retry.

- [x] **Step 3: Run RED verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests ENABLE_DEBUG_DYLIB=NO
```

RED evidence: `LibSSH2SessionLifecycleTests.testShellWriteEAGAINLoopStopsWhenTaskIsCancelled` failed with `Expected cancelled shell write to throw CancellationError` before the write retry loop checked cancellation.

- [x] **Step 4: Implement cancellation and timeout fixes**

Use the existing timeout `onTimeout` hook or an equivalent structured boundary for disconnect abort. Add cancellation checks to channel write retry loops without changing successful write semantics.

- [x] **Step 5: Tighten teardown diagnostics or classify exemption**

Prefer raw `LibSSH2RawError` logging for close/free/shutdown failures where a session pointer is available. If the raw message cannot be queried safely, document the owner and invariant in the Progress Ledger.

- [x] **Step 6: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/LibSSH2SessionLifecycleTests -only-testing:VVTermTests/SSHErrorRetryableTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

Focused test evidence: `LibSSH2SessionLifecycleTests` passed 12 XCTest tests and `SSHErrorRetryableTests` passed 6 Swift Testing tests with the command above.

Review-fix evidence: after review found upload close/free teardown still collapsed or discarded raw diagnostics, `LibSSH2SessionLifecycleTests.testExecUploadCloseFailurePreservesRawLibSSH2Error` failed RED with `Expected SSHError.libssh2, got socketError("SCP close failed: -7")`, and `testExecUploadFreeFailureQueriesRawLibSSH2Error` failed RED because `.channelFree` was never queried. Both passed GREEN after `finishUploadChannel(_:)` preserved raw close errors and logged raw free errors.

- [x] **Step 7: API and boundary cleanup**

Verify Core SSH remains the only low-level owner of libssh2 teardown, unsafe pointer lifetimes stay local, and cancellation is not surfaced as a user-facing authentication/network failure.

Review note: no UI/application boundary changes were introduced; SSHClient/SSHSession remain the Core SSH lifecycle owners, raw C pointers stay inside `SSHSession`, and cancellation now leaves the write path as `CancellationError` rather than being translated to auth/network errors.

- [x] **Step 8: Request review and commit**

```bash
git add VVTerm/Core/SSH/SSHClient.swift VVTerm/Core/SSH/LibSSH2SessionDriver.swift VVTermTests/Core/SSH/LibSSH2SessionLifecycleTests.swift docs/refactor-swift-best-practice.md
git commit -m "fix: tighten ssh teardown cancellation"
```

Review result: initial review found upload close/free teardown diagnostics still incomplete and direct disconnect helper coverage ambiguous. Follow-up fixes added upload close/free RED/GREEN coverage, preserved raw close failures, logged raw free failures, and explicitly classified the direct private-helper disconnect test as accepted seam debt. Re-review found no Critical or Important issues.

## Task 40: Cross-Feature Lifecycle Ownership Sweep

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`
- Modify: `VVTerm/App/VVTermApp.swift`
- Modify: `VVTerm/Core/Sync/CloudKitSyncCoordinator.swift`
- Modify: `VVTerm/Features/VoiceInput/Application/*` or create application owner if needed.
- Modify: `VVTerm/Features/Settings/UI/AboutView.swift`
- Modify: `VVTerm/Features/Store/UI/ProUpgradeSheet.swift`
- Test: targeted tests for each touched feature.
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Server metadata and Keychain save/delete APIs.
  - CloudKit foreground/notification/settings sync paths.
  - Voice model download/cancel APIs.
  - AppKit window presentation helpers.
- Produces:
  - Server edit save is one application-layer operation that keeps metadata and credentials consistent.
  - Destructive server/workspace/environment UI actions report or track lifecycle task results.
  - Sync work is serialized/tracked by an app/application coordinator.
  - Voice model downloads are owned by an application/service object, not a leaf settings view.
  - AppKit singleton windows live in Application-style managers, not UI views.

- [x] **Step 1: Split this sweep into reviewable sub-tasks**

Before editing, break this broad sweep into smaller Tasks if more than one feature requires production changes. Each sub-task must have its own RED/GREEN tests and commit boundary.

Sub-task split:
- Task 40A: Server edit credential consistency. Move edit metadata+credential save into `ServerManager`, keep UI as intent sender, and test credential failure does not mutate server metadata.
- Task 40B: Sync task ownership. Audit app foreground/background/settings sync calls and move lifecycle-critical task tracking into an app/application coordinator if current calls are untracked.
- Task 40C: Voice model download ownership. Move download/cancel ownership out of leaf settings UI if the current flow starts or drops critical `URLSession` tasks from views.
- Task 40D: AppKit window presentation ownership. Move singleton window lifetime helpers out of UI views if scan confirms UI-owned long-lived windows.
- Task 40E: Remaining destructive action tracking. Audit delete/save flows not covered by 40A-40D and add focused tests for any dropped lifecycle result.
  - Task 40E1: Servers server/workspace deletion intent. Move synchronous UI deletion entry points to an application-layer tracked request API.
  - Task 40E2: Servers environment deletion intent. Classify and fix remaining environment delete `try?` paths if they drop lifecycle failures.
  - Task 40E3: Settings destructive/persistence actions. Classify Keychain, generated-key save/delete, and trusted-host reset flows.
    - Task 40E3a: Trusted-host reset ownership. Move known-host refresh/reset task ownership out of `TerminalSettingsView`.
    - Task 40E3b/c: Reusable SSH key library ownership. Move stored-key import/delete and generated-key persistence out of `KeychainSettingsView` into Settings Application.
  - Task 40E4: RemoteFiles mutation ownership. Classify remote batch delete and preview-save flows that still start mutation tasks from UI.
    - Task 40E4a: Browser mutation helper ownership. Move create folder, rename, move, delete, and permission-change request task ownership out of `RemoteFileBrowserScreen`.
    - Task 40E4b: Preview-save ownership. Classify edited preview save paths and move any lifecycle-critical save tasks out of UI.
    - Task 40E4c: Transfer/drop ownership. Classify upload/download/drop/file-promise transfer tasks and keep only application-layer tracked work for lifecycle-critical mutations.
  - Task 40E5: TerminalThemes persistence/sync failures. Classify swallowed local persistence and untracked sync push results.

- [x] **Step 2: Run boundary scans**

```bash
rg -n "try\\?|Task \\{|Task\\.detached|URLSession|NSWindow|save|delete|sync" VVTerm/App VVTerm/Core VVTerm/Features -g '*.swift'
```

Scan result: Task 40A selected server edit credential consistency as the first slice. Task 40B then selected AppDelegate/SyncSettingsView sync task ownership. Remaining scan hits stay assigned to later sub-tasks: Voice/URLSession download ownership for 40C, About/Pro AppKit window presenters for 40D, and remaining destructive save/delete flows for 40E.

- [x] **Step 3: Implement the first selected cross-feature sub-task with TDD**

Start with the highest-risk lifecycle-critical operation found by the scan, likely Server edit credential consistency or sync task tracking.

Task 40A RED evidence: `ServerManagerBootstrapTests.updateServerWithCredentialsDoesNotMutateMetadataWhenCredentialStoreFails` failed to compile before `ServerManager` exposed a credential-store seam and `updateServer(_:credentials:)`.

Task 40A GREEN evidence: `ServerManagerBootstrapTests` passed 11 Swift Testing tests after `ServerManager` owned edit credential+metadata ordering and `ServerFormSheet.saveServer()` stopped writing Keychain directly during edit saves. The first single-test filter run matched 0 tests and is not counted as GREEN evidence.

Task 40B RED evidence: `AppSyncCoordinatorTests` failed to compile because `AppSyncCoordinator` and `ServerRefreshReason` did not exist.

Task 40B GREEN evidence: `AppSyncCoordinatorTests` passed 5 Swift Testing tests after adding app-layer sync task ownership, coalesced server refresh tracking, remote-notification completion waiting, settings enable ordering, settings-owned post-toggle reload after an existing foreground refresh, and cancellation of stale settings enable work when a later disable intent arrives.

Task 40C RED evidence: `VoiceModelDownloadStoreTests` first failed to compile because `VoiceModelDownloadStore` did not exist, proving voice model download task ownership was still missing from the application layer. The strengthened cancellation RED then failed because canceling a tracked download did not clear the task early enough for immediate retry to start fresh work.

Task 40C GREEN evidence: `VoiceModelDownloadStoreTests` passed 2 Swift Testing tests after adding `VoiceModelDownloadStore` as the application-layer owner for voice model managers and tracked download tasks by model kind.

Task 40D RED evidence: `AppKitWindowOwnershipBoundaryTests.singletonWindowPresentersLiveInApplicationLayer` failed with 4 Swift Testing issues because `AboutView.swift` still declared `AboutWindowController`, `ProUpgradeSheet.swift` still declared `ProUpgradeWindowPresenter`, and the expected Application-layer presenter files did not exist.

Task 40D GREEN evidence: `AppKitWindowOwnershipBoundaryTests.singletonWindowPresentersLiveInApplicationLayer` passed 1 Swift Testing test after moving About and Pro upgrade singleton `NSWindow` ownership into Application-layer presenters.

Task 40E1 RED evidence: `ServerManagerBootstrapTests.workspaceDeletionIntentTracksFailureInsteadOfDroppingResult` failed to compile before `ServerManager` exposed tracked deletion request APIs, pending request IDs, awaitable request waiting, and captured deletion failure state. `ServerDeletionIntentBoundaryTests.serverAndWorkspaceDeletionUIUsesApplicationIntentRequests` then failed with 2 Swift Testing issues because server/workspace UI still swallowed delete failures through `try? await ...deleteServer/deleteWorkspace` in untracked tasks.

Task 40E1 GREEN evidence: `ServerManagerBootstrapTests` passed 12 Swift Testing tests after `ServerManager` owned user-initiated server/workspace deletion requests and captured failures. `ServerDeletionIntentBoundaryTests` passed 1 Swift Testing test after shared/iOS server rows and workspace deletion UI switched to `requestServerDeletion` and `requestWorkspaceDeletion`.

Task 40E2 RED evidence: `ServerManagerBootstrapTests.environmentDeletionIntentTracksRequestAndRunsSuccessAfterApplicationDelete` failed to compile before `ServerManager` exposed `requestEnvironmentDeletion`. The expanded deletion boundary test also covered macOS/iOS environment deletion UI, which still launched `Task { try? await serverManager.deleteEnvironment(...) }` before the production change.

Task 40E2 GREEN evidence: `ServerManagerBootstrapTests` and `ServerDeletionIntentBoundaryTests` passed 14 Swift Testing tests after environment deletion intent moved to `ServerManager.requestEnvironmentDeletion`, and macOS/iOS environment deletion UI stopped swallowing `deleteEnvironment` failures.

Task 40E3a RED evidence: `TrustedHostsSettingsStoreTests.resetTrustedHostsTracksTaskAndRefreshesCount` and `SettingsLifecycleBoundaryTests.terminalSettingsDelegatesTrustedHostCleanupToApplicationStore` first failed to compile because `TrustedHostsSettingsStore` did not exist and `TerminalSettingsView` still owned `knownHostsTask` while calling `KnownHostsStore.shared` directly. The strengthened ordering RED, `TrustedHostsSettingsStoreTests.staleRefreshCannotOverwriteLaterResetCount`, then failed because there was no `KnownHostsStoring` seam and the Settings store accepted only concrete `KnownHostsStore`.

Task 40E3a GREEN evidence: `TrustedHostsSettingsStoreTests` and `SettingsLifecycleBoundaryTests` passed 3 Swift Testing tests after `TrustedHostsSettingsStore` became the Settings application-layer owner for trusted-host refresh/reset tasks, exposed awaitable request tracking, delegated persistence to a `KnownHostsStoring` boundary, and guarded count updates so stale refresh completions cannot overwrite a later reset.

Task 40E3b/c RED evidence: `SSHKeySettingsStoreTests` first failed to compile because `SSHKeySettingsStore`, `SSHKeyLibrary`, and `SSHKeyPairGenerating` did not exist. `SettingsLifecycleBoundaryTests.keychainSettingsDelegatesSSHKeyLibraryLifecycleToApplicationStore` also guarded the source boundary where `KeychainSettingsView` called `KeychainManager.shared`, `SSHKeyGenerator.generate`, and owned generation `Task {}` state directly.

Task 40E3b/c GREEN evidence: `SSHKeySettingsStoreTests` and `SettingsLifecycleBoundaryTests` passed 6 Swift Testing tests after `SSHKeySettingsStore` became the Settings application-layer owner for reusable SSH key import, delete, and generated-key persistence. The store delegates Keychain operations through `SSHKeyLibrary`, delegates key generation through `SSHKeyPairGenerating`, tracks generation tasks by request ID, and exposes an awaitable test hook for generated-key save ordering.

Task 40E4a RED evidence: `RemoteFileBrowserStoreTests.mutationRequestTracksTaskAndRunsSuccessAfterOperation` and `mutationRequestTracksFailureAndSkipsSuccessContinuation` first failed to compile because `RemoteFileBrowserStore` did not expose an application-layer mutation request API, pending request IDs, or awaitable request waiting. `RemoteFileMutationIntentBoundaryTests.browserScreenDelegatesMutationTaskOwnershipToStore` also covered the source boundary where `RemoteFileBrowserScreen.performOperation` wrapped arbitrary mutations in UI-owned `Task {}` blocks.

Task 40E4a GREEN evidence: `RemoteFileBrowserStoreTests` and `RemoteFileMutationIntentBoundaryTests` passed 9 Swift Testing tests after `RemoteFileBrowserStore` became the tracked owner for browser mutation request tasks, and `RemoteFileBrowserScreen.performOperation` delegated create folder, rename, move, delete, and permission-change mutation lifecycle to `browser.requestMutation(...)`.

Task 40E4b RED evidence: `RemoteFilePreviewCoordinatorTests.textPreviewSaveRequestTracksUploadAndRunsSuccessAfterStoreSave` first failed to compile because `RemoteFileBrowserStore` did not expose `requestTextPreviewSave`. `RemoteFileMutationIntentBoundaryTests.previewTextSaveDelegatesTaskOwnershipToStore` also covered the source boundary where `RemoteFileInspectorView` wrapped edited preview saves in a UI-owned `Task` and platform preview containers called `try await browser.saveTextPreview(...)` directly.

Task 40E4b GREEN evidence: `RemoteFilePreviewCoordinatorTests` and `RemoteFileMutationIntentBoundaryTests` passed 4 Swift Testing tests after `RemoteFileBrowserStore.requestTextPreviewSave(...)` reused the tracked mutation registry for edited preview saves, and macOS/iOS preview UI sent synchronous save intent through `RemoteFileTextSaveRequest` instead of owning the save task.

Task 40E4c RED evidence: `RemoteFileBrowserStoreTests.transferRequestTracksTaskProgressAndSuccessAfterOperation` first failed to compile because `RemoteFileBrowserStore` did not expose transfer request tracking APIs (`requestTransfer`, `pendingTransferRequestIDs`, and `waitForTransferRequest`). `RemoteFileMutationIntentBoundaryTests.transferAndDropDelegatesTaskOwnershipToStore` also covered the source boundary where `RemoteFileBrowserScreen.performTransfer`, upload planning, remote drag file representations, and macOS file promises owned transfer/download tasks from UI or platform support code.

Task 40E4c GREEN evidence: `RemoteFileBrowserStoreTests` and `RemoteFileMutationIntentBoundaryTests` passed 12 Swift Testing tests after `RemoteFileBrowserStore.requestTransfer(...)` became the tracked owner for transfer request tasks, `RemoteFileBrowserScreen.performTransfer` delegated upload/download/drop transfer lifecycle to the store, local drop URL loading and upload planning ran inside the tracked transfer operation, and macOS file-promise export completion delegated download work to store-owned transfer requests.

Task 40E5 RED evidence: `TerminalThemeManagerLifecycleTests` first failed to compile because `TerminalThemeManager` did not expose injectable custom-theme persistence/cloud seams, pending CloudKit sync request IDs, or `waitForCloudSyncRequest(_:)`, and `deleteCustomTheme(id:)` was non-throwing. The added Settings boundary test also covered the source rule that custom theme deletion must remain a throwing intent instead of swallowing persistence failures in UI.

Task 40E5 GREEN evidence: `TerminalThemeManagerLifecycleTests`, `TerminalThemeValidationTests`, `TerminalThemeStoragePathsTests`, and `SettingsLifecycleBoundaryTests` passed 9 Swift Testing tests plus 4 XCTest tests after `TerminalThemeManager` became the tracked application-layer owner for custom theme persistence and CloudKit push tasks, create/update/delete published local state only after persistence succeeded, foreground sync routed through tracked sync requests, concrete UserDefaults persistence stopped committing defaults before file sync succeeds, and Settings custom-theme delete UI surfaced thrown persistence errors.

- [x] **Step 4: Run focused verification**

Run feature-specific tests plus `git diff --check`.

Verification evidence for Task 40A:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests ENABLE_DEBUG_DYLIB=NO` passed 11 Swift Testing tests.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.

Verification evidence for Task 40B:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppSyncCoordinatorTests ENABLE_DEBUG_DYLIB=NO` passed 5 Swift Testing tests.
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppSyncCoordinatorTests -only-testing:VVTermTests/ServerManagerBootstrapTests ENABLE_DEBUG_DYLIB=NO` passed 16 Swift Testing tests.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.

Verification evidence for Task 40C:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/VoiceModelDownloadStoreTests -only-testing:VVTermTests/TranscriptionSettingsStoreTests -only-testing:VVTermTests/MLXModelCatalogTests ENABLE_DEBUG_DYLIB=NO` passed 8 XCTest tests plus 2 Swift Testing tests.

Verification evidence for Task 40D:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppKitWindowOwnershipBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 1 Swift Testing test.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed after the unsigned macOS build was rerun with signing disabled.

Verification evidence for Task 40E1:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/ServerDeletionIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 13 Swift Testing tests.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation warnings.

Verification evidence for Task 40E2:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/ServerDeletionIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 14 Swift Testing tests.
- `rg -n "try\\? await serverManager\\.deleteEnvironment" VVTerm/App/iOS/iOSContentView.swift VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift` produced no matches.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation warnings.

Verification evidence for Task 40E3a:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TrustedHostsSettingsStoreTests -only-testing:VVTermTests/SettingsLifecycleBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 3 Swift Testing tests.
- `rg -n "KnownHostsStore\\.shared|knownHostsTask" VVTerm/Features/Settings/UI/TerminalSettingsView.swift` produced no matches.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation warnings.

Verification evidence for Task 40E3b/c:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/SSHKeySettingsStoreTests -only-testing:VVTermTests/SettingsLifecycleBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 6 Swift Testing tests.
- `rg -n "KeychainManager\\.shared|SSHKeyGenerator\\.generate|Task \\{" VVTerm/Features/Settings/UI/KeychainSettingsView.swift` produced no matches.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation and XCTest deployment warnings.

Verification evidence for Task 40E4a:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 9 Swift Testing tests.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation and XCTest deployment warnings.

Verification evidence for Task 40E4b:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFilePreviewCoordinatorTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 4 Swift Testing tests.
- `rg -n "Task \\{\\n\\s*await saveEditedText|private func saveEditedText\\(for entry: RemoteFileEntry\\) async|try await browser\\.saveTextPreview" VVTerm/Features/RemoteFiles -g '*.swift' -U` produced no matches.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation and XCTest deployment warnings.

Verification evidence for Task 40E4c:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` first failed to compile with missing `RemoteFileBrowserStore.requestTransfer`, `pendingTransferRequestIDs`, and `waitForTransferRequest`.
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 12 Swift Testing tests after the transfer request owner and UI delegation changes.
- `rg -n "Task \\{\\n\\s*do \\{\\n\\s*try await operation \\{ progress in|func beginUploadFlow\\(urls: \\[URL\\], to destinationPath: String, initialMessage: String\\) \\{\\n\\s*Task \\{|Task \\{\\n\\s*do \\{\\n\\s*let temporaryURL = try preparedTemporaryURL\\.get\\(\\)|Task \\{ @MainActor in\\n\\s*do \\{\\n\\s*try await export\\(entry, url\\)" VVTerm/Features/RemoteFiles -g '*.swift' -U` produced no matches.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation and XCTest deployment warnings.

Verification evidence for Task 40E5:
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalThemeManagerLifecycleTests ENABLE_DEBUG_DYLIB=NO` first failed to compile with missing `TerminalThemeCustomThemeStoring`, `TerminalThemeCloudStoring`, `TerminalThemeSyncCoordinating`, `pendingCloudSyncRequestIDs`, `waitForCloudSyncRequest(_:)`, a private initializer, and non-throwing delete.
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalThemeManagerLifecycleTests ENABLE_DEBUG_DYLIB=NO` passed 6 Swift Testing tests after the review fixes for concrete store partial writes and foreground sync request tracking.
- `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalThemeManagerLifecycleTests -only-testing:VVTermTests/TerminalThemeValidationTests -only-testing:VVTermTests/TerminalThemeStoragePathsTests -only-testing:VVTermTests/SettingsLifecycleBoundaryTests ENABLE_DEBUG_DYLIB=NO` passed 9 Swift Testing tests plus 4 XCTest tests.
- `rg -n "try\\? terminalThemeManager\\.deleteCustomTheme|try\\? .*saveThemes|syncCustomThemeFiles\\(|Task \\{ @MainActor \\[weak self\\]" VVTerm/Features/TerminalThemes/Application/TerminalThemeManager.swift VVTerm/Features/Settings/UI/TerminalSettingsView.swift` found no UI-swallowed custom-theme delete or swallowed `saveThemes` failure; remaining hits are the TerminalThemes application owner or custom-theme store internals.
- `git diff --check` passed.
- `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- `xcodebuild build-for-testing -quiet -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO` passed with existing Swift 6 isolation and XCTest deployment warnings; no TerminalThemeManager warning remained after removing a redundant await.

- [x] **Step 5: API and boundary cleanup**

Verify each feature keeps Domain/Application/Infrastructure/UI boundaries intact and that no UI owns critical long-lived resources.

Task 40A cleanup: server edit save now goes through `ServerManager.updateServer(_:credentials:)`, and `ServerFormSheet.saveServer()` no longer calls `storePassword`, `storeSSHKey`, `storeCloudflareServiceToken`, or `deleteCloudflareServiceToken` directly. Remaining `ServerFormSheet` Keychain reads/import helpers are outside the 40A save-consistency slice and should be classified separately before broader cleanup. Task 40 as a whole remains open for 40B-40E.

Task 40B cleanup: app launch, foreground, and remote notification sync intents now go through `AppSyncCoordinator`; `SyncSettingsView` sends recheck/toggle intent to the same application-layer owner instead of composing CloudKit/server/accessory work in SwiftUI. `CloudKitManager.handleSyncToggle(_:)` is now awaitable and cancellation-aware after account status checks, and subscription setup rechecks cancellation/sync-enabled state before treating existing subscriptions or saves as valid. Remaining `Task` hits in the scan are classified as existing app-lock/teardown paths, stored CloudKit fetch/zone tasks, or later Task 40C-40E candidates.

Task 40C cleanup: `TranscriptionSettingsView` now observes a stable `VoiceModelDownloadStore` and sends model selection, download, remove, and clear-storage intent to that application-layer owner. The view no longer creates `MLXModelManager` with `@StateObject` and no longer starts download tasks directly. `MLXModelManager` remains the infrastructure owner of `URLSession` and `URLSessionDownloadTask`, while `VoiceModelDownloadStore` tracks application-level download tasks by `MLXModelKind`, coalesces duplicate download intent, clears canceled tasks immediately for retry, and forwards cancellation to the manager. Review cleanup also guards URLSession delegate callbacks by current task identity so stale callbacks from a canceled download cannot mutate a newer retry. Remaining VoiceInput `Task.detached` hits are model inference/storage-size work outside the leaf settings download ownership slice. Task 40 remains open for AppKit window ownership and remaining destructive action tracking.

Task 40D cleanup: `AboutView` no longer declares or owns an AppKit window controller; the macOS About command sends show intent to `AboutWindowPresenter` in Settings Application. `ProUpgradeSheet` no longer declares or owns the Pro upgrade singleton `NSWindow`; `ProUpgradePresentationModifier` sends show/close intent to `ProUpgradeWindowPresenter` in Store Application, with `PaywallSource` presentation copy colocated in Store Application for both SwiftUI and AppKit chrome. `ProUpgradeWindowConfigurator` remains UI-scoped for configuring the attached sheet host window and owns no long-lived window. Boundary scan found About, Settings, and Pro upgrade `NSWindow` ownership only in Application files; remaining UI hits were UIKit appearance or non-window provider helpers outside the AppKit singleton-window slice. Task 40 remains open for remaining destructive action tracking.

Task 40E1 cleanup: `ServerManager` now owns user-initiated server/workspace deletion request tasks, exposes pending request IDs for awaitable ordering, captures `ServerDeletionFailure`, and runs success continuations only after the underlying awaitable delete operation succeeds. Shared macOS/iOS server row deletion and workspace deletion UI now send intent to `ServerManager` instead of starting `Task { try? await ... }` from SwiftUI. Remaining Task 40E candidates are environment deletion `try?` paths, Settings Keychain/trusted-host destructive actions, RemoteFiles batch delete/save mutations, and TerminalThemes persistence/sync failure handling.

Task 40E2 cleanup: `ServerManager.requestEnvironmentDeletion(_:in:fallback:onDeleted:)` now reuses the application-layer deletion request tracking path for environment deletes, including pending request waiting and `ServerDeletionFailure.Operation.deleteEnvironment` diagnostics. `ServerSidebarView` and `iOSContentView` now send environment deletion intent to `ServerManager`; their selection-state updates run in the success continuation after the environment is removed and affected servers are moved to the fallback environment. Remaining Task 40E candidates are Settings Keychain/trusted-host destructive actions, RemoteFiles batch delete/save mutations, and TerminalThemes persistence/sync failure handling.

Task 40E3a cleanup: `TerminalSettingsView` no longer owns known-host refresh/reset task state and no longer calls `KnownHostsStore.shared` directly. The view observes `TrustedHostsSettingsStore` and sends refresh/reset intent, while the Settings application store tracks request tasks, offers awaitable test hooks, and ensures only the latest trusted-host request updates `knownHostCount`. `KnownHostsStore` remains the Core SSH persistence actor behind the `KnownHostsStoring` boundary. Task 40E3 remains open for Keychain stored-key import/delete and generated-key save/delete ownership, and Task 40E remains open for RemoteFiles mutation tasks and TerminalThemes persistence/sync failure handling.

Task 40E3b/c cleanup: `KeychainSettingsView` no longer owns SSH key import/delete/generation persistence or calls `KeychainManager.shared` and `SSHKeyGenerator.generate` directly. The view observes `SSHKeySettingsStore.shared` and sends import/delete/generate intent; the Settings application store owns Keychain persistence through `SSHKeyLibrary` and tracks generated-key save tasks so tests and later operations can await completion. The reusable `AddSSHKeySheet` now receives the store explicitly from its caller, and `ServerFormSheet` passes the same shared application owner into that sheet while preserving the existing server-form selected-key behavior. Task 40E3 is complete; Task 40E remains open for RemoteFiles mutation tasks and TerminalThemes persistence/sync failure handling.

Task 40E4a cleanup: `RemoteFileBrowserScreen.performOperation` no longer owns generic browser mutation tasks. It now adapts UI-specific failure presentation and delegates lifecycle to `RemoteFileBrowserStore.requestMutation(...)`, while the store tracks pending mutation request IDs and exposes `waitForMutationRequest(_:)` for ordering tests. This covers create folder, rename, move, delete, and permission-change browser mutations that flow through the shared helper. Task 40E4 remains open for preview-save and transfer/drop/file-promise task ownership, and Task 40E remains open for TerminalThemes persistence/sync failure handling.

Task 40E4b cleanup: `RemoteFileInspectorView` no longer starts a `Task` for edited text preview saves. It sends a `RemoteFileTextSaveRequest` containing UI success/failure continuations to the platform container, while `RemoteFileBrowserStore.requestTextPreviewSave(...)` owns and tracks the actual async save through the existing mutation request registry. The lower-level `saveTextPreview` method remains the awaitable implementation for callers that already run inside application-owned async work. Task 40E4 remains open for transfer/drop/file-promise task ownership, and Task 40E remains open for TerminalThemes persistence/sync failure handling.

Task 40E4c cleanup: `RemoteFileBrowserStore.requestTransfer(...)` now mirrors the existing mutation request API for transfer lifecycle: it tracks request IDs, reports progress through application-owned task callbacks, and exposes `waitForTransferRequest(_:)` for ordering tests. `RemoteFileBrowserScreen.performTransfer` no longer starts the transfer `Task`; it keeps notice presentation state only. Upload selection, local drops, remote drops, drag file representation export, iOS export/share downloads, and macOS save-panel downloads now run their lifecycle-critical work inside tracked transfer requests. `FilePromiseDelegate` no longer awaits export work itself; it invokes the supplied application-layer completion bridge from its main operation queue. Task 40E4 is complete; Task 40E remains open for TerminalThemes persistence/sync failure handling.

Task 40E5 cleanup: `TerminalThemeManager` now owns custom-theme persistence through a `TerminalThemeCustomThemeStoring` boundary and owns CloudKit fetch/drain work through TerminalThemes application-layer protocols. Custom theme create, update, delete, and remote merge now attempt persistence before publishing `customThemes`; create/update/delete do not enqueue CloudKit work after local persistence failure. The concrete UserDefaults custom-theme store now syncs files before committing defaults, preventing a thrown file-sync failure from becoming durable metadata on next launch. CloudKit push/startup/foreground sync work is tracked in `pendingCloudSyncTasks` with `waitForCloudSyncRequest(_:)` for ordering tests. Settings custom-theme deletion remains synchronous UI intent, but the intent is throwing and surfaces errors through the existing custom-theme error alert instead of silently marking deletion successful. Task 40E is complete.

- [x] **Step 6: Request review and commit**

Commit each split sub-task atomically.

## Task 41: Terminal Open Intent Ownership

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/App/ContentView.swift`
- Modify: `VVTerm/Core/UI/SidebarComponents.swift`
- Modify: `VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabComponents.swift`
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Test: `VVTermTests/TerminalOpenIntentBoundaryTests.swift`
- Test: focused manager lifecycle tests if source-boundary tests expose missing request tracking.
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `TerminalTabManager.openTab(for:)`
  - `ConnectionSessionManager.openConnection(to:forceNew:)`
  - Existing open serialization and teardown wait gates.
- Produces:
  - Application-layer open request APIs that UI can call synchronously from buttons and menus.
  - Awaitable request IDs or equivalent failure state for tests and later operations.
  - UI call sites that send open intent instead of starting their own open `Task` and swallowing failures.

- [x] **Step 1: Add RED boundary tests**

Add `TerminalOpenIntentBoundaryTests` with a `Test Context` header. The tests must inspect the SwiftUI source files that currently open terminal tabs or iOS sessions and fail while UI still contains direct `try? await tabManager.openTab(...)`, `try? await sessionManager.openConnection(...)`, or a no-op catch for open failures.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalOpenIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the new boundary test fails because `ContentView`, `SidebarComponents`, `ServerSidebarView`, `ConnectionTabComponents`, and any remaining terminal-tab UI entry points still own open tasks or swallow open errors.

Actual RED result: `TerminalOpenIntentBoundaryTests` failed with 5 issues because UI sources still contained direct `tabManager.openTab`, direct `sessionManager.openConnection`, and the no-op open failure catch.

- [x] **Step 2: Add manager-owned open request APIs**

Add a narrow request API to `TerminalTabManager` and `ConnectionSessionManager` that starts and tracks user-initiated open work. The API should name the side effect clearly, for example `requestTabOpen(for:selectTerminalViewOnSuccess:onOpened:onFailed:)` and `requestConnectionOpen(to:forceNew:onOpened:onFailed:)`, or a smaller equivalent that matches existing manager style.

The owner must:
- Store pending open request tasks by request ID or server ID.
- Reuse the existing teardown wait and duplicate-open gate inside `openTab` / `openConnection`.
- Preserve cancellation separately from user-facing open failures where possible.
- Expose awaitable test hooks for request completion if production code starts the task internally.

- [x] **Step 3: Route UI open entry points through the request APIs**

Replace UI-owned open tasks in:
- `ContentView.connectToServer(_:)`
- `SidebarComponents`
- `ServerSidebarView.connectToServer(_:)`
- `ConnectionTabsView.openNewTab(selectTerminalViewOnSuccess:)`
- `ConnectionTabComponents.duplicateTab(_:)`
- iOS server-list and new-tab open flows where the view currently owns open orchestration.

UI may still update purely visual state such as selected view, pending spinner, alert flags, or navigation state in success/failure closures, but it must not own the lifecycle-critical open operation or discard the thrown result with `try?`.

- [x] **Step 4: Run focused verification**

Run the RED/GREEN boundary test plus the focused open lifecycle suites:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalOpenIntentBoundaryTests -only-testing:VVTermTests/ConnectionSessionManagerOpenTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
git diff --check
```

If runtime changes touch shared open ordering, also run iOS and macOS build-for-testing before review.

Actual GREEN result: `TerminalOpenIntentBoundaryTests`, `ConnectionSessionManagerOpenTests`, and `ConnectionLifecycleIntegrationTests` passed with 14 XCTest tests plus 79 Swift Testing tests after review fixes. `git diff --check` passed, iOS/macOS build-for-testing passed, and the terminal-open UI boundary scan produced no matches for swallowed direct opens or UI-side existing-tab bypasses.

- [x] **Step 5: API and boundary cleanup**

Before moving to another task, verify request API names are consistent between session and tab managers, UI files no longer contain swallowed terminal-open `try?`, duplicate open state is still one authoritative manager-owned source, and no temporary helper or stale "Next task" ledger note remains.

- [x] **Step 6: Request review and commit**

Request code review for Task 41. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 42: Store Purchase Intent Ownership

**Files:**
- Modify: `VVTerm/Features/Store/Application/StoreManager.swift`
- Modify: `VVTerm/Features/Store/UI/ProUpgradeSheet.swift`
- Modify: `VVTerm/Features/Settings/UI/ProSettingsView.swift`
- Test: `VVTermTests/Features/Store/StoreManagerLifecycleTests.swift`
- Test: `VVTermTests/StorePurchaseIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `StoreManager.purchase(_:)`
  - `StoreManager.restorePurchases()`
  - Existing `purchaseState` and `restoreState`.
- Produces:
  - Application-layer purchase and restore request APIs that UI can call synchronously from buttons.
  - Pending request IDs and awaitable request waits for tests and later ordering-sensitive operations.
  - UI call sites that send Store intent instead of starting untracked purchase/restore `Task` work.

- [x] **Step 1: Add RED tests**

Add `StorePurchaseIntentBoundaryTests` with a `Test Context` header. The tests must inspect Store and Settings UI source files and fail while UI still contains direct `Task { await storeManager.purchase(...) }` or `Task { await storeManager.restorePurchases() }`.

Add `StoreManagerLifecycleTests` with fake purchase/restore operations that avoid real StoreKit network calls. The tests must prove request IDs are tracked while operations are pending, completion can be awaited, and thrown fake failures are recorded by the Store application owner.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/StorePurchaseIntentBoundaryTests -only-testing:VVTermTests/StoreManagerLifecycleTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the boundary test fails because `ProUpgradeSheet` and `ProSettingsView` still start Store purchase/restore tasks from SwiftUI, and the lifecycle test fails to compile because Store request tracking APIs do not exist.

Actual RED result: `StorePurchaseIntentBoundaryTests` plus `StoreManagerLifecycleTests` failed before production changes because `StoreManager.makeForTesting()` did not exist. Review-fix RED later failed because `applyPurchaseErrorForTesting(_:)` and `applyRestoreErrorForTesting(_:)` did not exist, proving the cancellation regression tests exercised new behavior before implementation.

- [x] **Step 2: Add Store request APIs**

Add narrow request APIs to `StoreManager`, for example `requestPurchase(of:)` and `requestRestorePurchases()`, plus awaitable request waits. The owner must:
- Store pending purchase and restore tasks by request ID.
- Preserve cancellation separately from fake or operation failures.
- Record request-level failures for tests without changing the existing StoreKit user-facing state semantics.
- Keep real StoreKit purchase/restore behavior inside `purchase(_:)` and `restorePurchases()`.

- [x] **Step 3: Route UI Store entry points through request APIs**

Replace UI-owned Store tasks in:
- `ProUpgradeSheet` purchase button.
- `ProUpgradeSheet` restore button.
- `ProSettingsView` restore button.

UI may still present state derived from `purchaseState` and `restoreState`, but it must not own the lifecycle-critical purchase or restore operation.

- [x] **Step 4: Run focused verification**

Run the RED/GREEN Store lifecycle suite plus a Store UI boundary scan:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/StorePurchaseIntentBoundaryTests -only-testing:VVTermTests/StoreManagerLifecycleTests -only-testing:VVTermTests/Features/Store/StoreStateTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{ await storeManager\\.(purchase|restorePurchases)|storeManager\\.purchase\\(|storeManager\\.restorePurchases\\(" VVTerm/Features/Store/UI/ProUpgradeSheet.swift VVTerm/Features/Settings/UI/ProSettingsView.swift
git diff --check
```

If StoreManager changes touch app startup or StoreKit listener setup, also run iOS build-for-testing before review.

Focused GREEN result: `StorePurchaseIntentBoundaryTests` and `StoreManagerLifecycleTests` passed after routing UI through request APIs. `StoreManagerLifecycleTests` passed again with 4 tests after the cancellation review fix.

- [x] **Step 5: API and boundary cleanup**

Before moving to another task, verify request API names are consistent with prior manager request APIs, UI files no longer contain Store purchase/restore task ownership, fake test seams are test-only or narrow, and Store Domain remains pure.

- [x] **Step 6: Request review and commit**

Request code review for Task 42. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: initial review found one Important issue: real `purchase(_:)` and `restorePurchases()` catch paths still translated `CancellationError` into failed Store UI state. The follow-up fix introduced cancellation-aware Store state helpers and regression tests; re-review found no Critical or Important issues. Minor accepted risk: cancellation coverage uses a narrow helper seam because StoreKit `Product.purchase()` and `AppStore.sync()` are not directly faked.

## Task 43: Store Lifecycle Refresh Task Tracking

**Files:**
- Modify: `VVTerm/Features/Store/Application/StoreManager.swift`
- Test: `VVTermTests/Features/Store/StoreManagerLifecycleTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `StoreManager.loadProducts()`
  - `StoreManager.checkEntitlements()`
  - Existing review mode enable/disable state.
- Produces:
  - StoreManager-owned startup refresh task tracking for product load plus entitlement check.
  - StoreManager-owned review-mode disable entitlement refresh tracking.
  - Awaitable test hooks that prove these lifecycle tasks do not disappear into untracked `Task {}` work.

- [x] **Step 1: Add RED lifecycle tests**

Extend `StoreManagerLifecycleTests` with fake load-products and check-entitlements operations. The tests must prove startup refresh remains tracked while product loading and entitlement checking are pending, and that disabling review mode tracks the entitlement refresh until completion.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/StoreManagerLifecycleTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the test fails to compile because StoreManager does not yet expose injectable lifecycle refresh operations or awaitable startup/review-mode refresh tracking hooks.

Actual RED result: `StoreManagerLifecycleTests` failed to compile because `StoreManager.makeForTesting(...)` did not accept lifecycle operation injections.

- [x] **Step 2: Track startup refresh**

Replace the initialization `Task { await loadProducts(); await checkEntitlements() }` with a StoreManager-owned stored task. The task should be canceled in `deinit`, clear itself after completion, and remain awaitable for tests.

- [x] **Step 3: Track review-mode disable refresh**

Replace the `Task { await checkEntitlements() }` created when review mode is disabled with a StoreManager-owned stored task. The task should cancel any previous review-mode refresh, clear itself after completion, and remain awaitable for tests.

- [x] **Step 4: Run focused verification**

Run the focused Store lifecycle tests plus a source scan for the old untracked Store lifecycle tasks:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/StoreManagerLifecycleTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{\\s*(await loadProducts\\(\\)|await checkEntitlements\\(\\))|Task \\{ await checkEntitlements\\(\\) \\}" VVTerm/Features/Store/Application/StoreManager.swift
git diff --check
```

Actual GREEN result: `StoreManagerLifecycleTests` passed 7 Swift Testing tests after startup refresh and review-mode disable refresh were stored on `StoreManager`, including review-fix coverage proving a superseded review-mode refresh does not run entitlement work after cancellation. The Store lifecycle source scan produced no matches for the old untracked load/check entitlement task forms, `git diff --check` passed, and iOS/macOS build-for-testing passed.

- [x] **Step 5: API and boundary cleanup**

Before review, verify the lifecycle hooks are test-only or private, StoreManager remains the single Store lifecycle owner, the new task names match the existing request-task style, and no new StoreKit work moved into SwiftUI.

- [x] **Step 6: Request review and commit**

Request code review for Task 43. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: initial review found one Important issue: canceling a superseded review-mode refresh did not prevent that task from running entitlement work if it resumed before the new task completed. Follow-up RED coverage failed with two entitlement refreshes, then GREEN passed after `startReviewModeRefresh()` checked cancellation before invoking the entitlement refresh action. Re-review found no Critical or Important issues.

## Task 44: Terminal Accessory Cloud Sync Task Tracking

**Files:**
- Modify: `VVTerm/Features/TerminalAccessories/Application/TerminalAccessoryPreferencesManager.swift`
- Test: `VVTermTests/Features/TerminalAccessories/TerminalAccessoryPreferencesManagerTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `TerminalAccessoryPreferencesManager.syncWithCloud()`
  - `CloudKitManager.syncTerminalAccessoryProfile(_:)`
  - `CloudKitSyncCoordinator.enqueueTerminalAccessoryProfileUpsert(_:)`
  - `CloudKitSyncCoordinator.drainPendingMutations()`
  - Existing foreground, sync-toggle, and CloudKit resolution observers.
- Produces:
  - TerminalAccessories application-layer protocol seams for cloud profile sync and pending mutation drain.
  - Stored, cancelable startup and observer-triggered cloud sync tasks owned by `TerminalAccessoryPreferencesManager`.
  - DEBUG-only await hooks that prove startup cloud sync remains tracked until cloud merge and pending mutation drain complete.

- [x] **Step 1: Add RED lifecycle tests**

Extend `TerminalAccessoryPreferencesManagerTests` with fake cloud sync and fake pending mutation drain dependencies. Add one test that enables sync, creates the manager, blocks fake cloud sync and drain independently, and asserts the startup sync task remains pending across both phases and clears after completion. Add one source-boundary test that fails while `TerminalAccessoryPreferencesManager` still contains untracked startup/observer `Task { ... syncWithCloud ... }` wrappers instead of stored task helpers.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalAccessoryPreferencesManagerTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the test fails to compile because `TerminalAccessoryPreferencesManager` does not expose injectable cloud sync / pending drain dependencies or awaitable startup sync tracking hooks. If compile succeeds unexpectedly, the source-boundary test must fail on the old untracked startup/observer `Task` forms.

Actual RED result: `TerminalAccessoryPreferencesManagerTests` failed to compile because `TerminalAccessoryCloudProfileSyncing` and `TerminalAccessoryPendingSyncCoordinating` did not exist, the initializer did not accept cloud sync / pending drain dependencies, and the startup sync await hook did not exist. Review-fix RED then failed `testStartupCloudSyncDoesNotApplyCloudResultAfterSyncIsDisabled` because a CloudKit result that resumed after sync was disabled still merged a remote custom action into local state.

- [x] **Step 2: Add TerminalAccessories sync dependency boundaries**

Introduce small application-layer protocols in `TerminalAccessoryPreferencesManager.swift` for cloud profile sync and pending mutation coordination. Make `CloudKitManager` and `CloudKitSyncCoordinator` conform without moving CloudKit behavior into UI. Keep existing production defaults wired to `.shared`.

- [x] **Step 3: Track startup and observer sync tasks**

Replace the init-time `Task { await syncWithCloud(); await syncCoordinator.drainPendingMutations() }` and observer callback `Task { ... }` sync wrappers with manager-owned stored tasks. Each task should cancel a superseded task of the same kind, clear only if its task ID still matches, and be canceled in `deinit`.

- [x] **Step 4: Run focused verification**

Run the focused TerminalAccessories lifecycle tests and a source scan for old untracked cloud sync task forms:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalAccessoryPreferencesManagerTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{\\s*(await syncWithCloud\\(|@MainActor \\[weak self\\].*syncWithCloud|await self\\?\\.syncWithCloudIfNeededForForeground|await self\\.syncWithCloud\\()" VVTerm/Features/TerminalAccessories/Application/TerminalAccessoryPreferencesManager.swift
git diff --check
```

Actual GREEN result: `TerminalAccessoryPreferencesManagerTests` passed 5 XCTest tests after `TerminalAccessoryPreferencesManager` owned startup, foreground, sync-toggle, and cloud-resolution tasks, and after CloudKit await continuations re-check cancellation and `SyncSettings.isEnabled` before local merge/drain. The source scan found no old untracked startup/observer cloud sync task forms, `git diff --check` passed, iOS build-for-testing passed, and macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` after the signed macOS build failed on missing local Mac Development signing assets. The Swift lifecycle guard warning for added `Task` was reviewed as manager-owned stored task work.

- [x] **Step 5: API and boundary cleanup**

Before review, verify the new protocols stay in TerminalAccessories Application, DEBUG hooks are test-only, observer callbacks only enqueue manager-owned lifecycle tasks, and no CloudKit lifecycle work moved into SwiftUI.

- [x] **Step 6: Request review and commit**

Request code review for Task 44. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: initial review found one Important issue: disabling sync canceled pending drain work but did not cancel or guard in-flight startup/foreground/toggle CloudKit sync tasks, so a stale CloudKit result could still merge remote state after sync was turned off. Follow-up RED coverage reproduced the stale merge, then GREEN passed after disable handling canceled cloud sync tasks and `syncWithCloud()` / foreground drain paths re-checked cancellation plus `SyncSettings.isEnabled` after awaited work. The reviewer Minor source-boundary concern was addressed by asserting all named tracked observer entry points. Re-review found no Critical or Important issues; it left one Minor note that the disable regression behaviorally proves the post-await guard while the observer cancel helper remains covered by source-boundary assertions.

## Task 45: Server Form Keychain Read Boundary

**Files:**
- Create: `VVTerm/Features/Servers/Application/ServerFormCredentialProvider.swift`
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`
- Test: `VVTermTests/ServerFormCredentialProviderTests.swift`
- Test: `VVTermTests/ServerFormCredentialBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `KeychainManager.getStoredSSHKeys()`
  - `KeychainManager.getStoredSSHKeyData(for:)`
  - `KeychainManager.getCredentials(for:)`
  - `ServerFormSheet.loadInitialFormData()`
  - `ServerFormSheet.loadStoredKey(_:)`
  - `ServerFormSheet.selectMatchingStoredKeyIfAvailable()`
- Produces:
  - `ServerFormCredentialLibrary`: Servers Application protocol for server-form credential/key reads.
  - `ServerFormCredentialProvider`: Servers Application owner for reusable stored-key lists, stored-key material loading, server credential loading, and stored-key matching.
  - `ServerFormStoredSSHKeyMaterial`: value type containing decoded private key text, optional passphrase, and optional public key text for UI form population.
  - `ServerFormSheet` dependency on `ServerFormCredentialProvider.shared` instead of direct `KeychainManager.shared` calls.

- [x] **Step 1: Add RED provider and boundary tests**

Add `ServerFormCredentialProviderTests` with an in-memory fake library. Cover stored-key material decoding, matching a stored key by private key and passphrase, rejecting passphrase mismatches, and preserving thrown keychain errors for UI presentation. Add `ServerFormCredentialBoundaryTests` that reads `ServerFormSheet.swift` and fails while the UI source still contains `KeychainManager.shared`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerFormCredentialProviderTests -only-testing:VVTermTests/ServerFormCredentialBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the provider tests fail to compile because `ServerFormCredentialProvider`, `ServerFormCredentialLibrary`, and `ServerFormStoredSSHKeyMaterial` do not exist. If those compile unexpectedly, the boundary test must fail because `ServerFormSheet.swift` still directly references `KeychainManager.shared`.

Actual RED result: focused `ServerFormCredentialProviderTests` / `ServerFormCredentialBoundaryTests` failed to compile because `ServerFormCredentialLibrary` and `ServerFormCredentialProvider` did not exist. The initial fixture also exposed a missing `serverId` argument in the test `ServerCredentials` setup, which was corrected before GREEN.

- [x] **Step 2: Add Servers Application credential provider**

Create `ServerFormCredentialProvider.swift` in Servers Application. Keep `KeychainManager` conformance at the application boundary and expose only server-form read operations needed by the UI. Convert stored key `Data` to `String` inside the provider so `ServerFormSheet` receives form-ready values without touching keychain storage details.

- [x] **Step 3: Route ServerFormSheet through provider**

Inject `ServerFormCredentialProvider.shared` into `ServerFormSheet` via a private dependency. Replace stored-key list refreshes, edit credential loading, stored-key material loading, and stored-key matching with provider calls. Keep UI behavior unchanged: selected stored keys still populate private key, passphrase, and public key fields; matching still respects passphrase mismatch.

- [x] **Step 4: Run focused verification**

Run the focused provider/boundary tests, a source scan for direct `KeychainManager.shared` in `ServerFormSheet.swift`, and `git diff --check`:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerFormCredentialProviderTests -only-testing:VVTermTests/ServerFormCredentialBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "KeychainManager\\.shared" VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift
git diff --check
```

Actual GREEN result: focused `ServerFormCredentialProviderTests` / `ServerFormCredentialBoundaryTests` passed 7 Swift Testing tests after review-fix coverage. The source scan found no direct `KeychainManager.shared` references in `ServerFormSheet.swift`, `git diff --check` passed, iOS build-for-testing passed after rerunning sequentially to avoid Xcode's `build.db` lock, signed macOS build-for-testing failed on missing local Mac Development signing assets, and macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO`.

- [x] **Step 5: API and boundary cleanup**

Before review, verify the new provider lives in Servers Application, the UI only sends form/read intent through that provider, no Keychain storage details leak back into UI, provider names read clearly at call sites, and no temporary source-boundary-only helper remains public.

- [x] **Step 6: Request review and commit**

Request code review for Task 45. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: initial review found one Important behavior-preservation issue: automatic stored-key matching would surface the first unreadable stored-key candidate as a form error, while the old UI loop skipped broken candidates and could still match a later valid key. Follow-up RED coverage failed to compile until `matchingStoredSSHKey(in:...)` existed; GREEN passed after matching was scoped to the already loaded picker candidates and per-candidate read/decode failures were skipped. Direct explicit stored-key loading still preserves underlying read failures for user-visible error presentation. Re-review found no Critical or Important issues; the remaining Minor API clarity note was addressed by making matching non-throwing and removing the dead UI catch.

## Task 46: Sync Settings CloudKit Status Boundary

**Files:**
- Create: `VVTerm/Features/Settings/Application/SyncSettingsStore.swift`
- Modify: `VVTerm/Features/Settings/UI/SyncSettingsView.swift`
- Test: `VVTermTests/SyncSettingsStoreTests.swift`
- Test: `VVTermTests/SettingsLifecycleBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `CloudKitManager.syncStatus`
  - `CloudKitManager.lastSyncDate`
  - `CloudKitManager.isAvailable`
  - `CloudKitManager.accountStatusDetail`
  - `AppSyncCoordinator.handleSyncSettingsChanged(_:)`
  - `AppSyncCoordinator.refreshCloudKitStatusFromSettings()`
- Produces:
  - `SyncSettingsCloudStatusProviding`: Settings Application protocol for observable CloudKit status values.
  - `SyncSettingsCoordinating`: Settings Application protocol for sync-toggle and CloudKit-status refresh intent.
  - `SyncSettingsStore`: Settings Application owner that bridges CloudKit status observation and sync intent for the SwiftUI settings view.
  - `SyncSettingsView` dependency on `SyncSettingsStore.shared` instead of direct `CloudKitManager.shared` / `AppSyncCoordinator.shared` calls.

- [x] **Step 1: Add RED store and boundary tests**

Add `SyncSettingsStoreTests` with fakes for CloudKit status and sync coordination. Cover initial status snapshot, published status updates, sync-toggle intent delegation, and coalesced status refresh task reuse through the coordinator boundary. Extend `SettingsLifecycleBoundaryTests` so `SyncSettingsView.swift` fails while it directly references `CloudKitManager.shared` or `AppSyncCoordinator.shared`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/SyncSettingsStoreTests -only-testing:VVTermTests/SettingsLifecycleBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `SyncSettingsStoreTests` fails to compile because `SyncSettingsStore`, `SyncSettingsCloudStatusProviding`, and `SyncSettingsCoordinating` do not exist. If those compile unexpectedly, the boundary test must fail because `SyncSettingsView.swift` still directly references CloudKit/app-sync singletons.

Actual RED result: focused `SyncSettingsStoreTests` / `SettingsLifecycleBoundaryTests` failed to compile because `SyncSettingsCloudStatusProviding`, `SyncSettingsCoordinating`, and `SyncSettingsStore` did not exist.

- [x] **Step 2: Add Settings Application sync store**

Create `SyncSettingsStore.swift` in Settings Application. Keep production defaults wired to `CloudKitManager.shared` and `AppSyncCoordinator.shared`, but expose only view-ready status values and explicit `handleSyncEnabledChanged(_:)` / `refreshCloudKitStatus()` intent methods. Store any Combine subscription and returned coordinator task inside the store so the UI does not own sync lifecycle state.

- [x] **Step 3: Route SyncSettingsView through the store**

Replace `@ObservedObject private var cloudKit = CloudKitManager.shared` with the application store. Use store-published status values for badges/status/details and send toggle/recheck intent through the store. Preserve existing copy, counts, labels, and visible behavior.

- [x] **Step 4: Run focused verification**

Run the focused store/boundary tests, source scans for direct singleton references in `SyncSettingsView.swift`, and `git diff --check`:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/SyncSettingsStoreTests -only-testing:VVTermTests/SettingsLifecycleBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "CloudKitManager\\.shared|AppSyncCoordinator\\.shared" VVTerm/Features/Settings/UI/SyncSettingsView.swift
git diff --check
```

Actual GREEN result: focused `SyncSettingsStoreTests` / `SettingsLifecycleBoundaryTests` passed 9 Swift Testing tests after the store introduced CloudKit status snapshot bridging, tracked sync-toggle/recheck tasks, and `SyncSettingsView` stopped referencing CloudKit/app-sync singletons. The source scan found no direct `CloudKitManager.shared` or `AppSyncCoordinator.shared` in `SyncSettingsView.swift`; `git diff --check` passed; iOS build-for-testing passed after a sequential rerun because the first parallel build hit Xcode's `build.db` lock; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `SyncSettingsStore` lives in Settings Application, SwiftUI only renders state and sends intent, CloudKit/app sync singleton access stays behind application-layer protocols, task ownership is awaitable/tracked where relevant, and test files include complete context for future failures.

- [x] **Step 6: Request review and commit**

Request code review for Task 46. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: subagent review was not spawned because the current tool contract permits spawning only when the user explicitly requests subagents. Local read-only review found one Important status-ordering issue: publishing a void event and then re-reading provider properties could lag behind `@Published` updates at the CloudKit boundary. Review-fix RED reproduced stale `.idle` / `available` values when the fake provider published before applying backing properties. GREEN passed after the status protocol published complete `SyncSettingsCloudStatusSnapshot` values and production `CloudKitManager` used `CombineLatest4` to carry publisher-emitted values into the store. Re-review found no remaining Critical or Important issues against the Swift lifecycle checklist.

## Task 47: Workspace Form Save/Delete Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Modify: `VVTerm/Features/Servers/UI/Workspace/WorkspaceFormSheet.swift`
- Test: `VVTermTests/ServerManagerBootstrapTests.swift`
- Test: `VVTermTests/WorkspaceFormIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ServerManager.addWorkspace(_:)`
  - `ServerManager.updateWorkspace(_:)`
  - `ServerManager.requestWorkspaceDeletion(_:)`
  - `WorkspaceFormSheet.saveWorkspace()`
  - `WorkspaceFormSheet.deleteWorkspace()`
- Produces:
  - `ServerWorkspaceSaveFailure`: application-layer diagnostic for failed user-initiated workspace save intent.
  - `ServerManager.requestWorkspaceSave(_:mode:onSaved:onProRequired:onFailed:)`: manager-owned, tracked workspace create/update request API.
  - `ServerManager.waitForWorkspaceSaveRequest(_:)` and `pendingWorkspaceSaveRequestIDs` for awaitable tests and later lifecycle ordering.
  - `WorkspaceFormSheet` save/delete actions that synchronously send intent to `ServerManager` instead of owning async CRUD tasks.

- [x] **Step 1: Add RED manager and boundary tests**

Extend `ServerManagerBootstrapTests` with request-save coverage for successful workspace update and Pro-limit create failure. Add `WorkspaceFormIntentBoundaryTests` that reads `WorkspaceFormSheet.swift` and fails while the form owns `Task { ... }` wrappers or directly calls `addWorkspace`, `updateWorkspace`, or `deleteWorkspace`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/WorkspaceFormIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `ServerManagerBootstrapTests` fails to compile because workspace save request APIs and `ServerWorkspaceSaveFailure` do not exist. If those compile unexpectedly, the boundary test must fail because `WorkspaceFormSheet.swift` still owns async CRUD `Task` wrappers and direct workspace CRUD calls.

Actual RED result: `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/WorkspaceFormIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` failed to compile before production changes because `ServerManager` did not expose `requestWorkspaceSave`, `pendingWorkspaceSaveRequestIDs`, `waitForWorkspaceSaveRequest`, or `workspaceSaveFailure`, and the contextual `.create` / `.update` save modes did not exist.

- [x] **Step 2: Add ServerManager workspace save request tracking**

Add a small save operation enum/failure type and manager-owned request dictionary. The request API should clear prior save failure, run create/update through the existing async CRUD methods, store the returned task by request ID, clear only its own ID, expose an await hook, call success only after the application-layer save succeeds, and preserve Pro-required failures separately so UI can keep showing the upgrade sheet.

- [x] **Step 3: Route WorkspaceFormSheet through request APIs**

Replace form-owned save/delete `Task` blocks with synchronous calls to `requestWorkspaceSave` and `requestWorkspaceDeletion`. Keep visible behavior: save sets `isSaving`, success calls `onSave` and dismisses, Pro-limit failure opens the upgrade sheet and clears saving, other failures show local error text, delete success dismisses, delete failure shows local error text.

- [x] **Step 4: Run focused verification**

Run focused manager/boundary tests, source scans for old async CRUD ownership in `WorkspaceFormSheet.swift`, and `git diff --check`:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/WorkspaceFormIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{|try await serverManager\\.(addWorkspace|updateWorkspace|deleteWorkspace)" VVTerm/Features/Servers/UI/Workspace/WorkspaceFormSheet.swift
git diff --check
```

Actual GREEN result: the focused test command passed 16 Swift Testing tests across `ServerManagerBootstrapTests` and `WorkspaceFormIntentBoundaryTests`. The source scan for `Task \{` and direct `try await serverManager.addWorkspace/updateWorkspace/deleteWorkspace` in `WorkspaceFormSheet.swift` produced no matches. `git diff --check` passed. iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`, `-parallel-testing-enabled NO`, and skipped UI tests. macOS `build-for-testing` passed with `CODE_SIGNING_ALLOWED=NO`; only the existing XCTest deployment-version link warnings were present.

- [x] **Step 5: API and boundary cleanup**

Before review, verify save/delete request APIs live in Servers Application, UI callbacks only update UI state after application-layer completion, Pro-limit behavior remains user-visible, request tasks clear deterministically, and tests include enough context to distinguish behavior regressions from intentional ownership moves.

Cleanup result: `WorkspaceSaveMode`, `ServerWorkspaceSaveFailure`, and workspace save task storage live in Servers Application on `ServerManager`. `WorkspaceFormSheet` now only builds the desired value and sends request intent; save success, Pro-limit, ordinary failure, delete success, and delete failure update UI state from manager callbacks after the application-layer operation finishes. Request IDs are removed by the tracked manager task after completion, and the new boundary test includes a Test Context header plus Given/When/Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 47. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: subagent review was not spawned because the current tool contract permits spawning only when the user explicitly requests subagents. Local read-only review against the Swift lifecycle checklist found no Critical or Important issues. The stable owner is `ServerManager`; `WorkspaceFormSheet` sends intent only; save/delete work is tracked and awaitable through request IDs; expected Pro-limit failures remain distinguishable from ordinary save failures.

## Task 48: Environment Form Save Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Modify: `VVTerm/Features/Servers/UI/Workspace/EnvironmentFormSheet.swift`
- Test: `VVTermTests/ServerManagerBootstrapTests.swift`
- Test: `VVTermTests/EnvironmentFormIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ServerManager.createCustomEnvironment(name:color:)`
  - `ServerManager.updateEnvironment(_:in:)`
  - `ServerManager.updateWorkspace(_:)`
  - `EnvironmentFormSheet.saveEnvironment()`
- Produces:
  - `ServerEnvironmentSaveMode`: `.create` and `.update` modes for user-initiated environment save intent.
  - `ServerEnvironmentSaveFailure`: application-layer diagnostic for failed user-initiated environment save intent.
  - `ServerManager.requestEnvironmentSave(_:in:mode:onSaved:onFailed:)`: manager-owned, tracked environment create/update request API.
  - `ServerManager.waitForEnvironmentSaveRequest(_:)` and `pendingEnvironmentSaveRequestIDs` for awaitable tests and later lifecycle ordering.
  - `EnvironmentFormSheet` save action that synchronously sends intent to `ServerManager` instead of owning async workspace/environment update tasks.

- [x] **Step 1: Add RED manager and boundary tests**

Extend `ServerManagerBootstrapTests` with request-save coverage for successful environment update and duplicate-name/update failure behavior if the failure can be expressed through the manager API. Add `EnvironmentFormIntentBoundaryTests` with a Test Context header. The source-boundary test must read `EnvironmentFormSheet.swift` and fail while the form owns a `Task { ... }` wrapper or directly calls:

```swift
try await serverManager.updateEnvironment
try await serverManager.updateWorkspace
```

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/EnvironmentFormIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `ServerManagerBootstrapTests` fails to compile because environment save request APIs, save mode, pending request IDs, await hook, or failure state do not exist. If those compile unexpectedly, `EnvironmentFormIntentBoundaryTests` fails because `EnvironmentFormSheet.swift` still owns async save `Task` work and directly calls workspace/environment CRUD methods.

Actual RED result: `xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/EnvironmentFormIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO` failed to compile before production changes because `ServerManager` did not expose `requestEnvironmentSave`, `ServerEnvironmentSaveMode.create/update`, `pendingEnvironmentSaveRequestIDs`, `waitForEnvironmentSaveRequest`, or `environmentSaveFailure`.

- [x] **Step 2: Add ServerManager environment save request tracking**

Add a small save mode enum/failure type and manager-owned request dictionary. The request API should clear prior environment save failure, run create/update through existing application-layer methods, store the returned task by request ID, clear only its own ID, expose an await hook, call success only after the application-layer save succeeds, and call failure with the user-visible message without mutating UI state directly.

For create mode, the manager should create the custom environment, append it to the workspace, and reuse `updateWorkspace(_:)` as the persistence/sync boundary. For update mode, it should reuse `updateEnvironment(_:in:)` so assigned servers and workspace selection keep the existing behavior.

- [x] **Step 3: Route EnvironmentFormSheet through request APIs**

Replace the form-owned save `Task` block with a synchronous call to `requestEnvironmentSave`. Keep visible behavior: local duplicate-name validation remains immediate in the form, save sets `isSaving`, success calls `onSave` and dismisses, and failure shows local error text and clears saving.

- [x] **Step 4: Run focused verification**

Run focused manager/boundary tests, source scans for old async CRUD ownership in `EnvironmentFormSheet.swift`, and `git diff --check`:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/EnvironmentFormIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{|try await serverManager\\.(updateEnvironment|updateWorkspace)" VVTerm/Features/Servers/UI/Workspace/EnvironmentFormSheet.swift
git diff --check
```

Actual GREEN result: the focused test command passed 18 Swift Testing tests across `ServerManagerBootstrapTests` and `EnvironmentFormIntentBoundaryTests`. The source scan for `Task \{` and direct `try await serverManager.updateEnvironment/updateWorkspace` in `EnvironmentFormSheet.swift` produced no matches. `git diff --check` passed. iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`, `-parallel-testing-enabled NO`, and skipped UI tests. macOS `build-for-testing` passed with `CODE_SIGNING_ALLOWED=NO`; only the existing XCTest deployment-version link warnings and AppIntents no-dependency metadata skip warning were present.

- [x] **Step 5: API and boundary cleanup**

Before review, verify save request APIs live in Servers Application, UI callbacks only update UI state after application-layer completion, request tasks clear deterministically, no stale workspace copy is passed to UI on create/update success, and tests include enough context to distinguish behavior regressions from intentional ownership moves.

Cleanup result: `ServerEnvironmentSaveMode`, `ServerEnvironmentSaveFailure`, and environment save task storage live in Servers Application on `ServerManager`. `EnvironmentFormSheet` now builds the desired environment value and sends request intent; success and failure callbacks update UI state only after the manager-owned request completes. Request IDs are removed by the tracked manager task after completion, create success returns the persisted workspace after `updateWorkspace(_:)`, update success returns the `updateEnvironment(_:in:)` result, and the new boundary test includes a Test Context header plus Given/Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 48. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: subagent review was not spawned because the current tool contract permits spawning only when the user explicitly requests subagents. Local read-only review against the Swift lifecycle checklist found no Critical or Important issues. The stable owner is `ServerManager`; `EnvironmentFormSheet` sends intent only; save work is tracked and awaitable through request IDs; Pro-required create failures remain distinguishable through `ServerEnvironmentSaveFailure` and the existing manager error path.

## Task 49: Server Form Save Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`
- Test: `VVTermTests/ServerManagerBootstrapTests.swift`
- Test: `VVTermTests/ServerFormSaveIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ServerManager.addServer(_:credentials:)`
  - `ServerManager.updateServer(_:credentials:)`
  - `ServerFormSheet.saveServer()`
  - `ServerFormCredentialBuilder.build(...)`
- Produces:
  - `ServerSaveMode`: `.create` and `.update` modes for user-initiated server save intent.
  - `ServerSaveFailure`: application-layer diagnostic for failed user-initiated server create/update intent.
  - `ServerManager.requestServerSave(_:credentials:mode:onSaved:onProRequired:onFailed:)`: manager-owned, tracked server create/update request API.
  - `ServerManager.waitForServerSaveRequest(_:)` and `pendingServerSaveRequestIDs` for awaitable tests and later lifecycle ordering.
  - `ServerFormSheet` save action that synchronously sends intent to `ServerManager` instead of owning async credential/metadata save tasks.

- [x] **Step 1: Add RED manager and boundary tests**

Extend `ServerManagerBootstrapTests` with request-save coverage for successful server create, successful server update, and credential-store failure. Add `ServerFormSaveIntentBoundaryTests` with a Test Context header. The source-boundary test must read `ServerFormSheet.swift` and fail while `saveServer()` owns a `Task { ... }` wrapper or directly calls:

```swift
try await serverManager.updateServer(newServer, credentials: credentials)
try await serverManager.addServer(newServer, credentials: credentials)
```

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/ServerFormSaveIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `ServerManagerBootstrapTests` fails to compile because server save request APIs, save mode, pending request IDs, await hook, or failure state do not exist. If those compile unexpectedly, `ServerFormSaveIntentBoundaryTests` fails because `ServerFormSheet.saveServer()` still owns async credential/metadata save `Task` work and directly calls server CRUD methods.

Actual RED result: the focused command failed with exit 65 before production changes. Compilation failed because `ServerManager` had no `requestServerSave`, no save mode, no `pendingServerSaveRequestIDs`, no `waitForServerSaveRequest`, and no `serverSaveFailure`.

- [x] **Step 2: Add ServerManager server save request tracking**

Add a small save mode enum/failure type and manager-owned request dictionary. The request API should clear prior server save failure, run create/update through existing application-layer methods, store the returned task by request ID, clear only its own ID, expose an await hook, call success only after credential and metadata save succeeds, and preserve Pro-required failures separately so UI can keep showing the upgrade sheet.

For create mode, reuse `addServer(_:credentials:)` so Pro limits, credential storage, bootstrap workspace promotion, pending CloudKit upsert, and local persistence keep their existing behavior. For update mode, reuse `updateServer(_:credentials:)` so credential failure still prevents metadata mutation. In both modes, return the persisted server value from `servers.first(where: { $0.id == server.id }) ?? server` to avoid passing stale pre-save timestamps or metadata back to UI.

- [x] **Step 3: Route ServerFormSheet through request APIs**

Replace the save form-owned `Task` block with a synchronous call to `requestServerSave`. Keep visible behavior: save sets `isSaving`, success calls `onSave` and dismisses, Pro-limit failure opens the existing server limit alert and clears saving, and ordinary failures show local error text and clear saving.

- [x] **Step 4: Run focused verification**

Run focused manager/boundary tests, source scans for old async CRUD ownership in `ServerFormSheet.swift`, and `git diff --check`:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/ServerFormSaveIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "try await serverManager\\.(updateServer|addServer)\\(newServer, credentials: credentials\\)|Task \\{" VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift
git diff --check
```

Actual GREEN result: the focused test command passed 22 tests in 2 suites after review fixes. A scoped `saveServer()` source scan showed the form save action only builds values synchronously and calls `serverManager.requestServerSave(...)`; the broader `Task {` hits in `ServerFormSheet.swift` are outside Task 49 and remain assigned to later slices. `git diff --check`, iOS build-for-testing, and macOS build-for-testing with `CODE_SIGNING_ALLOWED=NO` completed successfully.

- [x] **Step 5: API and boundary cleanup**

Before review, verify save request APIs live in Servers Application, UI callbacks only update UI state after application-layer completion, request tasks clear deterministically, Pro-limit behavior remains user-visible, credential-store failure still prevents metadata mutation, no stale server copy is passed to UI on create/update success, and tests include enough context to distinguish behavior regressions from intentional ownership moves.

Cleanup result: save request APIs live in Servers Application; `ServerFormSheet.saveServer()` only sends intent and updates UI from completion callbacks; request IDs clear from `serverSaveRequests`; Pro-limit, credential-store failure, and persisted-server callback behavior are covered by focused tests with Test Context headers.

- [x] **Step 6: Request review and commit**

Request code review for Task 49. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Review result: code review found no Critical issues and three Task-49 findings: missing Pro-required save coverage, missing positive `requestServerSave` boundary assertion, and a missing `When` comment in the source-boundary test. All were fixed before final verification.

## Task 50: Server Move Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`
- Test: `VVTermTests/ServerManagerBootstrapTests.swift`
- Test: `VVTermTests/ServerMoveIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ServerManager.moveServer(_:to:preferredEnvironment:)`
  - `ServerManager.resolvedEnvironment(for:destination:preferredEnvironment:)`
  - `MoveServerSheet.moveServer()`
- Produces:
  - `ServerMoveFailure`: application-layer diagnostic for failed user-initiated server move intent.
  - `ServerManager.requestServerMove(_:to:preferredEnvironment:onMoved:onProRequired:onFailed:)`: manager-owned, tracked server move request API.
  - `ServerManager.waitForServerMoveRequest(_:)` and `pendingServerMoveRequestIDs` for awaitable tests and later lifecycle ordering.
  - `MoveServerSheet` move action that synchronously sends intent to `ServerManager` instead of owning async move tasks.

- [x] **Step 1: Add RED manager and boundary tests**

Extend `ServerManagerBootstrapTests` with request-move coverage for successful move and move failure. Add `ServerMoveIntentBoundaryTests` with a Test Context header. The source-boundary test must read `ServerFormSheet.swift`, isolate `MoveServerSheet.moveServer()`, and fail while the SwiftUI move action owns a `Task { ... }` wrapper or directly calls:

```swift
let updatedServer = try await serverManager.moveServer(
```

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/ServerMoveIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `ServerManagerBootstrapTests` fails to compile because server move request APIs, pending request IDs, await hook, or failure state do not exist. If those compile unexpectedly, `ServerMoveIntentBoundaryTests` fails because `MoveServerSheet.moveServer()` still owns async server move `Task` work and directly calls `moveServer`.

Actual RED result: the focused command failed to compile because `ServerManager` did not yet expose `requestServerMove`, `pendingServerMoveRequestIDs`, `waitForServerMoveRequest`, or `serverMoveFailure`.

- [x] **Step 2: Add ServerManager server move request tracking**

Add a move failure type and manager-owned move request dictionary. The request API should clear prior move failure, run through existing `moveServer(_:to:preferredEnvironment:)`, store the returned task by request ID, clear only its own ID, expose an await hook, call success only after server metadata and workspace selection metadata update succeed, preserve Pro-required failures for the existing upgrade sheet, and route ordinary failures through the UI error callback.

Reuse `moveServer(_:to:preferredEnvironment:)` so destination refresh, move restrictions, environment fallback, `updateServer`, and `updateWorkspaceSelectionMetadataAfterMove` remain the single application-layer move behavior.

- [x] **Step 3: Route MoveServerSheet through request APIs**

Replace the move sheet-owned `Task` block with a synchronous call to `requestServerMove`. Keep visible behavior: move sets `isMoving`, success calls `onMove` and dismisses, Pro-limit failure opens the existing upgrade sheet and clears moving, and ordinary failures show local error text and clear moving.

- [x] **Step 4: Run focused verification**

Run focused manager/boundary tests, source scans for old async move ownership in `MoveServerSheet.moveServer()`, and `git diff --check`:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests -only-testing:VVTermTests/ServerMoveIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
awk '/private func moveServer\\(\\)/,/private func sectionHeader/' VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift
git diff --check
```

Actual GREEN result: the focused command passed 25 Swift Testing tests in 2 suites. A scoped `MoveServerSheet.moveServer()` source scan showed only `serverManager.requestServerMove(...)`, with no local `Task` creation and no direct `serverManager.moveServer(...)` call. `git diff --check` completed with no output. iOS build-for-testing completed successfully. macOS build-for-testing completed successfully with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment-target warnings.

- [x] **Step 5: API and boundary cleanup**

Before review, verify move request APIs live in Servers Application, UI callbacks only update UI state after application-layer completion, request tasks clear deterministically, Pro-limit behavior remains user-visible, move restriction failures remain distinguishable internally, and tests include enough context to distinguish behavior regressions from intentional ownership moves.

Actual cleanup result: `requestServerMove` lives in `ServerManager`, move request tasks are tracked by request ID and awaitable through `waitForServerMoveRequest`, UI callbacks are invoked from the manager-owned task only after the existing application-layer move path returns, Pro-limit failures route to the upgrade continuation, ordinary failures remain distinguishable through `ServerMoveFailure`, and the new boundary test includes the required Test Context.

- [x] **Step 6: Request review and commit**

Request code review for Task 50. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Actual review result: code review found an Important coverage gap for ordinary non-Pro move failures and a Minor source-boundary literalness issue. Added missing ordinary failure coverage, strengthened the boundary test for `Task(` / `Task.detached` / direct `moveServer`, and verified the new ordinary failure test with a mutation RED that suppressed `onFailed` and failed as expected before restoration.

## Task 51: Server Form Connection Test Intent Boundary

**Files:**
- Create: `VVTerm/Features/Servers/Application/ServerConnectionTester.swift`
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`
- Test: `VVTermTests/ServerConnectionTesterTests.swift`
- Test: `VVTermTests/ServerFormConnectionTestBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `SSHConnectionOperationService.shared.withTemporaryConnection(server:credentials:_:)`
  - `RemoteMoshManager.shared.bootstrapConnectInfo(using:startCommand:portRange:)`
  - `ServerFormSheet.connectionSnapshot`
  - `ServerFormSheet.buildServer(id:createdAt:)`
  - `ServerFormSheet.buildCredentials(for:)`
- Produces:
  - `ServerConnectionTesting`: application-layer protocol for server form connection checks without real network in tests.
  - `ServerConnectionTestFailure`: typed diagnostic for failed user-initiated connection tests.
  - `ServerConnectionTester.requestConnectionTest(server:credentials:onSucceeded:onFailed:onCompleted:)`: application-owned, tracked connection-test request API.
  - `ServerConnectionTester.waitForConnectionTestRequest(_:)` and `pendingConnectionTestRequestIDs` for awaitable lifecycle ordering tests.
  - `ServerFormSheet` connection-test button that synchronously sends intent to `ServerConnectionTester` instead of owning async connection-test tasks.

- [x] **Step 1: Add RED connection tester and boundary tests**

Add `ServerConnectionTesterTests` with a Test Context header and fake `ServerConnectionTesting` implementation. Cover success, ordinary failure, request tracking, and mosh-mode bootstrap delegation through the injected tester. Add `ServerFormConnectionTestBoundaryTests` that reads `ServerFormSheet.swift`, isolates `connectionSection` and the connection-test helper, and fails while SwiftUI owns `Task { await runConnectionTest(...) }`, uses `Task.detached`, or directly references `SSHConnectionOperationService.shared` / `RemoteMoshManager.shared`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerConnectionTesterTests -only-testing:VVTermTests/ServerFormConnectionTestBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `ServerConnectionTesterTests` fails to compile because `ServerConnectionTester`, `ServerConnectionTesting`, request IDs, await hooks, or failure state do not exist. If those compile unexpectedly, `ServerFormConnectionTestBoundaryTests` fails because `ServerFormSheet` still owns async connection-test `Task` work and directly reaches Core SSH/mosh services.

Actual RED result: the focused suite failed before implementation because `ServerConnectionTesting` and `ServerConnectionTester` did not exist. After review identified the cancellation completion gap, an additional RED failed with `Extra argument 'onCompleted' in call`, proving the test required a completion signal for cancellation before production code supported it.

- [x] **Step 2: Add Servers Application connection-test owner**

Create `ServerConnectionTester` in Servers Application. It should own a dictionary of tracked request tasks, expose pending request IDs and `waitForConnectionTestRequest(_:)`, record `ServerConnectionTestFailure`, and delegate the real connection check through `ServerConnectionTesting`. The default concrete tester should use `SSHConnectionOperationService.shared.withTemporaryConnection`; for `.mosh` servers it should also call `RemoteMoshManager.shared.bootstrapConnectInfo` with the existing `exec true` command and `60001...61000` port range. Keep cancellation distinct from ordinary failure if a request is canceled later.

- [x] **Step 3: Route ServerFormSheet connection tests through request APIs**

Inject `ServerConnectionTester` into `ServerFormSheet` with `.shared` as the default. Replace the button-owned `Task` and async `runConnectionTest(force:)` body with a synchronous request helper. Preserve visible behavior: the button disables while testing, success shows the existing green footer and stores the snapshot, ordinary failures show the localized error, Tailscale failures append the existing no-userspace-proxy reminder, and Cloudflare configuration failures show override fields.

- [x] **Step 4: Run focused verification**

Run focused tests, scoped source scans, and `git diff --check`:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerConnectionTesterTests -only-testing:VVTermTests/ServerFormConnectionTestBoundaryTests ENABLE_DEBUG_DYLIB=NO
awk '/private var connectionSection/,/private var sessionSection/' VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift
awk '/private func requestConnectionTest/,/private func saveServer/' VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift
git diff --check
```

Actual GREEN result: the focused suite passed 6 Swift Testing tests in 2 suites after adding cancellation-completion coverage. Scoped scans showed the connection button now sends `requestConnectionTest(force: true)`, the form helper calls `connectionTester.requestConnectionTest(...)`, and direct `Task.detached`, `SSHConnectionOperationService.shared`, and `RemoteMoshManager.shared` hits moved out of SwiftUI into `ServerConnectionTester`. `git diff --check` passed. iOS build-for-testing passed. macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings.

- [x] **Step 5: API and boundary cleanup**

Before review, verify the connection-test owner lives in Servers Application, UI callbacks only update UI state after application-layer completion, request tasks clear deterministically, real network is not used by tests, the temporary SSH/mosh concrete implementation is behind a protocol, and tests include enough context to distinguish behavior regressions from intentional ownership moves.

Actual cleanup result: `ServerConnectionTester` owns the tracked request task dictionary and await hooks in Servers Application; SwiftUI only builds the draft server/credentials and sends intent. Success/failure callbacks update result UI, while `onCompleted` always clears transient testing state, including cancellation. Real SSH/mosh work is behind `ServerConnectionTesting`; tests use delayed in-memory fakes with full Test Context headers. `ObservableObject` / `@Published` was intentionally not used because the form does not observe this owner.

- [x] **Step 6: Request review and commit**

Request code review for Task 51. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Actual review result: code review found an Important cancellation gap where `CancellationError` was swallowed by `ServerConnectionTester` without notifying `ServerFormSheet`, leaving `isTestingConnection` stuck. Added a RED cancellation test, introduced `onCompleted`, and routed the form's testing-state cleanup through that completion callback. Re-run focused tests passed 6 tests in 2 suites; source scans, `git diff --check`, iOS build-for-testing, and macOS build-for-testing passed.

## Task 52: App Lock Authentication Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Security/Application/AppLockManager.swift`
- Modify: `VVTerm/Features/Security/UI/AppLockGateView.swift`
- Modify: `VVTerm/Features/Settings/UI/GeneralSettingsView.swift`
- Test: `VVTermTests/Features/Security/AppLockManagerTests.swift`
- Test: `VVTermTests/AppLockIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `AppLockManager.requestSetFullAppLockEnabled(_:) async`
  - `AppLockManager.ensureAppUnlocked() async -> Bool`
  - `AppLockManager.handleScenePhaseChange(_:)`
  - `BiometricAuthServing.authenticate(localizedReason:allowPasscodeFallback:)`
  - `GeneralSettingsView` full-app-lock toggle binding
  - `AppLockContainer` scene activation hooks
  - `AppLockGateView` unlock button
- Produces:
  - `AppLockManager.requestFullAppLockChange(_:) -> UUID`: synchronous UI intent API for enabling/disabling full app lock.
  - `AppLockManager.requestAppUnlock() -> UUID`: synchronous UI intent API for app-unlock authentication.
  - `AppLockManager.waitForAppLockRequest(_:)` and `pendingAppLockRequestIDs` for awaitable lifecycle ordering tests.
  - SwiftUI app-lock views that send authentication intent without owning `Task { await appLockManager... }`.

- [x] **Step 1: Add RED app-lock request and boundary tests**

Add AppLock manager tests with delayed fake biometric auth. Cover that `requestFullAppLockChange(true)` tracks the request while authentication is in flight, eventually enables full app lock, and clears the request only after the existing async behavior completes. Cover that `requestAppUnlock()` tracks the request, unlocks an already locked app after authentication, and clears the request after completion. Add `AppLockIntentBoundaryTests` with a Test Context header that reads `AppLockGateView.swift` and `GeneralSettingsView.swift`; it should fail while those SwiftUI files contain `Task { await appLockManager.ensureAppUnlocked() }` or `Task { await appLockManager.requestSetFullAppLockEnabled(...) }`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppLockManagerTests -only-testing:VVTermTests/AppLockIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `AppLockManagerTests` fails to compile because `requestFullAppLockChange(_:)`, `requestAppUnlock()`, `waitForAppLockRequest(_:)`, or `pendingAppLockRequestIDs` do not exist. If those compile unexpectedly, `AppLockIntentBoundaryTests` fails because app-lock SwiftUI still launches authentication tasks directly.

Actual RED result: the focused suite failed before production changes because `AppLockManager` did not expose `requestFullAppLockChange(_:)`, `requestAppUnlock()`, `waitForAppLockRequest(_:)`, or `pendingAppLockRequestIDs`. After review identified cancellation as lifecycle state, the review-fix RED failed because `lastErrorMessage` was set to `Swift.CancellationError` instead of staying nil.

- [x] **Step 2: Add AppLockManager request ownership**

Add a tracked request-task dictionary to `AppLockManager`. `requestFullAppLockChange(_:)` should create and store a `Task` that awaits the existing `requestSetFullAppLockEnabled(_:)`, then clears itself. `requestAppUnlock()` should create and store a `Task` that awaits the existing `ensureAppUnlocked()`, then clears itself. Keep the existing async methods as the behavior boundary for product logic and existing call sites that already run inside application-layer async flows. Cancellation should clear tracking and should not create a user-facing failure.

- [x] **Step 3: Route SwiftUI app-lock authentication through request APIs**

Update `GeneralSettingsView` full-app-lock toggle setter to call `appLockManager.requestFullAppLockChange(newValue)` synchronously. Update `AppLockContainer` `.onAppear` and scene activation hooks to call `appLockManager.requestAppUnlock()` after handling scene phase. Update `AppLockGateView` unlock button to call `appLockManager.requestAppUnlock()` synchronously. Preserve visible behavior: `isAuthenticating` still drives disabled/progress state, unavailable biometry still sets `lastErrorMessage`, authentication cancellation remains non-failure, and successful unlock/enable still updates the same published state.

- [x] **Step 4: Run focused verification**

Run focused tests, scoped source scans, and whitespace check:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppLockManagerTests -only-testing:VVTermTests/AppLockIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{|requestSetFullAppLockEnabled|ensureAppUnlocked" VVTerm/Features/Security/UI/AppLockGateView.swift VVTerm/Features/Settings/UI/GeneralSettingsView.swift
git diff --check
```

Actual GREEN result: the focused suite passed 6 XCTest tests plus 2 Swift Testing tests after adding tracked request APIs and cancellation-aware authentication handling. The app-lock source scan showed SwiftUI only calls `requestAppUnlock()` / `requestFullAppLockChange(newValue)`, with the only production `Task {}` in `AppLockManager`. `git diff --check` passed. iOS build-for-testing passed. macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings / AppIntents metadata skip warning.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `AppLockManager` is the only owner of user-initiated app-lock authentication tasks, request API names express intent and side effects, SwiftUI only updates view-local presentation state or sends synchronous intent, tests use fake biometric auth without real device prompts, and touched test files include enough Test Context / Given / When / Then information for future failure triage.

Actual cleanup result: `AppLockManager` owns tracked app-lock request tasks and exposes request IDs plus an await hook for ordering tests. `AppLockContainer`, `AppLockGateView`, and the full-app-lock toggle now send synchronous intent only. Tests use delayed fake biometric auth, include Test Context / Given / When / Then notes, and cover cancellation as lifecycle completion rather than user-facing failure. The request tracker passes the manager into the stored operation closure to avoid an unnecessary strong operation capture of `self`.

- [x] **Step 6: Request review and commit**

Request code review for Task 52. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Actual review result: code review found no Critical issues. Important findings were that `CancellationError` was incorrectly surfaced as `lastErrorMessage` and that the new source-boundary test file was still untracked; both were fixed. Minor findings about touched legacy tests lacking Given/When/Then context and Task 52 ledger drift were also fixed before commit.

## Task 53: App Lifecycle Intent Boundary

**Files:**
- Create: `VVTerm/App/Application/AppLifecycleCoordinator.swift`
- Modify: `VVTerm/App/VVTermApp.swift`
- Test: `VVTermTests/AppLifecycleCoordinatorTests.swift`
- Test: `VVTermTests/AppLifecycleIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ConnectionSessionManager.shared.disconnectAllAndWait()`
  - `TerminalTabManager.shared.disconnectAllAndWait()`
  - `ConnectionSessionManager.shared.suspendAllForBackground()`
  - `AppLockManager.shared.lockIfNeededForBackground()`
  - `AppSyncCoordinator.shared.startChangeSubscription()`
  - `AppSyncCoordinator.shared.refreshServerData(reason:)`
  - `AppSyncCoordinator.shared.refreshServerDataAfterRemoteNotification(onComplete:)`
  - `SyncSettings.isEnabled`
  - `ServerManager.shared.handleAppLanguageChange()`
- Produces:
  - `AppLifecycleCoordinator.shared`: application-layer owner for app delegate lifecycle orchestration.
  - `AppLifecycleCoordinator.requestLaunch()`: synchronous delegate intent for startup subscription work.
  - `AppLifecycleCoordinator.requestForegroundRefresh()`: synchronous foreground intent that applies sync-enabled and throttling policy.
  - `AppLifecycleCoordinator.requestRemoteNotificationRefresh(onComplete:)`: synchronous remote notification intent that preserves the completion callback contract.
  - `AppLifecycleCoordinator.requestBackgroundLock() -> UUID`: tracked background app-lock request API.
  - `AppLifecycleCoordinator.requestBackgroundSuspension() -> UUID`: tracked background suspend/lock request API.
  - `AppLifecycleCoordinator.waitForBackgroundLockRequest(_:)`, `pendingBackgroundLockRequestIDs`, `waitForBackgroundSuspensionRequest(_:)`, and `pendingBackgroundSuspensionRequestIDs` for awaitable lifecycle ordering tests.
  - `AppLifecycleCoordinator.waitForRemoteNotificationRefreshRequest(_:)` and `pendingRemoteNotificationRefreshRequestIDs` for awaitable remote-notification completion tests.
  - `AppLifecycleCoordinator.requestTerminationTeardown(onCompleted:) -> UUID`: tracked timeout-bounded terminal-manager teardown request API for app termination.
  - `AppLifecycleCoordinator.waitForTerminationTeardownRequest(_:)` and `pendingTerminationTeardownRequestIDs` for awaitable lifecycle ordering tests.
  - `AppLifecycleCoordinator.handleAppLanguageChange(_:)`: app-level locale intent that keeps SwiftUI from directly calling `ServerManager.shared`.

- [x] **Step 1: Add RED app lifecycle coordinator and source-boundary tests**

Add `AppLifecycleCoordinatorTests` with a Test Context header. Use injected fake closures plus an async gate to cover: background suspension stays tracked until `suspendAllForBackground` finishes and then locks the app; termination teardown waits for both terminal-manager teardown closures before returning; foreground refresh respects sync-disabled and minimum-interval policy; remote notification completion waits on `AppSyncCoordinator` refresh completion. Add `AppLifecycleIntentBoundaryTests` with a Test Context header that reads `VVTermApp.swift` and fails while AppDelegate or the root SwiftUI locale hooks directly call lifecycle singletons or own `Task { ... }` wrappers for background suspension / termination teardown / app-language change.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppLifecycleCoordinatorTests -only-testing:VVTermTests/AppLifecycleIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: `AppLifecycleCoordinatorTests` fails to compile because `AppLifecycleCoordinator`, `requestBackgroundSuspension()`, `pendingBackgroundSuspensionRequestIDs`, `waitForBackgroundSuspensionRequest(_:)`, or termination teardown request APIs do not exist. If those compile unexpectedly, `AppLifecycleIntentBoundaryTests` fails because `VVTermApp.swift` still owns app lifecycle tasks or directly calls terminal/app-lock/sync/server-manager singletons from delegate/root lifecycle hooks.

Actual RED result: the focused suite first failed to compile because `AppLifecycleCoordinator` did not exist. After the initial implementation exposed an untracked background-lock task, the review-cycle RED failed to compile because `pendingBackgroundLockRequestIDs` and `waitForBackgroundLockRequest(_:)` did not exist, proving background lock work still needed tracked ownership.

- [x] **Step 2: Add App lifecycle coordinator owner**

Create `AppLifecycleCoordinator` under App Application. Inject closures for terminal disconnect-all teardown, background suspend, app lock, app sync subscription/refresh, sync-enabled reads, time, app-language handling, and termination timeout sleep. Store background lock, background suspension, remote-notification refresh, and termination teardown requests by UUID; expose pending IDs and await hooks. Keep cancellation as lifecycle state and clear tracked requests deterministically. Do not keep the old blocking termination semaphore bridge: a GREEN attempt proved a MainActor semaphore wait could time out while waiting for MainActor teardown, so termination teardown is tracked asynchronously and macOS termination uses `.terminateLater` plus `reply(toApplicationShouldTerminate:)`.

- [x] **Step 3: Route AppDelegate and root app lifecycle hooks through the coordinator**

Update macOS and iOS `AppDelegate` methods so they only send intent to `AppLifecycleCoordinator.shared`. Preserve behavior: launch starts CloudKit subscription and remote notifications, foreground refresh still respects `SyncSettings.isEnabled` and the 20-second throttle, remote notification completion still calls the system completion handler after refresh, macOS termination waits through `applicationShouldTerminate(_:)` / `.terminateLater` until terminal teardown completes, and iOS background still suspends sessions before locking the app. Update `VVTermApp` `.onAppear` / `.onChange(of: appLanguage)` to apply the language selection and then call `AppLifecycleCoordinator.shared.handleAppLanguageChange(...)` instead of directly calling `ServerManager.shared`.

- [x] **Step 4: Run focused verification**

Run focused tests, scoped source scans, and whitespace check:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppLifecycleCoordinatorTests -only-testing:VVTermTests/AppLifecycleIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "awaitTerminalManagersTeardownBeforeExit|ConnectionSessionManager\\.shared\\.(disconnectAllAndWait|suspendAllForBackground)|TerminalTabManager\\.shared\\.disconnectAllAndWait|AppLockManager\\.shared\\.lockIfNeededForBackground|ServerManager\\.shared\\.handleAppLanguageChange|AppSyncCoordinator\\.shared" VVTerm/App/VVTermApp.swift
git diff --check
```

Actual GREEN result: the focused suite passed 7 Swift Testing tests in 2 suites. Source scans showed direct terminal teardown, background suspend, app-lock, app-sync, and server-language singleton calls moved out of `VVTermApp.swift` and into `AppLifecycleCoordinator`; tracked task scans showed app lock, background suspend, remote notification refresh, and termination teardown expose request IDs plus await hooks. `git diff --check` passed.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `AppLifecycleCoordinator` is the only owner of app delegate lifecycle task orchestration, request API names are imperative and side-effectful, delegate methods remain thin intent senders, termination teardown is timeout-bounded without blocking the main actor, fake tests avoid real CloudKit/app lifecycle calls, and touched tests include enough Test Context / Given / When / Then information for future failure triage.

Actual cleanup result: `AppLifecycleCoordinator` is the App/Application owner for launch, foreground refresh, remote notification refresh, background lock, background suspension, termination teardown, and app-language side effects. AppDelegate methods and root app locale hooks are thin intent senders. The old semaphore bridge was removed instead of moved because it could deadlock or time out on MainActor teardown; macOS now uses the native delayed-termination reply path with a tracked timeout race, and iOS termination sends a tracked best-effort teardown request. Remote notification completion is also tracked by coordinator request ID instead of using an untracked callback task. Tests use fake closures and gates, not real CloudKit/AppKit/UIKit terminal managers.

- [x] **Step 6: Request review and commit**

Request code review for Task 53. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

Actual review result: local lifecycle review found no Critical issues. Important findings were that macOS delayed termination could wait forever if terminal teardown never completed, and remote-notification completion still had an untracked disabled-sync callback task; both were fixed with a timeout race plus tracked remote-notification request IDs before final verification.

## Task 54: Terminal Install Intent Boundary

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/TerminalInstallIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ConnectionSessionManager.startTmuxInstall(for:)`
  - `ConnectionSessionManager.installMoshServerAndReconnect(session:)`
  - `TerminalTabManager.startTmuxInstall(for:)`
  - `TerminalTabManager.installMoshServerAndReconnect(for:)`
  - `RemoteTmuxManager.shared.tmuxInstallBackend(...)`
  - `RemoteTmuxManager.shared.isTmuxAvailable(...)`
  - `RemoteMoshManager.shared.installMoshServer(...)`
- Produces:
  - `ConnectionSessionManager.requestTmuxInstall(for:onCompleted:) -> UUID`: tracked session tmux install request API that coalesces duplicate request intent for the same session.
  - `ConnectionSessionManager.waitForTmuxInstallRequest(_:)` and `pendingTmuxInstallRequestIDs` for awaitable lifecycle ordering tests.
  - `ConnectionSessionManager.requestMoshInstallAndReconnect(session:onCompleted:onFailed:) -> UUID`: tracked session mosh install-then-reconnect request API that coalesces duplicate request intent for the same session and keeps cancellation separate from ordinary failure.
  - `ConnectionSessionManager.waitForMoshInstallRequest(_:)`, `pendingMoshInstallRequestIDs`, and `lastMoshInstallFailure` for awaitable lifecycle ordering and failure tests.
  - `TerminalTabManager.requestTmuxInstall(for:onCompleted:) -> UUID`: tracked pane tmux install request API that coalesces duplicate request intent for the same pane.
  - `TerminalTabManager.waitForTmuxInstallRequest(_:)` and `pendingTmuxInstallRequestIDs` for awaitable pane lifecycle ordering tests.
  - `TerminalTabManager.requestMoshInstallAndReconnect(for:onCompleted:onFailed:) -> UUID`: tracked pane mosh install-then-reconnect request API that coalesces duplicate request intent for the same pane and keeps cancellation separate from ordinary failure.
  - `TerminalTabManager.waitForMoshInstallRequest(_:)`, `pendingMoshInstallRequestIDs`, and `lastMoshInstallFailure` for awaitable pane lifecycle ordering and failure tests.
  - DEBUG-only injected install operations so tests can block tmux/mosh install work without real SSH, tmux, or mosh.

- [x] **Step 1: Add RED install request and source-boundary tests**

Extend `ConnectionLifecycleIntegrationTests` with request-ordering coverage for session and pane install intent. Use delayed fake install closures to prove `requestTmuxInstall` stays pending until the whole install operation completes, `requestMoshInstallAndReconnect` calls `onCompleted` only after install/reconnect work finishes, duplicate request intent for the same session/pane reuses the in-flight request, and ordinary mosh install failure records `lastMoshInstallFailure` plus calls `onFailed` without invoking success. Add `TerminalInstallIntentBoundaryTests` with a Test Context header that reads `TerminalContainerView.swift` and `TerminalView.swift`, then fails while install alert buttons contain UI-owned `Task { ... startTmuxInstall ... }`, UI-owned `Task { ... installMoshServerAndReconnect ... }`, or direct calls to the old async install helpers instead of request APIs.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalInstallIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestTmuxInstall`, `pendingTmuxInstallRequestIDs`, `waitForTmuxInstallRequest(_:)`, `requestMoshInstallAndReconnect`, `pendingMoshInstallRequestIDs`, `waitForMoshInstallRequest(_:)`, `lastMoshInstallFailure`, and DEBUG install-operation injection hooks do not exist. If those compile unexpectedly, `TerminalInstallIntentBoundaryTests` fails because terminal UI install buttons still launch install work inside SwiftUI-owned `Task` blocks.

Actual RED result: after fixing an initial source-boundary test-local `TestFailure` helper mistake, the focused suite failed to compile because `ConnectionSessionManager` and `TerminalTabManager` did not expose `setTmuxInstallOperationForTesting` / `setMoshInstallAndReconnectOperationForTesting`, confirming the new manager-owned install request boundary was absent before implementation.

- [x] **Step 2: Add manager-owned install request tracking**

In `ConnectionSessionManager`, add request dictionaries for tmux install and mosh install keyed by request ID plus per-session in-flight indexes for duplicate coalescing. In `TerminalTabManager`, add the same structure keyed by pane ID. Each request API should return the existing in-flight request ID for duplicate same-entity intent, clear both the request dictionary and the per-entity index in `defer`, and expose await hooks for tests. Mosh install requests should record `lastMoshInstallFailure` and call `onFailed(error)` for ordinary errors, ignore `CancellationError` as lifecycle cancellation, and call `onCompleted()` only after install plus reconnect completes.

- [x] **Step 3: Make tmux install await the install poll instead of scheduling a detached follow-up**

Change `startTmuxInstall(for:)` in both managers so the availability polling loop is awaited by the request task rather than launched as an untracked `Task`. Preserve behavior: set `.installing`, send the install-and-attach script, poll up to six times with the existing two-second interval, bind the managed session/pane on success, and set the unavailable status on failure. Use the DEBUG injected tmux install operation in tests so the focused suite does not wait real seconds or contact a server.

- [x] **Step 4: Route terminal UI install buttons through request APIs**

Update `TerminalContainerView` and split `TerminalView` install alerts so buttons only send synchronous intent to the manager request APIs. UI may keep presentation-only state such as `isInstallingMosh`, `operationNotice`, and `reconnectToken`, but it must not start or await the install task itself. The request callbacks update presentation state after the application-layer owner finishes or fails. Remove private UI helpers that only existed to orchestrate async install/reconnect flows if they become dead code.

- [x] **Step 5: Run focused verification**

Run focused tests, source scans, and whitespace check:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalInstallIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{[^\\n]*(startTmuxInstall|installMoshServerAndReconnect)|startTmuxInstall\\(|installMoshServerAndReconnect\\(" VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift
rg -n "Task \\{ \\[weak self\\] in|Task\\.detached" VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift
git diff --check
```

Expected GREEN result: focused tests pass; terminal UI scans show no UI-owned install `Task` wrappers or direct calls to the old async install helpers; manager task scans show install tasks are stored request tasks or previously classified runtime tasks, not untracked tmux install polling.

Actual GREEN result: focused `xcodebuild test` initially passed 81 Swift Testing tests across `ConnectionLifecycleIntegrationTests` and `TerminalInstallIntentBoundaryTests`; after review-fix coverage it passed 84 Swift Testing tests. The terminal UI install scan produced no matches. `git diff --check` passed. iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. The broad manager task scan still reports previously classified runtime/persist/detached tasks in both managers; the tmux install poll path touched by this task no longer schedules an untracked follow-up task.

- [x] **Step 6: API and boundary cleanup**

Before review, verify request API names are consistent between session and pane managers, install request state lives in TerminalSessions Application rather than UI, UI install callbacks are presentation-only, duplicate request coalescing is manager-owned, cancellation is not surfaced as a user-facing failure, tmux poll tracking is awaitable, and touched tests include Test Context plus Given / When / Then comments and assertion messages.

- [x] **Step 7: Request review and commit**

Request code review for Task 54. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 55: Terminal Retry Intent Boundary

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/TerminalRetryIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `ConnectionSessionManager.retrySessionConnection(session:server:)`
  - `TerminalTabManager.retryPaneConnection(paneId:server:)`
  - `TerminalReconnectRequestResult`
  - Existing manager-owned credential providers and reconnect gates.
- Produces:
  - `ConnectionSessionManager.requestSessionRetry(session:server:onCompleted:) -> UUID`: tracked session retry request API that coalesces duplicate retry intent for the same session and returns one request ID to every caller.
  - `ConnectionSessionManager.waitForSessionRetryRequest(_:)` and `pendingSessionRetryRequestIDs` for awaitable lifecycle ordering tests.
  - `TerminalTabManager.requestPaneRetry(paneId:server:onCompleted:) -> UUID`: tracked split-pane retry request API that coalesces duplicate retry intent for the same pane and returns one request ID to every caller.
  - `TerminalTabManager.waitForPaneRetryRequest(_:)` and `pendingPaneRetryRequestIDs` for awaitable lifecycle ordering tests.
  - DEBUG-only retry operation injection hooks so tests can block retry work without real SSH or Keychain.

- [x] **Step 1: Add RED retry request and source-boundary tests**

Extend `ConnectionLifecycleIntegrationTests` with request-ordering coverage for session and pane retry intent. Use delayed fake retry operations to prove `requestSessionRetry` and `requestPaneRetry` remain pending until the retry operation completes, duplicate same-session/pane retry intent reuses the in-flight request ID, and every duplicate caller receives the final `TerminalReconnectRequestResult`. Add `TerminalRetryIntentBoundaryTests` with a Test Context header that reads `TerminalContainerView.swift` and `TerminalView.swift`, then fails while retry buttons, timeout callbacks, or watchdog callbacks launch SwiftUI-owned `Task { await retryConnection() }` work or call `retrySessionConnection` / `retryPaneConnection` directly from UI.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalRetryIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestSessionRetry`, `pendingSessionRetryRequestIDs`, `waitForSessionRetryRequest(_:)`, `requestPaneRetry`, `pendingPaneRetryRequestIDs`, `waitForPaneRetryRequest(_:)`, and DEBUG retry-operation injection hooks do not exist. If those compile unexpectedly, `TerminalRetryIntentBoundaryTests` fails because terminal retry UI still owns async retry tasks or calls the old async retry helpers directly.

- [x] **Step 2: Add manager-owned retry request tracking**

In `ConnectionSessionManager`, add request dictionaries for session retry keyed by request ID plus a per-session in-flight index for duplicate coalescing. In `TerminalTabManager`, add the same structure keyed by pane ID. Each request API should return the existing in-flight request ID for duplicate same-entity intent, append completion callbacks for every duplicate caller, clear both the request dictionary and per-entity index in `defer`, and expose await hooks for tests. The request task should call the existing async retry behavior boundary or the DEBUG injected fake operation, then publish the final `TerminalReconnectRequestResult` to every callback.

- [x] **Step 3: Route terminal UI retry buttons through request APIs**

Update `TerminalContainerView.retryConnection()` and split `TerminalView.retryConnection()` so they are synchronous presentation helpers. UI may clear transient credential/error state before sending intent and may update `credentials`, `credentialLoadErrorMessage`, `reconnectToken`, and watchdog state in request completion callbacks, but it must not start or await retry tasks itself. Retry buttons, timeout callbacks, and connect watchdog callbacks should call the synchronous helper directly.

- [x] **Step 4: Run focused verification**

Run focused tests, source scans, and whitespace check:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalRetryIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{[^\\n]*await retryConnection|await retryConnection\\(|retrySessionConnection\\(|retryPaneConnection\\(" VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift
rg -n "Task \\{ \\[weak self\\] in|Task\\.detached" VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift
git diff --check
```

Expected GREEN result: focused tests pass; terminal UI retry scans show no UI-owned retry `Task` wrappers or direct calls to the old async retry helpers; manager task scans show retry tasks are stored request tasks or previously classified runtime tasks.

- [x] **Step 5: API and boundary cleanup**

Before review, verify request API names are consistent between session and pane managers, retry request state lives in TerminalSessions Application rather than UI, UI retry callbacks are presentation-only, duplicate request coalescing is manager-owned, cancellation is not surfaced as a credential failure, and touched tests include Test Context plus Given / When / Then comments and assertion messages.

- [x] **Step 6: Request review and commit**

Request code review for Task 55. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 56: Terminal Voice Input Intent Boundary

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Application/TerminalVoiceInputStore.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/VoiceRecordingView.swift`
- Test: `VVTermTests/TerminalVoiceInputStoreTests.swift`
- Test: `VVTermTests/TerminalVoiceInputIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `AudioService.startRecording()`, `stopRecording()`, `cancelRecording()`, and published voice state.
  - `ConnectionSessionManager.sendText(_:to:)` for root sessions.
  - `TerminalTabManager.getTerminal(for:)` / pane terminal send behavior for split panes until a narrower pane send-text API is introduced.
  - Existing `onVoiceRecordingChange` and `onVoiceTranscriptionSent` presentation callbacks.
- Produces:
  - `TerminalVoiceInputTarget: Hashable` with `.session(UUID)` and `.pane(UUID)` cases.
  - `TerminalVoiceInputStore`: TerminalSessions Application owner for terminal voice recording state and audio start/stop/cancel tasks.
  - `TerminalVoiceInputStore.requestStart(for:onStarted:onFailed:) -> UUID`: tracked start request that owns permission/audio startup work and keeps UI to presentation callbacks.
  - `TerminalVoiceInputStore.requestStopAndSend(for:onCompleted:) -> UUID`: tracked stop/transcribe request that publishes processing state and returns the final text to UI callbacks.
  - `TerminalVoiceInputStore.requestCancel(for:onCancelled:) -> UUID`: tracked cancellation request that clears audio state without surfacing cancellation as a permission/transcription failure.
  - `TerminalVoiceInputStore.waitForVoiceRequest(_:)` and `pendingVoiceRequestIDs` for awaitable lifecycle ordering tests.
  - A narrow audio service protocol seam so tests can block start/stop/cancel without real microphone, Speech, MLX, or permissions.

- [x] **Step 1: Add RED voice input store and source-boundary tests**

Add `TerminalVoiceInputStoreTests` with a Test Context header. Use a fake audio service whose start and stop operations can be blocked. Cover:
- start request remains pending until audio startup completes and then calls `onStarted`;
- failed start records a permission/user-facing message and calls `onFailed`;
- stop request remains pending until transcription completes and then calls `onCompleted` with the final text, using partial transcription as fallback when the final text is empty;
- cancel request clears recording/processing state and does not become a user-facing failure.

Add `TerminalVoiceInputIntentBoundaryTests` with a Test Context header. The tests must inspect `TerminalContainerView.swift`, split `TerminalView.swift`, and `VoiceRecordingView.swift`, then fail while terminal UI:
- declares `@StateObject private var audioService = AudioService()`;
- calls `audioService.startRecording()`, `audioService.stopRecording()`, or `audioService.cancelRecording()` directly;
- launches voice lifecycle `Task { ... }` blocks from button, keyboard, overlay, or trigger handlers.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalVoiceInputStoreTests -only-testing:VVTermTests/TerminalVoiceInputIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `TerminalVoiceInputStore`, `TerminalVoiceInputTarget`, tracked request APIs, await hooks, and the fake-audio seam do not exist. If those compile unexpectedly, the source-boundary test fails because terminal voice UI still owns `AudioService` and direct start/stop/cancel tasks.

- [x] **Step 2: Add the application-layer voice input owner**

Create `TerminalVoiceInputStore` under TerminalSessions Application. Keep the store `@MainActor` because it bridges published audio state into SwiftUI presentation, but keep actual microphone/Speech/MLX work inside the existing `AudioService` / VoiceInput infrastructure boundary. The store should:
- own one stable `AudioService` instance by default;
- expose published presentation state that `VoiceRecordingView` needs: recording, processing, partial/final transcription, audio level, and recording duration;
- track voice request tasks by request ID;
- coalesce duplicate start/stop/cancel intent for the same `TerminalVoiceInputTarget` while an equivalent request is pending;
- treat cancellation as lifecycle completion, not as a permission or transcription error;
- provide DEBUG/test initialization with a fake audio service.

- [x] **Step 3: Route root terminal voice UI through the store**

Update `TerminalContainerView` so it observes the application voice store instead of creating `AudioService`. `startVoiceRecording()`, `toggleVoiceRecording()`, escape-key cancel, overlay cancel, and send actions should call the store request APIs synchronously. UI may still update overlay visibility, permission alerts, notice presentation, and `onVoiceRecordingChange` / `onVoiceTranscriptionSent` in callbacks, but it must not call audio start/stop/cancel directly or launch a voice lifecycle task.

- [x] **Step 4: Route split terminal voice UI through the same boundary**

Update split `TerminalView` and `VoiceRecordingView` the same way. Preserve existing split-pane behavior: voice text is sent only to the focused terminal and only after a successful stop/send completion. If split pane text sending still requires direct `GhosttyTerminalView`, keep that as a named Task 56 limitation in the Progress Ledger; do not widen this task into pane text-send ownership unless the tests require it.

- [x] **Step 5: Run focused verification**

Run focused tests, source scans, and whitespace check:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalVoiceInputStoreTests -only-testing:VVTermTests/TerminalVoiceInputIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "@StateObject private var audioService|audioService\\.(startRecording|stopRecording|cancelRecording)|Task \\{" VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift VVTerm/Features/TerminalSessions/UI/Terminal/VoiceRecordingView.swift
git diff --check
```

Expected GREEN result: focused tests pass; voice source scan shows no UI-owned `AudioService` or direct voice lifecycle tasks; any remaining `Task` hits in the scanned files are unrelated, previously classified terminal lifecycle tasks and must be named in the Progress Ledger.

- [x] **Step 6: API and boundary cleanup**

Before review, verify the voice request API names are consistent with Task 54/55 request APIs, the long-lived audio service is owned by TerminalSessions Application / VoiceInput Infrastructure rather than SwiftUI views, UI callbacks remain presentation-only, cancellation is separate from permission/transcription failure, and touched tests include Test Context plus Given / When / Then comments and assertion messages.

- [x] **Step 7: Request review and commit**

Request code review for Task 56. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 57: Terminal Host Retrust Intent Boundary

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/TerminalRetrustIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `ConnectionSessionManager.retrustHostAndReconnect(session:server:) async -> Bool`.
  - Existing `TerminalTabManager.retrustHostAndReconnect(paneId:server:) async -> Bool`.
  - `KnownHostsStore.shared.remove(host:port:)` through the existing manager-owned retrust helpers.
  - Existing root/split terminal alert presentation and `reconnectToken` refresh behavior.
- Produces:
  - `ConnectionSessionManager.requestSessionHostRetrust(session:server:onCompleted:) -> UUID`: tracked root-session host-retrust request that owns trusted-host removal plus reconnect lifecycle.
  - `ConnectionSessionManager.pendingSessionHostRetrustRequestIDs` and `waitForSessionHostRetrustRequest(_:)` for lifecycle ordering tests.
  - `TerminalTabManager.requestPaneHostRetrust(paneId:server:onCompleted:) -> UUID`: tracked split-pane host-retrust request that owns trusted-host removal plus reconnect lifecycle.
  - `TerminalTabManager.pendingPaneHostRetrustRequestIDs` and `waitForPaneHostRetrustRequest(_:)` for lifecycle ordering tests.
  - DEBUG-only operation injection seams matching the existing retry request seams, so tests can block retrust work without touching real known-host storage or network.

- [x] **Step 1: Add RED host-retrust request and source-boundary tests**

Add manager lifecycle tests to `ConnectionLifecycleIntegrationTests` with the existing Test Context. Cover:
- duplicate root-session host-retrust intent for the same session coalesces to one request ID, remains pending while the manager-owned operation is blocked, and calls every completion callback with the final reconnect decision;
- duplicate split-pane host-retrust intent for the same pane coalesces the same way;
- cancellation reports `false` to callbacks and clears pending request state rather than surfacing a credential or reconnect failure.

Add `TerminalRetrustIntentBoundaryTests` with a Test Context header. The tests must inspect `TerminalContainerView.swift` and split `TerminalView.swift`, then fail while terminal UI:
- launches a `Task { ... }` from `retrustHostAndRetry()`;
- directly calls or awaits `retrustHostAndReconnect(...)`;
- omits the new request API in the retrust helper slice.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalRetrustIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because the request APIs, pending request IDs, wait hooks, and DEBUG operation seams do not exist. If those compile unexpectedly, the source-boundary tests fail because SwiftUI still owns retrust `Task` wrappers and directly awaits the old async helpers.

- [x] **Step 2: Add manager-owned host-retrust request tracking**

Add small request structs and dictionaries to both terminal managers. Match the Task 55 retry request style:
- coalesce duplicate request intent by session or pane ID;
- keep the underlying task stored until retrust/reconnect completes;
- call every queued callback with `false` on cancellation and with the helper result otherwise;
- remove request dictionaries and reverse indexes in `defer`;
- expose pending IDs and wait hooks for tests.

Keep the old async `retrustHostAndReconnect` helpers as lower-level manager operations for now, but make SwiftUI stop calling them directly.

- [x] **Step 3: Route terminal UI host-retrust buttons through request APIs**

Update root `TerminalContainerView.retrustHostAndRetry()` and split `TerminalView.retrustHostAndRetry()` so the alert button sends synchronous intent to the manager request API. UI may still update `reconnectToken` in the completion callback when the request reports success, but must not create a `Task` or await trusted-host removal/reconnect work.

- [x] **Step 4: Run focused verification**

Run focused tests, source scans, and whitespace check:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalRetrustIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{|retrustHostAndReconnect|requestSessionHostRetrust|requestPaneHostRetrust" VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows `retrustHostAndRetry()` uses request APIs and no retrust helper owns `Task {}` or direct awaits. Remaining `Task {}` hits in these files are previously classified non-retrust terminal paths and must be named in the Progress Ledger.

- [x] **Step 5: API and boundary cleanup**

Before review, verify the new API names align with Task 55 retry request names, the host-trust mutation remains application-owned, callbacks are presentation-only, cancellation is lifecycle completion, and touched tests include the required Test Context plus Given / When / Then comments and assertion messages.

- [x] **Step 6: Request review and commit**

Request code review for Task 57. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 58: App-Owned Server Disconnect Intent Boundary

**Files:**
- Create: `VVTerm/App/Application/ServerConnectionLifecycleCoordinator.swift`
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift`
- Test: `VVTermTests/ServerConnectionLifecycleCoordinatorTests.swift`
- Test: `VVTermTests/ServerDisconnectIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - `RemoteFileBrowserStore.disconnect(serverId:) -> Task<Void, Never>`
  - `RemoteFileTabManager.disconnect(serverId:)`
  - `ConnectionSessionManager.disconnectServerAndWait(_:)`
  - `TerminalTabManager.disconnectServerAndWait(_:)`
  - Existing iOS active-connection and current-server disconnect UI callbacks.
- Produces:
  - `@MainActor final class ServerConnectionLifecycleCoordinator` in App/Application as the cross-feature owner for server-scoped disconnect request orchestration.
  - `ServerConnectionLifecycleCoordinator.requestServerDisconnect(serverId:disconnectRemoteFiles:disconnectFileTabs:disconnectTerminals:onCompleted:) -> UUID`: starts a tracked request that awaits RemoteFiles teardown, clears file tabs, awaits the supplied terminal disconnect action, and runs completion only after all application-layer teardown is done.
  - `ServerConnectionLifecycleCoordinator.pendingDisconnectRequestIDs: Set<UUID>` and `waitForDisconnectRequest(_:)` for lifecycle ordering tests.
  - Duplicate same-server disconnect intent should coalesce to one request ID and append completion callbacks rather than launching parallel teardown chains.

- [x] **Step 1: Add RED app-owned disconnect orchestration tests**

Add `ServerConnectionLifecycleCoordinatorTests` with the required Test Context. Cover:
- a request remains pending while RemoteFiles teardown is blocked, does not call terminal disconnect or completion early, then runs RemoteFiles, file-tab cleanup, terminal disconnect, and completion in order;
- duplicate disconnect intent for the same server coalesces to one request ID and both callbacks run after the single teardown chain finishes;
- cancellation or superseded close should not be modeled as a terminal/auth failure; this task only needs lifecycle completion semantics, not user-facing error state.

Add `ServerDisconnectIntentBoundaryTests` with a Test Context header. Source-scan `iOSContentView.swift` and `ConnectionTabsView.swift` and fail while UI still:
- creates `Task { ... disconnectServerAndWait ... }` inside `disconnectActiveConnection`, `disconnectCurrentServerSessions`, or `disconnectFromServer`;
- directly sequences `fileBrowser.disconnect(serverId:)`, `fileTabs.disconnect(serverId:)` / `fileTabManager.disconnect(serverId:)`, and terminal manager disconnect in SwiftUI;
- omits `ServerConnectionLifecycleCoordinator.shared.requestServerDisconnect(...)`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerConnectionLifecycleCoordinatorTests -only-testing:VVTermTests/ServerDisconnectIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `ServerConnectionLifecycleCoordinator` does not exist. If it compiles unexpectedly, the boundary tests fail because SwiftUI still owns the disconnect `Task` wrappers and direct multi-step teardown sequencing.

- [x] **Step 2: Add the App/Application disconnect coordinator**

Implement `ServerConnectionLifecycleCoordinator` as a `@MainActor` final class with `shared`, request dictionaries keyed by request ID, and a reverse index keyed by server ID. Store the request `Task<Void, Never>` until teardown finishes. The task order must be:
1. call `disconnectRemoteFiles(serverId)` and await its returned task;
2. call `disconnectFileTabs(serverId)` if supplied;
3. await `disconnectTerminals(serverId)`;
4. run every queued completion callback.

Do not make the coordinator import RemoteFiles or TerminalSessions concrete managers directly for tests. Accept closures at the request boundary so iOS root sessions can pass `ConnectionSessionManager.disconnectServerAndWait(_:)` and split-tab UI can pass `TerminalTabManager.disconnectServerAndWait(_:)` while the coordinator still owns the request task and ordering.

- [x] **Step 3: Route iOS and tab disconnect UI through the coordinator**

Update:
- `iOSContentView.disconnectActiveConnection(_:)` to call `ServerConnectionLifecycleCoordinator.shared.requestServerDisconnect(...)` with `fileBrowser.disconnect`, no file-tab disconnect callback, and `sessionManager.disconnectServerAndWait`.
- `iOSContentView.disconnectCurrentServerSessions()` to call the same coordinator with `fileBrowser.disconnect`, `fileTabs.disconnect`, `sessionManager.disconnectServerAndWait`, and `onCompleted: onBack`.
- `ConnectionTabsView.disconnectFromServer()` to call the coordinator with `fileBrowser.disconnect`, `fileTabManager.disconnect`, and `tabManager.disconnectServerAndWait`.

The UI functions should become synchronous intent senders. They may update presentation state from `onCompleted`, but must not own the async teardown sequence.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerConnectionLifecycleCoordinatorTests -only-testing:VVTermTests/ServerDisconnectIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "disconnectActiveConnection|disconnectCurrentServerSessions|disconnectFromServer|Task \\{|disconnectServerAndWait|requestServerDisconnect|fileBrowser.disconnect|fileTabs.disconnect|fileTabManager.disconnect" VVTerm/App/iOS/iOSContentView.swift VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows the three disconnect helpers use `requestServerDisconnect(...)`, contain no helper-local `Task {}` wrappers, and do not directly sequence RemoteFiles/file-tabs/terminal teardown in SwiftUI. Remaining `Task {}` hits in these files are existing non-disconnect paths and must be named in the Progress Ledger.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `ServerConnectionLifecycleCoordinator` belongs in App/Application because it coordinates App-shell cross-feature lifecycle work, the closure labels read as side-effectful actions, the coordinator does not own UI presentation state, duplicate same-server request coalescing cannot drop callbacks, and touched tests include the required Test Context plus Given / When / Then comments and assertion messages.

- [x] **Step 6: Request review and commit**

Request code review for Task 58. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 59: Terminal Surface Attach Intent Boundary

**Files:**
- Create: `VVTermTests/TerminalSurfaceAttachIntentTests.swift`
- Create: `VVTermTests/TerminalSurfaceAttachBoundaryTests.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `ConnectionSessionManager.attachSurface(_:to:)` and `TerminalTabManager.attachSurface(_:toPane:)` async runtime-start boundaries.
  - Existing shell state helpers: `shellId(for:)`, `isShellStartInFlight(for:)`, `consumeTerminalReconnectReset(for:)`, `isSuspendingForBackground`, and pane equivalents.
  - Existing representable callbacks that know whether the SwiftUI scene/pane is active and hold the concrete `GhosttyTerminalView`.
- Produces:
  - `TerminalSurfaceAttachContext` with value-only inputs the UI can supply, such as `isAppActive`, `isViewActive`, and `autoReconnectEnabled`.
  - `ConnectionSessionManager.requestSurfaceAttach(sessionId:terminal:context:resetTerminal:) -> UUID?`: starts a tracked application-owned request that decides whether a root session surface should attach/start runtime, consumes reconnect reset only when attaching, and calls `attachSurface(_:to:)` from the manager-owned task.
  - `TerminalTabManager.requestSurfaceAttach(paneId:terminal:context:) -> UUID?`: same request boundary for split panes.
  - `pendingSurfaceAttachRequestIDs` and `waitForSurfaceAttachRequest(_:)` on both managers for lifecycle tests.
  - DEBUG-only attach operation seams that let tests prove attach/no-attach decisions without constructing a real `GhosttyTerminalView`.

- [x] **Step 1: Add RED surface attach policy/request tests**

Add `TerminalSurfaceAttachIntentTests` with the required Test Context. Cover:
- a root session attach request does not run attach when app/scene is inactive or background suspend is in progress;
- a root session attach request does not consume reconnect reset when attach is rejected, and does consume it only when attach proceeds;
- a root session attach request refuses duplicate runtime start when a shell already exists or shell start is already in flight;
- a disconnected root session attaches only when the UI reports active view state and auto-reconnect is enabled;
- a split-pane attach request uses the same shell-missing / shell-start-in-flight guard and tracks the request until the attach operation finishes.

Add `TerminalSurfaceAttachBoundaryTests` with a Test Context header. Source-scan:
- `SSHTerminalWrapper.swift` must call `requestSurfaceAttach(...)` and must not call `shellId(for:)`, `isShellStartInFlight(for:)`, `consumeTerminalReconnectReset(for:)`, or directly create an attach `Task { await ConnectionSessionManager.shared.attachSurface(...) }`;
- `TerminalView.swift` split wrapper must call `TerminalTabManager.shared.requestSurfaceAttach(...)` and must not directly create an attach `Task { await TerminalTabManager.shared.attachSurface(...) }`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalSurfaceAttachIntentTests -only-testing:VVTermTests/TerminalSurfaceAttachBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `TerminalSurfaceAttachContext`, `requestSurfaceAttach(...)`, pending request IDs, wait hooks, and DEBUG attach seams do not exist. If it compiles unexpectedly, boundary tests fail because representables still own shell-state checks and attach `Task` wrappers.

- [x] **Step 2: Add manager-owned root session surface attach requests**

Implement `TerminalSurfaceAttachContext` and root-session request tracking in `ConnectionSessionManager`. The request should:
1. reject missing sessions without creating a task;
2. reject inactive app/scene or `isSuspendingForBackground`;
3. evaluate the current session state and context to decide whether a disconnected session should auto-reconnect;
4. reject when a shell already exists or shell start is in flight;
5. consume reconnect reset and call the supplied `resetTerminal` only after the attach decision is accepted;
6. run `attachSurface(_:to:)` from a stored task and clear tracking in `defer`.

Expose `pendingSurfaceAttachRequestIDs` and `waitForSurfaceAttachRequest(_:)` for tests. Use a DEBUG attach-operation seam so tests can count attach attempts without creating `GhosttyTerminalView`. Keep existing `attachSurface(_:to:)` as the low-level async boundary used by the request task.

- [x] **Step 3: Add split-pane surface attach requests**

Add equivalent request tracking to `TerminalTabManager` for pane surfaces. It should reject missing pane state, shell already exists, shell start in flight, inactive app/scene, and background-like inactive context before starting the task. Expose the same pending IDs and wait hook. Keep pane-specific behavior narrower than root sessions: no auto-reconnect preference or reconnect-reset consumption unless an existing pane-specific reset flag already exists.

- [x] **Step 4: Route representable attach callbacks through request APIs**

Update `SSHTerminalWrapper` macOS and iOS attach paths:
- coordinator `attachSurface(_:)` should synchronously call `ConnectionSessionManager.shared.requestSurfaceAttach(...)`;
- reused-terminal and `onReady` paths should pass value context such as active scene/app state, active view state, and auto-reconnect preference, then let the manager decide shell state and reset consumption;
- remove direct wrapper reads of `shellId(for:)`, `isShellStartInFlight(for:)`, `consumeTerminalReconnectReset(for:)`, and `isSuspendingForBackground` from attach/start decisions.

Update `SSHTerminalPaneWrapper` in `TerminalView.swift`:
- coordinator `attachSurface(_:)` should synchronously call `TerminalTabManager.shared.requestSurfaceAttach(...)`;
- reused and `onReady` paths should no longer directly read shell state before attaching.

This task deliberately leaves resize/input/rich-paste callback `Task` bridges for later slices unless the focused tests force a small helper rename.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalSurfaceAttachIntentTests -only-testing:VVTermTests/TerminalSurfaceAttachBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "attachSurface\\(|requestSurfaceAttach|shellId\\(for:|isShellStartInFlight|consumeTerminalReconnectReset|Task \\{[^\\n]*attachSurface|resizeSession|resizePane" VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows attach paths use request APIs and representables no longer own shell-state/reconnect-reset attach policy. Remaining `Task` hits for send input, resize, rich paste, title/background parsing, and file navigation must be named in the Progress Ledger as deferred slices.

- [x] **Step 6: API and boundary cleanup**

Before review, verify request API names match the previous `requestSessionRetry`, `requestPaneRetry`, and `requestServerDisconnect` style; UI supplies only value context and presentation callbacks; managers own shell/runtimes/reconnect-reset decisions; DEBUG seams are reset in test cleanup; tests include the required Test Context and Given / When / Then comments.

- [x] **Step 7: Request review and commit**

Request code review for Task 59. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 60: Terminal Input Intent Boundary

**Files:**
- Create: `VVTermTests/TerminalInputIntentTests.swift`
- Create: `VVTermTests/TerminalInputBoundaryTests.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing low-level async runtime input APIs: `ConnectionSessionManager.sendInput(_:to:)` and `TerminalTabManager.sendInput(_:toPane:)`.
  - Existing terminal surface callbacks `GhosttyTerminalView.writeCallback`.
  - Existing manager reset hooks and DEBUG runtime test seams.
- Produces:
  - `ConnectionSessionManager.requestSessionInput(_ data: Data, to sessionId: UUID) -> UUID?`: rejects empty input or missing sessions, serializes accepted input requests per session in the manager, stores the request task, and calls `sendInput(_:to:)` from manager-owned request work.
  - `TerminalTabManager.requestPaneInput(_ data: Data, toPane paneId: UUID) -> UUID?`: same request boundary for split panes.
  - `pendingInputRequestIDs` and `waitForInputRequest(_:)` on both managers for lifecycle tests.
  - DEBUG-only input operation seams that let tests prove input/no-input decisions and write ordering without constructing `GhosttyTerminalView` or opening SSH.

- [x] **Step 1: Add RED input request and boundary tests**

Add `TerminalInputIntentTests` with the required Test Context. Cover:
- a root session input request rejects empty `Data` or missing sessions without creating a task;
- a root session input request stays tracked until the send operation finishes;
- rapid root input requests for the same session are serialized in request order;
- a split-pane input request rejects empty `Data` or missing pane state without creating a task;
- rapid split-pane input requests for the same pane are serialized in request order.

Add `TerminalInputBoundaryTests` with a Test Context header. Source-scan:
- `SSHTerminalWrapper.swift` write callbacks must call `requestSessionInput(_:to:)` and must not create `Task { await ConnectionSessionManager.shared.sendInput(...) }`;
- `TerminalView.swift` split wrapper write callbacks must call `TerminalTabManager.shared.requestPaneInput(_:toPane:)` and must not create `Task { await TerminalTabManager.shared.sendInput(...) }`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalInputIntentTests -only-testing:VVTermTests/TerminalInputBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestSessionInput(...)`, `requestPaneInput(...)`, pending input request IDs, wait hooks, and DEBUG input seams do not exist. If it compiles unexpectedly, boundary tests fail because representables still own input `Task` wrappers.

- [x] **Step 2: Add manager-owned root session input requests**

Implement root-session input request tracking in `ConnectionSessionManager`. The request should:
1. reject empty input without creating a task;
2. reject missing sessions without creating a task;
3. append accepted input to a per-session request queue so rapid writes preserve order;
4. run the send loop from a stored task and clear tracking in `defer`;
5. call `sendInput(_:to:)` one queued payload at a time;
6. expose `pendingInputRequestIDs` and `waitForInputRequest(_:)` for tests.

Use a DEBUG input-operation seam so tests can count send attempts without real SSH. Keep existing `sendInput(_:to:)` as the low-level async boundary used by the request task.

- [x] **Step 3: Add split-pane input requests**

Add equivalent request tracking to `TerminalTabManager` for pane input. It should reject missing pane state and empty payloads, serialize rapid pane input in request order, expose pending IDs and a wait hook, and keep existing `sendInput(_:toPane:)` as the low-level async boundary.

- [x] **Step 4: Route representable input callbacks through request APIs**

Update `SSHTerminalWrapper` macOS and iOS write callbacks:
- reused-terminal and newly-created-terminal paths should call `ConnectionSessionManager.shared.requestSessionInput(data, to: sessionId)`;
- remove coordinator-owned `Task { await ConnectionSessionManager.shared.sendInput(...) }` wrappers from write callbacks and `SSHTerminalCoordinator.sendToSSH(_:)`.

Update `SSHTerminalPaneWrapper` in `TerminalView.swift`:
- reused and newly-created pane write callbacks should call `TerminalTabManager.shared.requestPaneInput(data, toPane: paneId)`;
- remove direct `Task { await TerminalTabManager.shared.sendInput(...) }` wrappers from write callbacks and `SSHTerminalPaneWrapper.Coordinator.sendToSSH(_:)`.

This task deliberately leaves resize, rich-paste, title/background parsing, process-exit, and RemoteFiles navigation `Task` bridges for later slices.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalInputIntentTests -only-testing:VVTermTests/TerminalInputBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "sendInput\\(|requestSessionInput|requestPaneInput|Task \\{[^\\n]*sendInput|Task\\([^\\n]*sendInput" VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows input callbacks use request APIs and representables no longer own input `Task` wrappers. Remaining `Task` hits for resize, rich paste, title/background parsing, process exit, and file navigation must be named in the Progress Ledger as deferred slices.

- [x] **Step 6: API and boundary cleanup**

Before review, verify request API names match the previous `requestSurfaceAttach`, `requestSessionRetry`, and `requestPaneRetry` style; UI supplies only input bytes; managers own request tracking and low-level send invocation; DEBUG seams are reset in test cleanup; tests include the required Test Context and Given / When / Then comments.

- [x] **Step 7: Request review and commit**

Request code review for Task 60. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 61: Terminal Resize Intent Boundary

**Files:**
- Create: `VVTermTests/TerminalResizeIntentTests.swift`
- Create: `VVTermTests/TerminalResizeBoundaryTests.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing low-level async runtime resize APIs: `ConnectionSessionManager.resizeSession(_:cols:rows:)` and `TerminalTabManager.resizePane(_:cols:rows:)`.
  - Existing terminal surface callbacks `GhosttyTerminalView.onResize`.
  - Existing iOS active-connection redraw path that reads `terminal.terminalSize()`.
  - Existing manager reset hooks and DEBUG runtime test seams.
- Produces:
  - `ConnectionSessionManager.requestSessionResize(_ size: TerminalResizeRequestSize, for sessionId: UUID) -> UUID?`: rejects invalid sizes or missing sessions, stores/tracks accepted resize request work, coalesces rapid same-session resizes to the latest size, and calls `resizeSession(_:cols:rows:)` from manager-owned request work.
  - `TerminalTabManager.requestPaneResize(_ size: TerminalResizeRequestSize, forPane paneId: UUID) -> UUID?`: same request boundary for split panes.
  - `TerminalResizeRequestSize: Equatable, Sendable` with positive `cols` and `rows` values.
  - `pendingResizeRequestIDs` and `waitForResizeRequest(_:)` on both managers for lifecycle tests.
  - DEBUG-only resize operation seams that let tests prove resize/no-resize decisions and coalescing without constructing `GhosttyTerminalView` or opening SSH.

- [x] **Step 1: Add RED resize request and boundary tests**

Add `TerminalResizeIntentTests` with the required Test Context. Cover:
- a root session resize request rejects non-positive sizes or missing sessions without creating a task;
- a root session resize request stays tracked until the resize operation finishes;
- rapid root resize requests for the same session coalesce to the latest size and clear stale request bookkeeping;
- root session close clears/cancels pending resize requests through the real `closeSessionAndWait(...)` path;
- equivalent split-pane behavior for invalid/missing panes, pending tracking, latest-size coalescing, and `closePaneAndWait(...)` cleanup.

Add `TerminalResizeBoundaryTests` with a Test Context header. Source-scan:
- `SSHTerminalWrapper.swift` resize callbacks must call `ConnectionSessionManager.shared.requestSessionResize(...)` and must not create `Task { await ConnectionSessionManager.shared.resizeSession(...) }`;
- `TerminalView.swift` split wrapper resize callbacks must call `TerminalTabManager.shared.requestPaneResize(...)` and must not create `Task { await TerminalTabManager.shared.resizePane(...) }`;
- `iOSContentView.swift` active-connection redraw resize path must call `ConnectionSessionManager.shared.requestSessionResize(...)` and must not create `Task { await ConnectionSessionManager.shared.resizeSession(...) }`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalResizeIntentTests -only-testing:VVTermTests/TerminalResizeBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `TerminalResizeRequestSize`, `requestSessionResize(...)`, `requestPaneResize(...)`, pending resize request IDs, wait hooks, and DEBUG resize seams do not exist. If it compiles unexpectedly, boundary tests fail because representables and iOS redraw still own resize `Task` wrappers.

- [x] **Step 2: Add manager-owned root session resize requests**

Implement root-session resize request tracking in `ConnectionSessionManager`. The request should:
1. reject invalid sizes without creating a task;
2. reject missing sessions without creating a task;
3. coalesce duplicate same-session accepted requests by updating the stored latest size and returning the existing request ID;
4. run the low-level resize from a stored task and clear tracking in `defer`;
5. re-read the latest stored size before calling `resizeSession(_:cols:rows:)`;
6. drop the resize if the session is gone before the request runs;
7. cancel/clear pending resize requests when the session closes or test cleanup resets the manager;
8. expose `pendingResizeRequestIDs` and `waitForResizeRequest(_:)` for tests.

Use a DEBUG resize-operation seam so tests can count resize attempts without real SSH. Keep existing `resizeSession(_:cols:rows:)` as the low-level async boundary used by the request task.

- [x] **Step 3: Add split-pane resize requests**

Add equivalent request tracking to `TerminalTabManager` for pane resize. It should reject missing pane state and invalid sizes, coalesce rapid pane resizes to the latest size, expose pending IDs and a wait hook, cancel/clear pending resize when a pane closes, and keep existing `resizePane(_:cols:rows:)` as the low-level async boundary.

- [x] **Step 4: Route UI resize callbacks through request APIs**

Update `SSHTerminalWrapper` macOS and iOS resize callbacks:
- reused-terminal and newly-created-terminal paths should call `ConnectionSessionManager.shared.requestSessionResize(.init(cols: cols, rows: rows), for: sessionId)`;
- remove UI-owned `Task { await ConnectionSessionManager.shared.resizeSession(...) }` wrappers.

Update `SSHTerminalPaneWrapper` in `TerminalView.swift`:
- reused and newly-created pane resize callbacks should call `TerminalTabManager.shared.requestPaneResize(.init(cols: cols, rows: rows), forPane: paneId)`;
- remove direct `Task { await TerminalTabManager.shared.resizePane(...) }` wrappers.

Update `iOSContentView` active-connection redraw:
- after reading `terminal.terminalSize()`, call `ConnectionSessionManager.shared.requestSessionResize(...)` synchronously;
- remove the redraw-local resize `Task` wrapper.

This task deliberately leaves rich paste, title/PWD/background callbacks, process-exit/pane lifecycle callbacks, RemoteFiles navigation/preview/drop/file-representation tasks, and Stats retry tasks for later slices.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalResizeIntentTests -only-testing:VVTermTests/TerminalResizeBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "resizeSession\\(|resizePane\\(|requestSessionResize|requestPaneResize|Task \\{[^\\n]*resize|Task\\([^\\n]*resize" VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift VVTerm/App/iOS/iOSContentView.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows resize callbacks use request APIs and UI files no longer own resize `Task` wrappers. Remaining `Task` hits for rich paste, title/background parsing, process exit, RemoteFiles navigation, Stats retry, and credential reload must be named in the Progress Ledger as deferred slices.

- [x] **Step 6: API and boundary cleanup**

Before review, verify request API names match the previous `requestSurfaceAttach`, `requestSessionInput`, and `requestPaneInput` style; UI supplies only positive terminal dimensions; managers own request tracking, coalescing, cancellation, and low-level resize invocation; DEBUG seams are reset in test cleanup; tests include the required Test Context and Given / When / Then comments.

- [x] **Step 7: Request review and commit**

Request code review for Task 61. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 62: Terminal Pane Process Exit Intent Boundary

**Files:**
- Create: `VVTermTests/TerminalProcessExitIntentTests.swift`
- Create: `VVTermTests/TerminalProcessExitBoundaryTests.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing low-level pane process-exit behavior: `TerminalTabManager.handlePaneExit(for:)`.
  - Existing split terminal surface callback `GhosttyTerminalView.onProcessExit`.
  - Existing pane close/reset cleanup paths.
- Produces:
  - `TerminalTabManager.requestPaneProcessExit(forPane paneId: UUID) -> UUID?`: rejects missing panes, stores/tracks accepted pane process-exit request work, coalesces duplicate same-pane exits, and runs `handlePaneExit(for:)` from manager-owned request work.
  - `pendingProcessExitRequestIDs` and `waitForProcessExitRequest(_:)` on `TerminalTabManager` for lifecycle tests.
  - DEBUG-only process-exit operation seams that let tests prove request ordering and close cancellation without constructing `GhosttyTerminalView` or opening SSH.

- [x] **Step 1: Add RED process-exit request and boundary tests**

Add `TerminalProcessExitIntentTests` with the required Test Context. Cover:
- a pane process-exit request rejects missing panes without creating a task;
- a pane process-exit request stays tracked until the process-exit operation finishes;
- duplicate pane process-exit requests for the same pane coalesce to one request ID and call the operation once;
- pane close clears/cancels pending process-exit requests through the real `closePaneAndWait(...)` path.

Add `TerminalProcessExitBoundaryTests` with a Test Context header. Source-scan:
- `TerminalView.swift` split-pane exit handling must call the injected `tabManager.requestPaneProcessExit(forPane:)` and must not create `Task { await tabManager.handlePaneExit(...) }`;
- split `SSHTerminalPaneWrapper` may continue to assign `terminalView.onProcessExit = onProcessExit`, but must not own process-exit request tasks or call low-level pane exit handlers directly.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalProcessExitIntentTests -only-testing:VVTermTests/TerminalProcessExitBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestPaneProcessExit(...)`, pending process-exit request IDs, wait hooks, and DEBUG process-exit seams do not exist. If it compiles unexpectedly, boundary tests fail because split process exit still uses a SwiftUI-owned `Task` wrapper.

RED result: `xcodebuild test ... -only-testing:VVTermTests/TerminalProcessExitIntentTests -only-testing:VVTermTests/TerminalProcessExitBoundaryTests ENABLE_DEBUG_DYLIB=NO` failed to build because `TerminalTabManager` had no `setProcessExitOperationForTesting(...)`; the remaining missing request/pending/wait APIs were still unimplemented at the same boundary.

- [x] **Step 2: Add split-pane process-exit requests**

Add equivalent request tracking to `TerminalTabManager` for pane process exit. It should reject missing pane state, coalesce duplicate pane exits, expose pending IDs and a wait hook, cancel/clear pending process-exit when a pane closes, and keep existing `handlePaneExit(for:)` as the low-level async boundary.

- [x] **Step 3: Route split UI process-exit callbacks through request APIs**

Update split `TerminalView`:
- `handlePaneExit(paneId:)` should synchronously call `tabManager.requestPaneProcessExit(forPane: paneId)` through the injected manager or be replaced by direct request closures;
- remove the SwiftUI-owned `Task { await tabManager.handlePaneExit(for:) }` wrapper.

Do not widen this task into root session process-exit, rich paste upload ownership, title/PWD/background callbacks, credential reload, RemoteFiles navigation/preview/drop/file-representation, or Stats retry. Root process exit still uses a direct `ConnectionSessionManager.handleShellExit(for:)` bridge and should be handled separately if a later task introduces a safe main-actor event bridge for terminal callbacks.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalProcessExitIntentTests -only-testing:VVTermTests/TerminalProcessExitBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "handlePaneExit\\(|requestPaneProcessExit|Task \\{[^\\n]*handlePaneExit" VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows split pane process-exit callbacks use request APIs and split UI no longer owns a process-exit `Task` wrapper. Remaining `Task` hits for root process exit, rich paste, credential reload, title/PWD/background parsing, RemoteFiles navigation, Stats retry, and theme/background color parsing must be named in the Progress Ledger as deferred slices.

- [x] **Step 5: API and boundary cleanup**

Before review, verify request API names match the previous `requestPaneInput` and `requestPaneResize` style; UI supplies only pane process-exit intent; the manager owns request tracking, coalescing, cancellation, and low-level exit invocation; DEBUG seams are reset in test cleanup; tests include the required Test Context and Given / When / Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 62. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 63: Root Terminal Process Exit Intent Boundary

**Files:**
- Modify: `VVTermTests/TerminalProcessExitIntentTests.swift`
- Modify: `VVTermTests/TerminalProcessExitBoundaryTests.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing low-level root process-exit behavior: `ConnectionSessionManager.handleShellExit(for:)`.
  - Existing root terminal surface callback `GhosttyTerminalView.onProcessExit` passed through `SSHTerminalWrapper`.
  - Existing session close/reset cleanup paths.
- Produces:
  - `ConnectionSessionManager.requestSessionProcessExit(forSession sessionId: UUID) -> UUID?`: rejects missing sessions, stores/tracks accepted root process-exit request work, coalesces duplicate same-session exits, and runs `handleShellExit(for:)` from manager-owned request work.
  - `pendingProcessExitRequestIDs` and `waitForProcessExitRequest(_:)` on `ConnectionSessionManager` for lifecycle tests.
  - DEBUG-only process-exit operation seam that lets tests prove request ordering and close cancellation without constructing `GhosttyTerminalView` or opening SSH.

- [x] **Step 1: Add RED root process-exit request and boundary tests**

Extend `TerminalProcessExitIntentTests` with root-session coverage:
- a root process-exit request rejects missing sessions without creating a task;
- a root process-exit request stays tracked until the process-exit operation finishes;
- duplicate root process-exit requests for the same session coalesce to one request ID and call the operation once;
- session close clears/cancels pending root process-exit requests through the real `closeSessionAndWait(...)` path.

Extend `TerminalProcessExitBoundaryTests` with a source scan:
- `TerminalContainerView.swift` root process-exit handling must call `ConnectionSessionManager.shared.requestSessionProcessExit(forSession:)`;
- `TerminalContainerView.swift` must not wrap process exit in `DispatchQueue.main.async { ConnectionSessionManager.shared.handleShellExit(...) }`;
- `SSHTerminalWrapper` may continue to assign `terminalView.onProcessExit = onProcessExit`, but must not own process-exit request tasks or call low-level session exit handlers directly.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalProcessExitIntentTests -only-testing:VVTermTests/TerminalProcessExitBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestSessionProcessExit(...)`, root pending process-exit request IDs, wait hooks, and DEBUG process-exit seams do not exist on `ConnectionSessionManager`. If it compiles unexpectedly, boundary tests fail because root process exit still uses a SwiftUI-owned `DispatchQueue.main.async` bridge to `handleShellExit(for:)`.

- [x] **Step 2: Add root process-exit requests**

Add request tracking to `ConnectionSessionManager` for root process exit. It should reject missing session state, coalesce duplicate session exits, expose pending IDs and a wait hook, cancel/clear pending process-exit when a session closes or the manager resets for tests, and keep existing `handleShellExit(for:)` as the low-level synchronous boundary.

- [x] **Step 3: Route root UI process-exit callbacks through request APIs**

Update `TerminalContainerView`:
- the root `SSHTerminalWrapper(onProcessExit:)` closure should synchronously call `ConnectionSessionManager.shared.requestSessionProcessExit(forSession: session.id)`;
- remove the SwiftUI-owned `DispatchQueue.main.async { ConnectionSessionManager.shared.handleShellExit(for:) }` bridge.

Do not widen this task into split-pane exit, rich paste upload ownership, title/PWD/background callbacks, credential reload, RemoteFiles navigation/preview/drop/file-representation, Stats retry, or raw SSH ownership. `SSHTerminalWrapper` remains a pass-through surface adapter for `onProcessExit`.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalProcessExitIntentTests -only-testing:VVTermTests/TerminalProcessExitBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "handleShellExit\\(|requestSessionProcessExit|DispatchQueue\\.main\\.async" VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows root process-exit callbacks use request APIs and `TerminalContainerView` no longer owns a process-exit dispatch bridge. Remaining hits for rich paste, credential reload, title/PWD/background parsing, RemoteFiles navigation/preview, Stats retry, and theme/background color parsing must be named in the Progress Ledger as deferred slices.

- [x] **Step 5: API and boundary cleanup**

Before review, verify request API names match the previous `requestSessionInput`, `requestSessionResize`, and `requestPaneProcessExit` style; UI supplies only root process-exit intent; the manager owns request tracking, coalescing, cancellation, and low-level exit invocation; DEBUG seams are reset in test cleanup; tests include the required Test Context and Given / When / Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 63. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 64: RemoteFiles Preview Load Intent Boundary

**Files:**
- Modify: `VVTermTests/Features/RemoteFiles/RemoteFilePreviewCoordinatorTests.swift`
- Modify: `VVTermTests/RemoteFileMutationIntentBoundaryTests.swift`
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift`
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFilePreviewCoordinator.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserIOSScreen.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing low-level async preview implementation: `RemoteFileBrowserStore.loadPreview(for:in:server:allowLargeDownloads:)`.
  - Existing platform preview callbacks in `RemoteFileBrowserIOSScreen` and `RemoteFileBrowserMacScreen`.
  - Existing viewer cleanup paths: `clearViewer(for:)`, `focus(_:in:)`, `loadDirectory(path:in:server:)`, `removeRuntimeState(for:)`, and `disconnect(serverId:)`.
- Produces:
  - `RemoteFileBrowserStore.requestPreviewLoad(for entry: RemoteFileEntry, in tab: RemoteFileTab, server: Server, allowLargeDownloads: Bool = false) -> UUID?`: rejects mismatched tab/server and unsupported preview entries, coalesces duplicate same-tab/same-entry/same-large-download requests, cancels stale same-tab preview-load work before starting a different preview, and runs the existing async preview implementation from store-owned request work.
  - `pendingPreviewLoadRequestIDs` and `waitForPreviewLoadRequest(_:)` on `RemoteFileBrowserStore` for lifecycle tests.
  - Close/cleanup integration so `clearViewer(for:)`, `focus(_:in:)`, `loadDirectory(path:in:server:)`, `removeRuntimeState(for:)`, and `disconnect(serverId:)` cancel visible pending preview-load request bookkeeping while keeping the underlying task awaitable until it exits.

- [x] **Step 1: Add RED preview-load request and boundary tests**

Extend `RemoteFilePreviewCoordinatorTests`:
- a preview-load request rejects a tab/server mismatch without creating work;
- a preview-load request stays tracked while `readFile` is blocked, then clears after the preview payload is applied;
- duplicate preview-load requests for the same tab, entry, and `allowLargeDownloads` flag coalesce to one request ID and one remote read;
- `clearViewer(for:)`, `focus(_:in:)`, `loadDirectory(path:in:server:)`, `removeRuntimeState(for:)`, and `disconnect(serverId:)` clear/cancel pending visible preview-load request state through real cleanup paths while the underlying task remains awaitable until blocked work exits, and stale payload/error updates are prevented after release.

Extend `RemoteFileMutationIntentBoundaryTests`:
- `RemoteFileBrowserIOSScreen.swift` and `RemoteFileBrowserMacScreen.swift` must call `browser.requestPreviewLoad(...)` from `onLoadPreview` and `onDownloadPreview`;
- platform preview UI must not contain `Task { await browser.loadPreview(...) }` or direct `await browser.loadPreview(...)`;
- `RemoteFilePreviewViews.swift` may keep `.task(id: previewRequestID)` because it only sends synchronous `onLoadPreview` intent and does not own remote preview-load work.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFilePreviewCoordinatorTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestPreviewLoad(...)`, `pendingPreviewLoadRequestIDs`, and `waitForPreviewLoadRequest(_:)` do not exist on `RemoteFileBrowserStore`. If it compiles unexpectedly, boundary tests fail because macOS/iOS preview callbacks still create UI-owned `Task { await browser.loadPreview(...) }` wrappers.

- [x] **Step 2: Add tracked preview-load requests**

Add preview-load request bookkeeping to `RemoteFileBrowserStore`, mirroring the existing `requestMutation` / `requestTransfer` request style but scoped per tab:
- store accepted request tasks by request ID;
- keep a tab-to-request index carrying tab ID, entry path, and `allowLargeDownloads`;
- return the existing request ID for duplicate same-tab/same-entry/same-flag intent;
- cancel and unpublish an existing same-tab preview-load request before starting a different preview-load request, but keep the canceled task handle until the task exits;
- keep `loadPreview(...)` as the low-level async implementation and do not move SFTP/file preview details into UI.

- [x] **Step 3: Wire cleanup paths**

Update preview cleanup paths:
- `clearViewer(for:)` cancels/unpublishes pending preview-load requests for the tab before clearing viewer state and `viewerRequestIDs`;
- `focus(_:in:)` cancels/unpublishes pending preview-load requests for the previous selection before selecting a new entry;
- `loadDirectory(path:in:server:)` cancels/unpublishes pending preview-load requests and resets viewer loading state before loading directory contents;
- `removeRuntimeState(for:)` cancels/unpublishes pending preview-load requests for the tab before dropping runtime state;
- `disconnect(serverId:)` cancels/unpublishes pending preview-load requests for every affected tab before scheduling remote-service disconnect.

Do not widen this task into directory navigation (`goUp`, breadcrumbs, directory open), file activation, downloads/share, drag/drop, file promises, preview text save, rich paste, terminal credential reload, Stats retry, or terminal title/PWD/background parsing.

- [x] **Step 4: Route platform preview callbacks through request APIs**

Update `RemoteFileBrowserIOSScreen` and `RemoteFileBrowserMacScreen`:
- `onLoadPreview` should synchronously call `browser.requestPreviewLoad(for:entry,in:fileTab,server:server)`;
- `onDownloadPreview` should synchronously call `browser.requestPreviewLoad(for:entry,in:fileTab,server:server,allowLargeDownloads:true)`;
- remove platform-owned `Task { await browser.loadPreview(...) }` wrappers from these preview callbacks.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFilePreviewCoordinatorTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "requestPreviewLoad|loadPreview\\(|Task \\{ await browser\\.loadPreview|await browser\\.loadPreview" VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserIOSScreen.swift VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift VVTerm/Features/RemoteFiles/UI/Preview/RemoteFilePreviewViews.swift VVTerm/Features/RemoteFiles/Application/RemoteFilePreviewCoordinator.swift VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows platform preview UI calls `requestPreviewLoad`, no platform preview callback owns `Task { await browser.loadPreview(...) }`, and any remaining `loadPreview(...)` hits are the application-layer low-level implementation plus tests.

- [x] **Step 6: API and boundary cleanup**

Before review, verify request API names match the existing `requestMutation`, `requestTransfer`, and `requestTextPreviewSave` style; UI supplies only preview-load intent; RemoteFiles Application owns request tracking, duplicate coalescing, cancellation, and low-level preview invocation; cleanup paths remove stale request state; touched tests include the required Test Context plus Given / When / Then comments and assertion messages.

- [x] **Step 7: Request review and commit**

Request code review for Task 64. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, and cleanup notes, then commit atomically.

## Task 65: Terminal Credential Load Intent Boundary

**Files:**
- Modify: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Create: `VVTermTests/TerminalCredentialLoadIntentBoundaryTests.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing low-level credential helper: `ConnectionSessionManager.loadCredentials(for:) -> TerminalCredentialLoadResult`.
  - Existing low-level credential helper: `TerminalTabManager.loadCredentials(for:) -> TerminalCredentialLoadResult`.
  - Existing test seam: `setCredentialsProviderForTesting(_:)`.
  - Existing close paths: `ConnectionSessionManager.closeSessionAndWait(_:)` and `TerminalTabManager.closePaneAndWait(...)`.
- Produces:
  - `ConnectionSessionManager.requestSessionCredentialLoad(session: ConnectionSession, server: Server, onCompleted: @escaping @MainActor (TerminalCredentialLoadResult) -> Void = { _ in }) -> UUID`: validates the session/server pair, coalesces duplicate same-session credential-load intent, tracks the load task by request ID, skips stale/canceled completions, and keeps `loadCredentials(for:)` as the low-level implementation.
  - `ConnectionSessionManager.pendingSessionCredentialLoadRequestIDs` and `waitForSessionCredentialLoadRequest(_:)` for lifecycle tests.
  - `TerminalTabManager.requestPaneCredentialLoad(paneId: UUID, server: Server, onCompleted: @escaping @MainActor (TerminalCredentialLoadResult) -> Void = { _ in }) -> UUID`: validates the pane/server pair, coalesces duplicate same-pane credential-load intent, tracks the load task by request ID, skips stale/canceled completions, and keeps `loadCredentials(for:)` as the low-level implementation.
  - `TerminalTabManager.pendingPaneCredentialLoadRequestIDs` and `waitForPaneCredentialLoadRequest(_:)` for lifecycle tests.

- [x] **Step 1: Add RED credential-load request and boundary tests**

Extend `ConnectionLifecycleIntegrationTests`:
- a session credential-load request stays pending while the injected credentials provider is blocked, then calls completion and clears after release;
- duplicate same-session credential-load requests coalesce to one request ID and one provider call, while preserving both completion callbacks;
- `closeSessionAndWait(_:)` cancels and clears a pending session credential-load request before session teardown completes;
- a pane credential-load request has the same pending, duplicate coalescing, and close-cancellation behavior through `TerminalTabManager.closePaneAndWait(...)`.

Create `TerminalCredentialLoadIntentBoundaryTests`:
- `TerminalContainerView.swift` must call `ConnectionSessionManager.shared.requestSessionCredentialLoad(...)` from credential-load intent helpers and must not contain `Task { await loadCredentialsIfNeeded(...) }` or direct `await ConnectionSessionManager.shared.loadCredentials(...)` in UI code;
- `TerminalView.swift` must call `TerminalTabManager.shared.requestPaneCredentialLoad(...)` from credential-load intent helpers and must not directly await `TerminalTabManager.shared.loadCredentials(...)` in SwiftUI `.task` work;
- source-boundary assertions must include a `Test Context` header and Given / When / Then comments.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalCredentialLoadIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestSessionCredentialLoad(...)`, `requestPaneCredentialLoad(...)`, pending request ID properties, and wait hooks do not exist. If it compiles unexpectedly, the source-boundary tests fail because SwiftUI still awaits credential loading directly.

- [x] **Step 2: Add tracked manager-owned credential-load requests**

Add request bookkeeping to `ConnectionSessionManager` and `TerminalTabManager`, matching existing retry/host-retrust request style:
- store task records by request ID and keep a session-to-request or pane-to-request index;
- append duplicate caller callbacks and return the existing request ID for the same session/pane while a credential load is pending;
- validate session/pane ownership before loading and before invoking callbacks;
- treat cancellation as lifecycle completion, not a user-facing credential failure;
- leave `loadCredentials(for:)` as the low-level helper used by request tasks and existing non-UI internals.

- [x] **Step 3: Wire close/reset cleanup**

Update cleanup paths:
- `closeSessionAndWait(_:)` cancels and clears pending session credential-load requests for the closing session;
- `closePaneAndWait(...)` cancels and clears pending pane credential-load requests for the closing pane;
- `resetForTesting()` cancels and clears both new request registries and test-only state.

Do not widen this task into terminal retry, host retrust, rich paste upload/lease lifecycle, title/PWD/background callbacks, iOS active-connection open orchestration, RemoteFiles navigation, Stats retry, Ghostty config reload, Store product reload, or AppLock server unlock.

- [x] **Step 4: Route root and split UI through request APIs**

Update `TerminalContainerView`:
- replace async `loadCredentialsIfNeeded(force:)` with a synchronous credential-load intent helper;
- `.task` and `server?.id` change should send credential-load intent only, not create a UI-owned credential-load task;
- preserve the existing UI behavior where successful loads update `credentials` and failures update `credentialLoadErrorMessage`, guarded against stale server IDs.

Update split `TerminalView`:
- the initial `.task` may keep presentation-only setup, prompt checks, watchdog start, and reconnect intent, but credential loading must be sent through `TerminalTabManager.shared.requestPaneCredentialLoad(...)`;
- successful loads update `credentials`, and failures update `credentialLoadErrorMessage`, guarded against stale pane/server identity.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/TerminalCredentialLoadIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "requestSessionCredentialLoad|requestPaneCredentialLoad|loadCredentialsIfNeeded|Task \\{ await loadCredentialsIfNeeded|await ConnectionSessionManager\\.shared\\.loadCredentials|await TerminalTabManager\\.shared\\.loadCredentials" VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows root/split UI uses request APIs and no UI-owned credential-load task or direct manager `loadCredentials` await remains; any remaining `loadCredentials(for:)` hits are application-layer low-level helpers or tests.

- [x] **Step 6: API and boundary cleanup**

Before review, verify request API names match existing `requestSessionRetry`, `requestPaneRetry`, `requestSessionHostRetrust`, and `requestPaneHostRetrust` style; UI supplies only credential-load intent and presentation callbacks; managers own task tracking, duplicate coalescing, cancellation, and stale completion guards; close/reset cleanup drains new request state; touched tests include the required Test Context and Given / When / Then comments.

- [x] **Step 7: Request review and commit**

Request code review for Task 65. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Task 66: RemoteFiles Navigation Intent Boundary

**Files:**
- Modify: `VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift`
- Create: `VVTermTests/RemoteFileNavigationIntentBoundaryTests.swift`
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserIOSScreen.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing low-level RemoteFiles helpers: `loadInitialPath(for:server:tab:initialPath:)`, `refresh(server:tab:)`, `goUp(in:server:)`, `openBreadcrumb(_:in:server:)`, `openDirectory(_:in:server:)`, and `activate(_:in:server:)`.
  - Existing directory stale-result guard: `directoryRequestIDs`.
  - Existing runtime cleanup paths: `clearViewer(for:)`, `loadDirectory(path:in:server:)`, `removeRuntimeState(for:)`, and `disconnect(serverId:)`.
- Produces:
  - A RemoteFiles Application request boundary for directory navigation and entry activation, using names that match the existing `requestMutation`, `requestTransfer`, `requestPreviewLoad`, and `requestTextPreviewSave` style.
  - A request action/result model that keeps UI callbacks presentation-only. The action model should cover initial directory load, refresh, go up, breadcrumb open, directory open, and entry activation. The result model should let iOS preview presentation distinguish file selection from directory navigation without reaching back into async work.
  - Pending navigation request IDs and `waitFor...` hooks for lifecycle ordering tests.

- [x] **Step 1: Add RED navigation request and boundary tests**

Extend `RemoteFileBrowserStoreTests`:
- an initial directory load request stays pending while the fake directory snapshot is blocked, then applies the loaded directory and clears after release;
- a new navigation request for the same tab cancels/unpublishes the previous visible request, remains awaitable until the blocked fake exits, and prevents the stale result from overwriting the latest directory state;
- `removeRuntimeState(for:)` cancels/unpublishes pending navigation for the tab while keeping the request wait hook awaitable until the fake exits;
- `disconnect(serverId:)` cancels/unpublishes pending navigation for affected tabs before scheduling remote-service disconnect;
- entry activation through the request API preserves existing symlink/file behavior and reports a presentation result that the UI can use without owning the async task.

Create `RemoteFileNavigationIntentBoundaryTests`:
- `RemoteFileBrowserScreen.swift`, `RemoteFileBrowserIOSScreen.swift`, and `RemoteFileBrowserMacScreen.swift` must call RemoteFileBrowserStore request APIs for initial load, refresh, go up, breadcrumb open, directory open, and entry activation;
- `ConnectionTabsView.swift` must call the same request APIs for RemoteFiles toolbar and Zen controls;
- source-boundary assertions must reject `Task { await browser.goUp(...) }`, `Task { await browser.refresh(...) }`, `Task { await browser.openDirectory(...) }`, `Task { await browser.openBreadcrumb(...) }`, `Task { await browser.activate(...) }`, direct `await browser.loadInitialPath(...)` from SwiftUI, and equivalent `fileBrowser` toolbar forms;
- source-boundary assertions must include a `Test Context` header and Given / When / Then comments.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileNavigationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because the navigation request API, pending request IDs, request result model, and wait hook do not exist. If it compiles unexpectedly, the source-boundary tests fail because RemoteFiles UI still owns async navigation tasks.

- [x] **Step 2: Add tracked store-owned navigation requests**

Add request bookkeeping to `RemoteFileBrowserStore`, matching the Task 64 preview-load pattern:
- store navigation task records by request ID and index the active visible request by tab ID;
- when a new navigation request targets the same tab, cancel/unpublish the previous visible request but keep its task record until the task exits so wait hooks remain awaitable;
- run low-level directory navigation, initial load, and activation helpers inside the store-owned request task;
- treat cancellation as lifecycle completion, not a user-facing directory-load failure;
- guard all completion callbacks and state writes against canceled/stale requests and removed runtime state.

- [x] **Step 3: Wire cleanup and stale-result ordering**

Update cleanup paths:
- `removeRuntimeState(for:)` cancels and clears visible pending navigation for the tab before dropping runtime state;
- `disconnect(serverId:)` cancels and clears visible pending navigation for every affected tab before scheduling remote-service disconnect;
- `loadDirectory(path:in:server:)` keeps its stale-result guard aligned with request IDs so canceled or superseded tasks cannot apply payload or error state after a newer request wins;
- `resetForTesting()` cancels and clears navigation request registries and test hooks.

Do not widen this task into preview loading, transfers, downloads/share, drag/drop, file promises, preview text save, inline folder creation, rich paste upload/lease lifecycle, terminal retry, host retrust, title/PWD/background callbacks, Stats retry, Ghostty config reload, Store product reload, or AppLock server unlock.

- [x] **Step 4: Route RemoteFiles and tab chrome UI through request APIs**

Update RemoteFiles UI:
- `RemoteFileBrowserScreen` sends initial directory load, directory open, and entry activation intent through request APIs and uses only completion results for presentation state such as iOS preview presentation;
- `RemoteFileBrowserIOSScreen` sends refresh, go up, and entry activation intent through request APIs;
- `RemoteFileBrowserMacScreen` sends breadcrumb and directory-open intent through request APIs;
- `ConnectionTabsView` toolbar and Zen RemoteFiles controls send go-up and refresh intent through request APIs.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileNavigationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "request.*Navigation|request.*Activation|request.*Directory|Task \\{ await (browser|fileBrowser)\\.(goUp|refresh|openDirectory|openBreadcrumb|activate)|await (browser|fileBrowser)\\.(loadInitialPath|goUp|refresh|openDirectory|openBreadcrumb|activate)" VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserIOSScreen.swift VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows UI calls RemoteFileBrowserStore request APIs and no UI-owned RemoteFiles navigation task or direct SwiftUI await remains; any remaining low-level navigation helper calls are inside `RemoteFileBrowserStore` or tests.

- [x] **Step 6: API and boundary cleanup**

Before review, verify request API names match existing RemoteFiles request style; UI supplies only navigation intent plus presentation callbacks; the store owns request tracking, cancellation, duplicate/stale ordering, low-level directory loading, and activation ordering; cleanup paths drain new request state; touched tests include the required Test Context and Given / When / Then comments.

- [x] **Step 7: Request review and commit**

Request code review for Task 66. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Task 67: Terminal Rich Paste Upload Intent Boundary

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Application/TerminalRichPasteUploadRequest.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Modify: `VVTerm/Core/SSH/RemoteClipboardTransferService.swift`
- Test: `VVTermTests/TerminalRichPasteUploadRequestTests.swift`
- Test: `VVTermTests/TerminalRichPasteIntentBoundaryTests.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing rich paste UI model and prompt presentation in `TerminalRichPasteSupport.swift`.
  - Existing `TerminalRichPasteCoordinator.performRichPaste(image:settings:client:)`.
  - Existing terminal input request APIs: `ConnectionSessionManager.requestSessionInput(...)` and `TerminalTabManager.requestPaneInput(...)`.
  - Existing borrowed lease providers: `ConnectionSessionManager.remoteConnectionLease(forSessionId:)` and `TerminalTabManager.remoteConnectionLease(for:)`.
- Produces:
  - `TerminalRichPasteUploadRequest` / `TerminalRichPasteUploadResult` application-layer types that distinguish success, skipped no-connection, cancellation, and failure without exposing raw UI state to the upload owner.
  - `ConnectionSessionManager.requestSessionRichPasteUpload(image:settings:onProgress:onCompleted:) -> UUID?`, `pendingSessionRichPasteUploadRequestIDs`, and `waitForSessionRichPasteUploadRequest(_:)`.
  - `TerminalTabManager.requestPaneRichPasteUpload(image:settings:onProgress:onCompleted:) -> UUID?`, `pendingPaneRichPasteUploadRequestIDs`, and `waitForPaneRichPasteUploadRequest(_:)`.
  - Manager-owned rich paste upload tasks that resolve leases, run uploads through `RemoteConnectionLease.withExclusiveClient`, await `lease.close()` before clearing request state, and paste the uploaded path through the manager input request boundary.
  - UI support that only captures clipboard data, presents prompt/notice state, and sends upload/paste-text intent; it must not own the upload task, lease lifetime, coordinator, or close ordering.

- [x] **Step 1: Add RED rich paste request and boundary tests**

Add `TerminalRichPasteUploadRequestTests` with Test Context and fake lease/upload dependencies:
- a session rich paste request stays pending while the fake upload is blocked, reports progress, and clears only after the upload finishes and `lease.close()` has completed;
- a pane rich paste request uses the same request owner and paste-path input boundary;
- duplicate same-session/same-pane rich paste upload intent cancels or supersedes the older visible request while keeping the older request awaitable until its fake upload exits;
- `closeSessionAndWait(_:)` and `closePaneAndWait(...)` cancel pending rich paste upload requests and do not surface cancellation as a user-facing failure;
- upload success pastes `RemoteTerminalBootstrap.posixPastedPath(remotePath)` through the existing manager input request API, not by reaching into `GhosttyTerminalView`;
- rich paste upload uses `lease.withExclusiveClient` and awaits `lease.close()` before the request disappears.

Add `TerminalRichPasteIntentBoundaryTests`:
- `TerminalRichPasteSupport.swift` must not store `activePasteTask`, instantiate `TerminalRichPasteCoordinator`, call `performRichPaste`, call `resolveRemoteConnectionLease`, call `lease.close()`, or call `RemoteConnectionLease.withExclusiveClient` from UI code;
- root `SSHTerminalWrapper.swift` and split `TerminalView.swift` may install rich-paste interception, but upload start must route through `ConnectionSessionManager.requestSessionRichPasteUpload(...)` or `TerminalTabManager.requestPaneRichPasteUpload(...)`;
- `RemoteClipboardTransferService.swift` must not start an untracked stale-file sweep `Task` that can use the client after the upload lease closes.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalRichPasteUploadRequestTests -only-testing:VVTermTests/TerminalRichPasteIntentBoundaryTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because the session/pane rich paste request APIs, pending request IDs, wait hooks, and injectable upload/lease seams do not exist. If it compiles unexpectedly, source-boundary tests fail because `TerminalRichPasteController` still owns `activePasteTask`, direct coordinator upload, and lease close.

- [x] **Step 2: Add application-layer rich paste upload request owner**

Create `TerminalRichPasteUploadRequest.swift` under `Features/TerminalSessions/Application`:
- define request/result types and a small `TerminalRichPasteUploading` protocol that adapts `TerminalRichPasteCoordinator`;
- keep `TerminalRichPasteCoordinator` in Core/SSH as the low-level remote clipboard upload/seeding implementation;
- make request execution accept a `RemoteConnectionLease` provider, progress callback, completion callback, and paste-path sink;
- run `performRichPaste` inside `try await lease.withExclusiveClient { client in ... }`;
- close the lease in a `defer` or equivalent path that is awaited before request cleanup, including failure and cancellation;
- map missing lease to a skipped/no-connection result and cancellation to lifecycle completion, not a user-facing failure.

- [x] **Step 3: Add manager request APIs and close cleanup**

Update `ConnectionSessionManager` and `TerminalTabManager`:
- add request dictionaries indexed by request ID and active entity ID;
- expose `pendingSessionRichPasteUploadRequestIDs`, `pendingPaneRichPasteUploadRequestIDs`, and wait hooks for tests;
- coalesce or supersede duplicate same-entity upload intent explicitly, matching existing request API behavior in the manager;
- resolve borrowed leases from the shell registry at request execution time and recheck entity liveness after awaits;
- paste the uploaded path using `requestSessionInput` / `requestPaneInput` with UTF-8 data generated from `RemoteTerminalBootstrap.posixPastedPath(...)`;
- cancel pending rich paste upload requests from session/pane close paths and DEBUG reset cleanup.

- [x] **Step 4: Route UI prompt and interception through request APIs**

Update `TerminalRichPasteSupport.swift`, `SSHTerminalWrapper.swift`, and split `TerminalView.swift`:
- keep `TerminalRichPasteUIModel`, prompt sheet, and notice presentation in UI;
- replace `TerminalRichPasteController.activePasteTask` and `performRichPaste(...)` with a synchronous intent call on the context;
- root context sends upload intent to `ConnectionSessionManager.requestSessionRichPasteUpload(...)`;
- pane context sends upload intent to `TerminalTabManager.requestPaneRichPasteUpload(...)`;
- completion callbacks only update `TerminalRichPasteUIModel` presentation state such as progress and banners;
- paste-text fallback may remain a synchronous terminal UI operation for this task, but image upload and remote path paste must be manager-owned.

- [x] **Step 5: Remove or track rich paste stale-file sweep**

Update `RemoteClipboardTransferService` so stale remote clipboard file cleanup is not an untracked task that can outlive the lease:
- either perform the best-effort stale sweep inside the same upload request before `lease.close()`, or return a cleanup action to the application-layer request owner and await it there;
- keep cleanup best-effort and non-user-facing, but preserve enough logging to diagnose remote cleanup failure;
- do not let a delayed task capture and use `RemoteConnectionLeaseClient` after the request has closed its lease.

- [x] **Step 6: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalRichPasteUploadRequestTests -only-testing:VVTermTests/TerminalRichPasteIntentBoundaryTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
rg -n "activePasteTask|performRichPaste|resolveRemoteConnectionLease|lease\\.close|withExclusiveClient|TerminalRichPasteCoordinator\\(|requestSessionRichPasteUpload|requestPaneRichPasteUpload|Task\\(priority: \\.utility\\)" VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTerm/Features/TerminalSessions/Application/TerminalRichPasteUploadRequest.swift VVTerm/Core/SSH/RemoteClipboardTransferService.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows UI files contain no upload task/lease/coordinator ownership, managers expose request APIs, application request code owns `withExclusiveClient`, and `RemoteClipboardTransferService` has no delayed untracked stale-sweep task.

- [x] **Step 7: API and boundary cleanup**

Before review, verify request API names match the established TerminalSessions request style; UI only owns prompt/notice state; managers own upload lifecycle and close cleanup; lease use is serialized and closed before request cleanup; cancellation is not user-facing failure; tests include required Test Context and Given / When / Then comments; no temporary test seams are public beyond DEBUG/internal needs.

- [x] **Step 8: Request review and commit**

Request code review for Task 67. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Task 68: Stats Collection Request Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Stats/Application/ServerStatsCollector.swift`
- Modify: `VVTerm/Features/Stats/UI/ServerStatsView.swift`
- Test: `VVTermTests/Features/Stats/ServerStatsCollectorLifecycleTests.swift`
- Create: `VVTermTests/Features/Stats/ServerStatsIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `ServerStatsCollector.startCollecting(for:using:) async`
  - Existing `ServerStatsCollector.stopCollectingAndWait() async`
  - Existing `ServerStatsView` visibility, retry, and borrowed-lease provider inputs.
- Produces:
  - `ServerStatsCollector.requestStartCollecting(for:using:) -> UUID?`
  - `ServerStatsCollector.requestStopCollecting() -> UUID?`
  - `ServerStatsCollector.pendingStatsCollectionRequestIDs`
  - `ServerStatsCollector.waitForStatsCollectionRequest(_:) async`
  - Collector-owned start/stop request tasks that supersede stale visibility/retry intent, keep canceled work awaitable until task exit, and prevent a canceled queued start from creating a replacement lease after a newer stop intent wins.
  - `ServerStatsView` actions and lifecycle callbacks that synchronously send request intent instead of owning async collection tasks.

- [x] **Step 1: Add RED Stats request and boundary tests**

Extend `ServerStatsCollectorLifecycleTests` with Test Context-preserving async ordering tests:
- a start request remains pending while it waits behind an already-running stop task, and clears only after the underlying start request exits;
- a stop request cancels a queued start request before the queued start creates a replacement owned Stats lease;
- request cancellation is lifecycle intent and must not publish a user-facing connection error.

Create `ServerStatsIntentBoundaryTests`:
- `ServerStatsView.swift` must not create a `Task { await statsCollector.startCollecting(...) }` from Retry;
- `ServerStatsView.swift` must not use `.task(id: makeTaskKey())` to directly await `startCollecting` or `stopCollectingAndWait`;
- visible, hidden, disappearing, and retry intent must route through `requestStartCollecting(...)` / `requestStopCollecting()`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests -only-testing:VVTermTests/ServerStatsIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestStartCollecting`, `requestStopCollecting`, `pendingStatsCollectionRequestIDs`, and `waitForStatsCollectionRequest(_:)` do not exist. If it compiles unexpectedly, the boundary test must fail because `ServerStatsView` still starts async collection work directly from SwiftUI.

Actual RED result: focused `ServerStatsCollectorLifecycleTests` / `ServerStatsIntentBoundaryTests` failed to build because `ServerStatsCollector` had no `requestStartCollecting`, `requestStopCollecting`, `pendingStatsCollectionRequestIDs`, or `waitForStatsCollectionRequest`.

- [x] **Step 2: Add collector-owned request tracking**

Update `ServerStatsCollector`:
- store tracked collection request records by request ID, including the `Task<Void, Never>`;
- expose visible pending IDs and an await hook that waits for the retained task even after cancellation;
- make `requestStartCollecting(for:using:)` cancel any prior request, create a tracked task, check cancellation before and after waiting for pending stop work, then call `startCollecting`;
- make `requestStopCollecting()` cancel any queued start request, create a tracked task, then await `stopCollectingAndWait()`;
- clear request records only from the request task's `defer` when the request ID is still present;
- keep `CancellationError` and task cancellation from publishing a connection error.

- [x] **Step 3: Harden start cancellation around pending stop**

Update `startCollecting(for:using:)` so cancellation cannot leak through the existing pending-stop wait:
- after awaiting `pendingStopTask.value`, check `Task.isCancelled` before credentials lookup or lease creation;
- after awaiting any previous `collectTask.value`, check cancellation again before replacing connection state;
- leave existing direct async API behavior intact for tests and internal callers, but make it cancellation-aware for request-owned tasks.

- [x] **Step 4: Route Stats UI through request APIs**

Update `ServerStatsView`:
- replace Retry's `Task { await statsCollector.startCollecting(...) }` with `statsCollector.requestStartCollecting(for:using:)`;
- replace `.task(id: makeTaskKey())` direct awaits with synchronous visibility intent. Use `.onAppear` plus `.onChange(of: makeTaskKey())` or an equivalent SwiftUI lifecycle hook that only sends collector request intent;
- keep `onDisappear` as `statsCollector.requestStopCollecting()`;
- preserve existing copy, cards, error presentation, retry button, and borrowed lease behavior.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests -only-testing:VVTermTests/ServerStatsIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "Task \\{[[:space:]]*await statsCollector\\.startCollecting|\\.task\\(id: makeTaskKey\\(\\)\\)|await statsCollector\\.(startCollecting|stopCollectingAndWait)|requestStartCollecting|requestStopCollecting" VVTerm/Features/Stats/UI/ServerStatsView.swift VVTerm/Features/Stats/Application/ServerStatsCollector.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows Stats UI contains request API calls and no UI-owned async start/stop await; collector source contains the low-level async start/stop helpers and the tracked request APIs.

Actual GREEN result: focused Stats request suite passed 10 Swift Testing tests across `ServerStatsCollectorLifecycleTests` and `ServerStatsIntentBoundaryTests`. Expanded Stats verification passed 10 XCTest tests across `StatsParsingUtilsTests` and `ServerStatsDomainTests` plus the same 10 Swift Testing lifecycle/boundary tests. Source scan showed `ServerStatsView` only calls `requestStartCollecting` / `requestStopCollecting` and has no direct `await statsCollector.startCollecting`, `await statsCollector.stopCollectingAndWait`, or `.task(id: makeTaskKey())`; `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`.

- [x] **Step 6: API and boundary cleanup**

Before review, verify `ServerStatsCollector` is the single owner of collection request tasks, request names match existing application-layer intent style, canceled requests remain awaitable until exit, start-after-stop ordering is deterministic, UI only sends visibility/retry/disappear intent, and touched Stats tests include complete Test Context plus Given / When / Then comments.

- [x] **Step 7: Request review and commit**

Request code review for Task 68. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

Review result: subagent review was not spawned because the available multi-agent tool requires explicit user authorization for subagents. Local read-only review against the Swift lifecycle checklist found no Critical or Important issues: `ServerStatsCollector` is the single owner of collection request tasks, SwiftUI only sends intent, canceled queued starts remain awaitable until exit, `startCollecting` rechecks cancellation after pending-stop waits, and tests include the required context/comments.

## Task 69: Store Product Load Request Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Store/Application/StoreManager.swift`
- Modify: `VVTerm/Features/Store/UI/ProUpgradeSheet.swift`
- Test: `VVTermTests/Features/Store/StoreManagerLifecycleTests.swift`
- Create: `VVTermTests/StoreProductLoadIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `StoreManager.loadProducts() async`
  - Existing `StoreManager.notePaywallPresented(source:)`
  - Existing `ProUpgradeSheet.defaultPlan` and `selectedPlan` presentation state.
- Produces:
  - `StoreManager.requestProductLoad(onCompleted:) -> UUID`
  - `StoreManager.pendingProductLoadRequestIDs`
  - `StoreManager.waitForProductLoadRequest(_:) async`
  - StoreManager-owned product-load request task coalescing so repeated paywall appearances do not create duplicate App Store product fetches.
  - `ProUpgradeSheet` lifecycle hooks that synchronously send product-load intent and update `selectedPlan` from the request completion callback instead of awaiting `loadProducts()` in SwiftUI.

- [x] **Step 1: Add RED product-load lifecycle and boundary tests**

Extend `StoreManagerLifecycleTests`:
- `productLoadRequestTracksOperationUntilCompletion`: use `StoreRequestGate` and fake `loadProductsAction` to prove the request ID remains visible while product loading is blocked, then clears only after completion.
- `duplicateProductLoadRequestsCoalesceUntilCompletion`: issue two load requests while the first fake load is blocked, expect both calls to return the same request ID, expect the fake load to run once, and expect both completion callbacks to run after the load exits.
- `productLoadCancellationDoesNotRecordPurchaseOrRestoreFailure`: cancel a request through the testing hook, wait for it, and assert pending IDs clear without mutating purchase/restore request failures.

Create `StoreProductLoadIntentBoundaryTests`:
- scan `ProUpgradeSheet.swift`;
- assert it does not contain `await storeManager.loadProducts()` or a SwiftUI `.task` body that directly owns product loading;
- assert it calls `storeManager.requestProductLoad`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/StoreManagerLifecycleTests -only-testing:VVTermTests/StoreProductLoadIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestProductLoad(onCompleted:)`, `pendingProductLoadRequestIDs`, `waitForProductLoadRequest(_:)`, and the testing cancellation hook do not exist. If it compiles unexpectedly, the boundary test must fail because `ProUpgradeSheet` still directly awaits `loadProducts()`.

Actual RED result: focused `StoreManagerLifecycleTests` / `StoreProductLoadIntentBoundaryTests` failed to build because `StoreManager` had no `requestProductLoad`, `pendingProductLoadRequestIDs`, `waitForProductLoadRequest`, or `cancelProductLoadRequestForTesting`.

- [x] **Step 2: Add StoreManager-owned product-load request tracking**

Update `StoreManager`:
- add a private product-load request record containing the request ID, `Task<Void, Never>`, and completion callbacks;
- expose `pendingProductLoadRequestIDs`;
- implement `requestProductLoad(onCompleted:)` so the first caller creates a tracked MainActor task and duplicate callers append completion callbacks and receive the existing request ID;
- run `loadProductsAction(self)` from the tracked task so tests keep using the existing fake seam;
- treat cancellation as lifecycle completion, not as purchase/restore failure;
- clear the request record only from the request task's `defer` when its request ID is still current;
- cancel the product-load request from `deinit`.

- [x] **Step 3: Route ProUpgradeSheet through request intent**

Update both iOS and macOS sheet lifecycle hooks:
- keep `storeManager.notePaywallPresented(source:)` synchronous in UI because it records presentation state and analytics, not StoreKit product fetch ownership;
- replace `await storeManager.loadProducts()` with `storeManager.requestProductLoad { selectedPlan = defaultPlan }`;
- preserve the existing behavior that default plan selection is refreshed after products are loaded;
- keep purchase, restore, alerts, and subscription-management UI unchanged.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/StoreManagerLifecycleTests -only-testing:VVTermTests/StoreProductLoadIntentBoundaryTests -only-testing:VVTermTests/StorePurchaseIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "await storeManager\\.loadProducts|requestProductLoad|pendingProductLoadRequestIDs|waitForProductLoadRequest" VVTerm/Features/Store/UI/ProUpgradeSheet.swift VVTerm/Features/Store/Application/StoreManager.swift VVTermTests/Features/Store/StoreManagerLifecycleTests.swift VVTermTests/StoreProductLoadIntentBoundaryTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows `ProUpgradeSheet` uses `requestProductLoad` and no direct `await storeManager.loadProducts`; StoreManager owns pending IDs and await hooks.

Actual GREEN result: focused verification passed 12 Swift Testing tests across `StoreManagerLifecycleTests`, `StoreProductLoadIntentBoundaryTests`, and `StorePurchaseIntentBoundaryTests`. Source scan showed `ProUpgradeSheet` only calls `requestProductLoad`, and direct `loadProducts(` calls remain only in `StoreManager` plus the source-boundary assertion text. `git diff --check` passed. iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `StoreManager` is the single owner of StoreKit product-load request tasks, duplicate paywall appearances coalesce to one fetch, callbacks execute only after request completion, cancellation remains lifecycle completion, SwiftUI only sends product-load intent, and touched tests include complete Test Context plus Given / When / Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 69. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

Review result: independent read-only reviewer found no Critical, Important, or Minor findings. Residual risk recorded for later consideration: product-load completion callbacks remain held by `StoreManager` until loading exits, so a dismissed paywall's callback can still update presentation state; this matches the existing post-load selection behavior and can be tightened later with per-caller cancellation tokens if needed.

## Task 70: Server Unlock Request Intent Boundary

**Files:**
- Modify: `VVTerm/Features/Security/Application/AppLockManager.swift`
- Modify: `VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift`
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Test: `VVTermTests/Features/Security/AppLockManagerTests.swift`
- Modify: `VVTermTests/AppLockIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `AppLockManager.ensureServerUnlocked(_:) async -> Bool`
  - Existing `AppLockManager.pendingAppLockRequestIDs`
  - Existing `AppLockManager.waitForAppLockRequest(_:) async`
  - Existing `ServerSidebarView.selectServer(_:)` selection behavior.
  - Existing `iOSContentView.openActiveConnection(_:)` active-connection open behavior.
- Produces:
  - `AppLockManager.requestServerUnlock(_:onUnlocked:onDenied:) -> UUID`
  - `AppLockManager.pendingServerUnlockRequestIDs`
  - Same-server server-unlock request coalescing so duplicate UI intent does not create a second biometric prompt or a false denial while `isAuthenticating` is true.
  - Server UI paths that synchronously send unlock intent instead of launching SwiftUI-owned biometric-auth tasks.

- [x] **Step 1: Add RED server-unlock lifecycle and boundary tests**

Extend `AppLockManagerTests`:
- `testServerUnlockRequestTracksAuthenticationUntilCompletion`: create a server with `requiresBiometricUnlock: true`, delay fake auth, call `requestServerUnlock`, assert the request ID is visible in both `pendingAppLockRequestIDs` and `pendingServerUnlockRequestIDs` until auth finishes, then assert `onUnlocked` fires and tracking clears.
- `testDuplicateServerUnlockRequestsCoalesceUntilCompletion`: call `requestServerUnlock` twice for the same locked server while fake auth is delayed, assert both calls return the same request ID, fake auth starts once, both `onUnlocked` callbacks fire after completion, and no `onDenied` callback fires from the duplicate path.
- `testServerUnlockCancellationDoesNotRunCallbacksOrSetError`: cancel the returned request through a DEBUG testing hook, release fake auth, wait for completion, then assert pending tracking clears, no callbacks fire, and `lastErrorMessage` remains nil.

Extend `AppLockIntentBoundaryTests`:
- scan `ServerSidebarView.swift` and `iOSContentView.swift`;
- assert these SwiftUI files do not directly call `ensureServerUnlocked(`;
- assert they call `requestServerUnlock`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppLockManagerTests -only-testing:VVTermTests/AppLockIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestServerUnlock`, `pendingServerUnlockRequestIDs`, and the server-unlock testing cancellation hook do not exist. If it compiles unexpectedly, the boundary tests must fail because `ServerSidebarView` and `iOSContentView` still call `ensureServerUnlocked(` directly.

Actual RED result: the focused suite failed before production changes because `AppLockManager` did not expose `requestServerUnlock`, `pendingServerUnlockRequestIDs`, or the server-unlock testing cancellation hook. Review-fix RED added `testServerUnlockCancellationDuringFullAppUnlockDoesNotGrantAppAccess`, which failed until `ensureAppUnlocked()` checked cancellation before granting app-level unlock state.

- [x] **Step 2: Add AppLockManager-owned server-unlock request tracking**

Update `AppLockManager`:
- add server-unlock request records keyed by server ID with request ID, `Task<Void, Never>`, and `onUnlocked` / `onDenied` callback arrays;
- expose `pendingServerUnlockRequestIDs`;
- implement `requestServerUnlock(_:onUnlocked:onDenied:)` so server-unlock decisions complete through a tracked manager task, protected servers run `ensureServerUnlocked(_:)` from that task, and duplicate same-server intent appends callbacks and returns the existing request ID;
- canceling a server-unlock request must cancel the stored task, clear visible pending state only after task exit, avoid success/denied callbacks, and keep cancellation from surfacing as `lastErrorMessage`;
- keep existing `ensureServerUnlocked(_:)` available for application-layer callers such as terminal open managers.

- [x] **Step 3: Route SwiftUI server unlock through request intent**

Update `ServerSidebarView.selectServer(_:)`:
- replace the SwiftUI-owned `Task { await AppLockManager.shared.ensureServerUnlocked(server) }` with `AppLockManager.shared.requestServerUnlock(server) { selectedServer = server }`;
- preserve existing selection behavior and do not change terminal open behavior.

Update `iOSContentView.openActiveConnection(_:)`:
- resolve the server synchronously before sending intent;
- replace direct `ensureServerUnlocked` with `requestServerUnlock(server, onUnlocked:)`;
- keep the existing reconnect/select/show-terminal sequence inside the unlocked continuation for now, and leave broader Active Connection reconnect ownership to a later task if needed.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/AppLockManagerTests -only-testing:VVTermTests/AppLockIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "ensureServerUnlocked\\(|requestServerUnlock|pendingServerUnlockRequestIDs" VVTerm/Features/Security/Application/AppLockManager.swift VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift VVTerm/App/iOS/iOSContentView.swift VVTermTests/Features/Security/AppLockManagerTests.swift VVTermTests/AppLockIntentBoundaryTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows UI files use `requestServerUnlock` and no direct `ensureServerUnlocked(`, while application-layer managers may still call the low-level async helper.

Actual GREEN result: the review-fix single regression passed with 1 XCTest test and 0 failures. The full focused suite passed 10 XCTest tests in `AppLockManagerTests` plus 4 Swift Testing tests in `AppLockIntentBoundaryTests`, with 0 failures. The source scan showed `ServerSidebarView` and `iOSContentView` only call `requestServerUnlock`; direct `ensureServerUnlocked(` remains in `AppLockManager` and test assertion text. `git diff --check` passed.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `AppLockManager` is the single owner of server-unlock authentication request tasks, duplicate same-server unlock intent cannot be denied by `isAuthenticating`, callbacks fire only after unlock decision, cancellation is lifecycle completion, SwiftUI only sends unlock intent, and touched tests include complete Test Context plus Given / When / Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 70. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

Review result: independent read-only reviewer found one Important cancellation issue. A canceled server-unlock request that was inside nested full-app-lock authentication could still grant app unlock state because `ensureAppUnlocked()` wrote `isAppLocked = false` before the server-unlock caller checked cancellation. The fix adds a cancellation check inside `ensureAppUnlocked()` before mutating unlock state, with the focused review-fix regression covering that behavior. No other Critical or Important findings remain from that review.

## Task 71: iOS Active Connection Open Intent Boundary

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- Modify: `VVTerm/App/iOS/iOSContentView.swift`
- Test: `VVTermTests/ConnectionLifecycleIntegrationTests.swift`
- Test: `VVTermTests/IOSActiveConnectionOpenIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `ConnectionSessionManager.reconnectSessionIfRuntimeInactive(_:) async -> Bool`
  - Existing `ConnectionSessionManager.selectSession(_:)`
  - Existing `ConnectionSessionManager.selectedViewByServer`
  - Existing `AppLockManager.requestServerUnlock(_:onUnlocked:onDenied:)`
  - Existing `iOSContentView.openActiveConnection(_:)`
- Produces:
  - `ConnectionSessionManager.requestActiveConnectionOpen(session:preferredViewId:onOpened:) -> UUID`
  - `ConnectionSessionManager.pendingActiveConnectionOpenRequestIDs`
  - `ConnectionSessionManager.waitForActiveConnectionOpenRequest(_:) async`
  - Same-session active-connection open coalescing so repeated taps do not start duplicate reconnect/select work.
  - iOS Active Connection open UI that sends unlock intent and then active-connection open intent, without owning a reconnect `Task`.

- [x] **Step 1: Add RED active-connection open lifecycle and boundary tests**

Extend `ConnectionLifecycleIntegrationTests`:
- `activeConnectionOpenRequestTracksReconnectUntilCompletion`: create a saved session, install a DEBUG delayed active-connection reconnect operation, call `requestActiveConnectionOpen(session:preferredViewId:onOpened:)`, assert the request ID is visible in `pendingActiveConnectionOpenRequestIDs` while the operation is delayed, release it, wait for the request, then assert the session is selected, `selectedViewByServer[server.id]` is set to the preferred view ID, the callback fires, and pending tracking clears.
- `duplicateActiveConnectionOpenRequestsCoalesceUntilCompletion`: call `requestActiveConnectionOpen` twice for the same session while the fake reconnect operation is delayed, assert both calls return the same request ID, the fake operation starts once, both callbacks fire after completion, and pending tracking clears.
- `activeConnectionOpenCancellationDoesNotSelectOrCallback`: cancel the returned request through a DEBUG testing hook while the fake operation is delayed, release it, wait for completion, then assert no callback fires and no stale selection/view update is written.

Add `IOSActiveConnectionOpenIntentBoundaryTests` with a Test Context header:
- scan `VVTerm/App/iOS/iOSContentView.swift`;
- slice `private func openActiveConnection(_ connection: ActiveConnection)`;
- assert the helper still calls `AppLockManager.shared.requestServerUnlock`;
- assert the unlocked continuation calls `sessionManager.requestActiveConnectionOpen`;
- assert the helper slice does not contain `Task {` or `reconnectSessionIfRuntimeInactive`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/IOSActiveConnectionOpenIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestActiveConnectionOpen`, `pendingActiveConnectionOpenRequestIDs`, `waitForActiveConnectionOpenRequest`, and DEBUG testing hooks do not exist. If it compiles unexpectedly, the boundary test must fail because `iOSContentView.openActiveConnection(_:)` still owns `Task { await sessionManager.reconnectSessionIfRuntimeInactive(...) }`.

- [x] **Step 2: Add ConnectionSessionManager-owned active-connection open tracking**

Update `ConnectionSessionManager`:
- add an `ActiveConnectionOpenRequest` record keyed by request ID and a session-to-request index keyed by session ID;
- expose `pendingActiveConnectionOpenRequestIDs`;
- implement `requestActiveConnectionOpen(session:preferredViewId:onOpened:)` so it creates one manager-owned task per session, calls the existing reconnect-if-runtime-inactive helper, then selects the session, sets `selectedViewByServer[session.serverId]`, and runs `onOpened` only if the request was not canceled and the session still exists;
- duplicate same-session open intent appends callbacks and returns the existing request ID;
- cancellation must clear visible pending state after task exit and must not run callbacks or write stale selection state;
- add DEBUG-only operation/cancel hooks for ordering tests, following the local request-test seams already used by retry, install, input, resize, process-exit, credential-load, and rich-paste request tests.

- [x] **Step 3: Route iOS Active Connection open through request intent**

Update `iOSContentView.openActiveConnection(_:)`:
- keep synchronous `server(for:)` resolution and `AppLockManager.shared.requestServerUnlock(server)` from Task 70;
- replace the unlocked continuation's `Task { await sessionManager.reconnectSessionIfRuntimeInactive(...) ... }` with `sessionManager.requestActiveConnectionOpen(session: connection.session, preferredViewId: targetViewId) { showingTerminal = true }`;
- preserve existing visible behavior: protected servers still require unlock first, inactive runtimes reconnect before opening, live runtimes are reused, selected session and preferred terminal view are restored, and the terminal screen is shown from the UI callback.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests -only-testing:VVTermTests/IOSActiveConnectionOpenIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "openActiveConnection|requestActiveConnectionOpen|reconnectSessionIfRuntimeInactive|Task \\{" VVTerm/App/iOS/iOSContentView.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift VVTermTests/ConnectionLifecycleIntegrationTests.swift VVTermTests/IOSActiveConnectionOpenIntentBoundaryTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows `iOSContentView.openActiveConnection(_:)` uses `requestServerUnlock` plus `requestActiveConnectionOpen`, with no helper-local `Task {}` and no direct `reconnectSessionIfRuntimeInactive` call. `ConnectionSessionManager` remains the only owner of the low-level reconnect/select sequence for this iOS Active Connection path.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `ConnectionSessionManager` is the single owner of active-connection reconnect/select work, duplicate same-session taps cannot create duplicate reconnect work, cancellation is lifecycle completion, UI only sends unlock/open intent plus presentation callback, and touched tests include complete Test Context plus Given / When / Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 71. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Task 72: RemoteFiles Move Destination Load Request Boundary

**Files:**
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/Sheets/RemoteFileBrowserSheets.swift`
- Test: `VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift`
- Test: `VVTermTests/RemoteFileMutationIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `RemoteFileBrowserStore.listDirectories(at:server:) async throws -> [RemoteFileEntry]`
  - Existing `RemoteFileMoveSheet`
  - Existing `RemoteFileBrowserScreen.moveSheet(entry:)`
  - Existing `RemoteFileBrowserStore.withRemoteFileService(for:operation:)`
- Produces:
  - `RemoteFileBrowserStore.requestMoveDestinationLoad(path:server:onCompleted:) -> UUID`
  - `RemoteFileBrowserStore.pendingMoveDestinationLoadRequestIDs`
  - `RemoteFileBrowserStore.waitForMoveDestinationLoadRequest(_:) async`
  - Path/server move-destination load coalescing so repeated sheet reloads do not start duplicate remote directory-list work.
  - Server disconnect cleanup for visible move-destination load requests.
  - Move destination UI that sends load intent synchronously and keeps only presentation state.

- [x] **Step 1: Add RED move-destination lifecycle and boundary tests**

Extend `RemoteFileBrowserStoreTests`:
- `moveDestinationLoadRequestTracksDirectoryListingUntilCompletion`: create a store with a fake delayed RemoteFiles service for one server, call `requestMoveDestinationLoad(path:server:onCompleted:)`, assert the returned ID is visible in `pendingMoveDestinationLoadRequestIDs` while the fake listing is blocked, release it, wait for the request, then assert the callback receives only directory entries sorted by name and pending tracking clears.
- `duplicateMoveDestinationLoadRequestsCoalesceUntilCompletion`: call the request API twice for the same normalized path/server while the fake listing is blocked, assert both calls return the same request ID, the fake list operation starts once, both callbacks receive the result, and pending tracking clears.
- `moveDestinationLoadCancellationRemainsAwaitableUntilListingExits`: cancel the returned request through a DEBUG testing hook while the fake listing is blocked, assert visible pending state clears immediately but `waitForMoveDestinationLoadRequest(_:)` does not return until the fake list exits, then assert no completion callback runs.
- `replacementMoveDestinationLoadAfterCancellationRemainsCurrent`: cancel a same-server/same-path request while the blocked list is still running, immediately request the same path again, assert the replacement is the visible current request, release the blocked fake, then assert the canceled callback is skipped and the replacement callback succeeds.
- `disconnectCancelsVisibleMoveDestinationLoadRequestsForServer`: start a blocked move-destination directory load, disconnect the same server, assert visible pending state clears immediately, release the fake list, and assert no canceled completion callback runs.

Extend `RemoteFileMutationIntentBoundaryTests`:
- scan `VVTerm/Features/RemoteFiles/UI/Sheets/RemoteFileBrowserSheets.swift`;
- slice `struct RemoteFileMoveSheet`;
- assert the sheet accepts a synchronous move-destination load request closure instead of an async `onLoadDirectories`;
- assert the sheet uses `.task(id: currentDirectory)` only to send intent;
- assert the sheet does not contain `Task { await loadDirectories() }` or `try await onLoadDirectories`.
- scan `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift`;
- assert `moveSheet(entry:)` calls `browser.requestMoveDestinationLoad(...)`;
- assert `moveSheet(entry:)` does not pass `try await fileBrowser.listDirectories(...)` into the sheet.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails to compile because `requestMoveDestinationLoad`, `pendingMoveDestinationLoadRequestIDs`, `waitForMoveDestinationLoadRequest`, and DEBUG cancellation hooks do not exist. If it compiles unexpectedly, the boundary test must fail because `RemoteFileMoveSheet` still owns async directory loading through `onLoadDirectories` and retry starts `Task { await loadDirectories() }`.

- [x] **Step 2: Add RemoteFileBrowserStore-owned move-destination load tracking**

Update `RemoteFileBrowserStore`:
- add a `MoveDestinationLoadRequest` record keyed by request ID, with `serverId`, normalized `path`, `task`, and completion callbacks;
- add a `MoveDestinationLoadRequestKey: Hashable` for same-server/same-path coalescing;
- expose `pendingMoveDestinationLoadRequestIDs` from the visible key-to-request index;
- implement `requestMoveDestinationLoad(path:server:onCompleted:)` so it creates one store-owned task per key, calls `listDirectories(at:server:)`, filters to directory entries, sorts by name, and calls every completion only if the request is still current and not canceled;
- duplicate same-key intent appends callbacks and returns the existing request ID;
- cancellation must remove visible pending state immediately, keep the task record until task exit, skip callbacks after cancellation, and keep the wait hook awaitable until the blocked listing exits;
- disconnect must cancel visible move-destination requests for the same server and skip callbacks from the canceled request;
- add DEBUG-only cancellation hook for ordering tests.

- [x] **Step 3: Route move destination sheet loading through request intent**

Update `RemoteFileMoveSheet`:
- replace `let onLoadDirectories: (String) async throws -> [RemoteFileEntry]` with an intent-style closure such as `let onRequestDirectories: (String, @escaping @MainActor (Result<[RemoteFileEntry], Error>) -> Void) -> Void`;
- replace `private func loadDirectories() async` with a synchronous helper that sets `isLoading`, clears `errorMessage`, and calls `onRequestDirectories(currentDirectory)`;
- change `.task(id: currentDirectory)` to call the synchronous helper;
- change Retry to call the synchronous helper directly, with no local `Task`;
- ignore stale completion callbacks if `currentDirectory` has changed since the request was sent;
- keep UI-only presentation state (`directories`, `isLoading`, `errorMessage`, selected destination) in the sheet.

Update `RemoteFileBrowserScreen.moveSheet(entry:)`:
- pass a closure that calls `browser.requestMoveDestinationLoad(path:server:onCompleted:)`;
- keep existing move behavior and sheet sizing unchanged.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "RemoteFileMoveSheet|onLoadDirectories|onRequestDirectories|requestMoveDestinationLoad|Task \\{ await loadDirectories|try await fileBrowser\\.listDirectories|pendingMoveDestinationLoad|guard currentDirectory == requestedDirectory" VVTerm/Features/RemoteFiles/UI/Sheets/RemoteFileBrowserSheets.swift VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift VVTermTests/RemoteFileMutationIntentBoundaryTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows `RemoteFileMoveSheet` sends synchronous load intent, has no retry `Task { await loadDirectories() }`, and no longer awaits `onLoadDirectories`; `RemoteFileBrowserScreen.moveSheet(entry:)` delegates remote directory listing to `RemoteFileBrowserStore.requestMoveDestinationLoad(...)`.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `RemoteFileBrowserStore` is the single owner of remote move-destination directory listing work, duplicate same-path requests cannot create duplicate SFTP list work, cancellation is visible lifecycle completion while remaining awaitable, disconnect cancels same-server move-destination loads, `RemoteFileMoveSheet` owns only presentation state, and touched tests include complete Test Context plus Given / When / Then comments.

- [x] **Step 6: Request review and commit**

Request code review for Task 72. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Task 73: Terminal Split Voice Text Intent Boundary

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Test: `VVTermTests/TerminalVoiceInputIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `TerminalTabManager.getTerminal(for:) -> GhosttyTerminalView?`
  - Existing root voice text boundary `ConnectionSessionManager.sendText(_:to:)`
  - Existing split-pane voice lifecycle owner `TerminalVoiceInputStore`
  - Existing split-pane voice target `TerminalVoiceInputTarget.pane(UUID)`
- Produces:
  - `TerminalTabManager.sendText(_ text: String, toPane paneId: UUID)`
  - Split `TerminalView` voice transcription completion that sends text intent through `TerminalTabManager` instead of directly retaining or writing a `GhosttyTerminalView`.
  - Split voice text delivery keyed to the voice request target pane, so stop/send completion does not drift to a newly focused pane before delivery.

- [ ] **Step 1: Add RED split voice text boundary tests**

Extend `TerminalVoiceInputIntentBoundaryTests`:
- Add `splitTerminalDelegatesVoiceTextSendToTabManager`.
- Read `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`.
- Slice from `private var voiceOverlay` through `private func sendTranscriptionToTerminal`.
- Assert the slice contains `TerminalTabManager.shared.sendText(trimmed, toPane: paneId)`.
- Assert the slice contains `case .pane(let paneId)`.
- Assert the slice does not contain `guard let terminal = focusedTerminal`.
- Assert the slice does not contain `terminal.sendText(trimmed)`.
- Assert the slice does not contain `DispatchQueue.main.async`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalVoiceInputIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: the focused suite fails because split `TerminalView.sendTranscriptionToTerminal(_:)` still unwraps `focusedTerminal` and dispatches `terminal.sendText(trimmed)` from SwiftUI instead of delegating text-send intent to `TerminalTabManager`.

- [ ] **Step 2: Add TerminalTabManager-owned pane text send API**

Update `TerminalTabManager` near `getTerminal(for:)`:

```swift
/// Send text to the terminal surface for a given split pane.
func sendText(_ text: String, toPane paneId: UUID) {
    guard let terminal = terminalSurfaceRegistry.surface(for: .pane(paneId)) else { return }
    terminal.sendText(text)
}
```

This API mirrors root `ConnectionSessionManager.sendText(_:to:)`. It is intentionally synchronous because voice transcription text insertion is a terminal-surface write, not SSH transport teardown/auth/connect work. Do not add request-task tracking unless the implementation starts awaiting external work.

- [ ] **Step 3: Route split voice transcription through pane text intent**

Update split `TerminalView`:
- Change both voice completion call sites to pass the request target into `sendTranscriptionToTerminal`.
- In `voiceOverlay`, keep `showingVoiceRecording = false` after send, but call `sendTranscriptionToTerminal(transcribedText, target: voiceTarget)`.
- In `toggleVoiceRecording`, keep `voiceInput.requestStopAndSend(for: voiceTarget, ...)`, but call `sendTranscriptionToTerminal(text, target: voiceTarget)`.
- Replace `private func sendTranscriptionToTerminal(_ text: String)` with:

```swift
private func sendTranscriptionToTerminal(_ text: String, target: TerminalVoiceInputTarget) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard case .pane(let paneId) = target else { return }
    TerminalTabManager.shared.sendText(trimmed, toPane: paneId)
}
```

Do not change root `TerminalContainerView` in this task; it already routes voice text through `ConnectionSessionManager.sendText(_:to:)`.

- [ ] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalVoiceInputIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "sendTranscriptionToTerminal|focusedTerminal|terminal\\.sendText\\(trimmed\\)|DispatchQueue\\.main\\.async|TerminalTabManager\\.shared\\.sendText|func sendText\\(_ text: String, toPane" VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTermTests/TerminalVoiceInputIntentBoundaryTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows split voice text send uses `TerminalTabManager.shared.sendText(trimmed, toPane: paneId)`, has no direct `focusedTerminal` unwrap inside `sendTranscriptionToTerminal`, has no direct `terminal.sendText(trimmed)`, and has no local `DispatchQueue.main.async` bridge for this path.

- [ ] **Step 5: API and boundary cleanup**

Before review, verify `TerminalTabManager` is the application owner for split-pane terminal surface text insertion, split `TerminalView` keeps only voice presentation and intent sending, no asynchronous lifecycle work was introduced, and touched tests include the Test Context plus Given / When / Then comments required by the Swift test-context rule.

- [ ] **Step 6: Request review and commit**

Request code review for Task 73. Fix Critical and Important findings, update the Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Progress Ledger

- 2026-06-21: Post-Task-72 scan selected Task 73 as the next executable lifecycle slice. Task 56 intentionally left split-pane voice text-send ownership as a named limitation, and the current split `TerminalView.sendTranscriptionToTerminal(_:)` still unwraps `focusedTerminal`, dispatches back to the main queue, and calls `terminal.sendText(trimmed)` directly from SwiftUI. Root voice text already routes through `ConnectionSessionManager.sendText(_:to:)`, so Task 73 should add the matching `TerminalTabManager.sendText(_:toPane:)` boundary and route split voice completion by the voice target pane. Keep this slice synchronous and scoped because terminal-surface text insertion is not SSH transport teardown/auth/connect work. Terminal title/PWD/background parsing, terminal interaction-state cleanup, Ghostty config reload, and other low-level Application/Core lifecycle slices remain open.
- 2026-06-21: Task 72 RED/GREEN completed with review fix and reviewer Minor covered by an additional ordering test. `RemoteFileBrowserStore` now owns tracked move-destination directory-load requests through `requestMoveDestinationLoad(path:server:onCompleted:)`, exposes `pendingMoveDestinationLoadRequestIDs` plus `waitForMoveDestinationLoadRequest(_:)`, coalesces duplicate same-server/same-path loads, keeps canceled request handles awaitable until remote list exit, skips canceled/stale callbacks, and cancels visible move-destination loads from `disconnect(serverId:)`. `RemoteFileMoveSheet` now keeps only presentation state and sends synchronous `onRequestDirectories` intent from `.task(id:)` and Retry, with a stale-current-directory guard before applying completions; `RemoteFileBrowserScreen.moveSheet(entry:)` delegates loading to `browser.requestMoveDestinationLoad(...)` instead of awaiting `fileBrowser.listDirectories(...)`. Initial RED failed to build because the request API, pending IDs, wait hook, and DEBUG cancellation hook did not exist. Follow-up RED reproduced disconnect cleanup: the same-server move-destination request stayed visible and delivered a success callback after disconnect. GREEN focused verification passed 27 Swift Testing tests across `RemoteFileBrowserStoreTests` and `RemoteFileMutationIntentBoundaryTests`; source scan showed no `onLoadDirectories`, no Retry `Task { await loadDirectories() }`, no direct `try await fileBrowser.listDirectories`, and the stale directory guard is present. `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Independent review found no Critical issues and one Important doc-sync issue, fixed here; the reviewer Minor about same-key replacement after cancellation is covered by `replacementMoveDestinationLoadAfterCancellationRemainsCurrent`. Broader terminal split-pane voice text injection, terminal title/PWD/background parsing, terminal interaction-state cleanup, Ghostty config reload, and other low-level Application/Core lifecycle slices remain open.
- 2026-06-21: Post-Task-71 scan selected Task 72 as the next executable lifecycle slice. `RemoteFileMoveSheet` still starts move-destination directory loading from SwiftUI `.task(id: currentDirectory)` and Retry still launches `Task { await loadDirectories() }`, while `RemoteFileBrowserScreen.moveSheet(entry:)` passes an async closure that directly awaits `fileBrowser.listDirectories(at:server:)`. This is remote SFTP directory-list lifecycle work and matches the RemoteFiles move-destination loading gap repeatedly deferred in the ledger. Task 72 should move this load into `RemoteFileBrowserStore` as a tracked, awaitable, coalesced request while keeping only sheet presentation state in SwiftUI. Terminal split-pane voice text injection, terminal title/PWD/background parsing, terminal interaction-state cleanup, Ghostty config reload, and broader low-level Application/Core tracked tasks remain deferred.
- 2026-06-21: Task 71 RED/GREEN completed with local lifecycle review fix. `ConnectionSessionManager` now owns tracked iOS Active Connection open requests through `requestActiveConnectionOpen(session:preferredViewId:onOpened:)`, exposes `pendingActiveConnectionOpenRequestIDs` plus `waitForActiveConnectionOpenRequest(_:)`, coalesces duplicate same-session open intent, checks/reconnects inactive runtimes, selects the session, restores the preferred terminal view, and runs presentation callbacks only after manager-owned reconnect/select work completes. `iOSContentView.openActiveConnection(_:)` now sends server-unlock intent and then active-connection open intent; it no longer owns the reconnect/select/show-terminal `Task`. Initial RED failed to build because the active-connection open request API, pending IDs, wait hook, and DEBUG ordering/cancel hooks did not exist. A follow-up RED reproduced close-path cancellation: closing a session hid the pending request but the wait hook returned before blocked reconnect work exited. GREEN keeps canceled request task handles until task defer cleanup while deriving visible pending state from the session-to-request index. Final focused verification passed 97 Swift Testing tests across `ConnectionLifecycleIntegrationTests` and `IOSActiveConnectionOpenIntentBoundaryTests`; source scan showed `openActiveConnection(_:)` uses `requestServerUnlock` plus `requestActiveConnectionOpen` with no helper-local `Task {}` or direct `reconnectSessionIfRuntimeInactive` call. `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Tool policy did not permit spawning an independent review subagent without explicit user delegation, so review was local against the Swift lifecycle checklist; no remaining Critical or Important issues were found. Broader RemoteFiles move-destination loading, split-pane voice text injection, terminal title/PWD/background parsing, terminal interaction-state cleanup, and other deferred lifecycle slices remain open.
- 2026-06-21: Post-Task-70 scan selected Task 71 as the next executable lifecycle slice. Task 70 moved biometric server unlock ownership out of `iOSContentView.openActiveConnection(_:)`, but the unlocked continuation still starts a SwiftUI-owned `Task` that awaits `ConnectionSessionManager.reconnectSessionIfRuntimeInactive(_:)`, selects the session, sets `selectedViewByServer`, and presents the terminal. This open-active-connection path is directly tied to the original Active Connections reconnect/auth symptoms and should be owned by `ConnectionSessionManager` as a tracked request. Broader RemoteFiles move-destination loading, split-pane voice text injection, terminal title/PWD/background parsing, and terminal interaction-state cleanup remain deferred.
- 2026-06-21: Post-Task-69 scan selected Task 70 as the next executable lifecycle slice. `ServerSidebarView.selectServer(_:)` and iOS `openActiveConnection(_:)` still create SwiftUI-owned tasks that directly await `AppLockManager.shared.ensureServerUnlocked(server)`. This is biometric authentication lifecycle work, and `AppLockManager` already owns nearby app-unlock/full-lock request tracking, so Task 70 should add a server-specific request API with same-server coalescing and route these UI paths through intent callbacks. Broader Active Connection reconnect orchestration, RemoteFiles move-destination directory loading, split-pane voice text injection, and terminal interaction-state cleanup remain deferred.
- 2026-06-21: Task 70 RED/GREEN completed with review fix. `AppLockManager` now owns tracked server-unlock request tasks through `requestServerUnlock(_:onUnlocked:onDenied:)`, exposes `pendingServerUnlockRequestIDs`, coalesces duplicate same-server unlock intent into one biometric auth flow, cancels pending server-unlock work as lifecycle completion, and keeps server-unlock cancellation from running callbacks or granting prompt-free server access. `ServerSidebarView.selectServer(_:)` and iOS `openActiveConnection(_:)` now synchronously send server-unlock intent instead of directly awaiting `ensureServerUnlocked(_:)`; the iOS active-connection reconnect/select/show-terminal work remains inside the unlocked continuation and broader reconnect ownership stays deferred. Initial RED failed to build because the server-unlock request API, pending IDs, and testing cancellation hook did not exist. Independent review found one Important issue: cancellation during nested full-app-lock authentication could still unlock the app. Review-fix RED reproduced it, and GREEN passed after `ensureAppUnlocked()` checks cancellation before mutating app unlock state. Final focused verification passed 10 XCTest tests plus 4 Swift Testing tests; source scan showed UI files only call `requestServerUnlock`; `git diff --check` passed.
- 2026-06-21: Task 69 RED/GREEN completed with independent review. `StoreManager` now owns tracked paywall product-load request tasks through `requestProductLoad(onCompleted:)`, exposes `pendingProductLoadRequestIDs` plus `waitForProductLoadRequest(_:)`, coalesces duplicate in-flight paywall load intent into one App Store product fetch, stores all completion callbacks, treats cancellation as lifecycle completion, and cancels pending product-load requests in `deinit`. `ProUpgradeSheet` no longer awaits `storeManager.loadProducts()` from SwiftUI `.task`; both iOS and macOS paywall branches synchronously send product-load intent and update `selectedPlan` from the manager request completion callback, preserving post-load default-plan selection. Initial RED failed to build because the product-load request API, pending IDs, wait hook, and testing cancellation hook did not exist. GREEN focused verification passed 12 Swift Testing tests across `StoreManagerLifecycleTests`, `StoreProductLoadIntentBoundaryTests`, and `StorePurchaseIntentBoundaryTests`; source scan showed `ProUpgradeSheet` only uses `requestProductLoad`; `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Independent review found no Critical, Important, or Minor issues; residual callback-after-dismiss risk is noted for a possible later per-caller cancellation-token slice.
- 2026-06-21: Post-Task-68 scan selected Task 69 as the next executable lifecycle slice. `ProUpgradeSheet` still awaits `storeManager.loadProducts()` directly from SwiftUI `.task` on both iOS and macOS while `StoreManager` already owns nearby StoreKit purchase, restore, startup refresh, review refresh, and transaction listener lifecycles. This Store product-load path affects the paywall and purchase decisions, so the next slice should add `StoreManager` product-load request tracking, duplicate paywall-load coalescing, and an await hook, then leave broader server unlock, RemoteFiles move-destination loading, split-pane voice text injection, and terminal interaction-state cleanup for later tasks.
- 2026-06-21: Task 68 RED/GREEN completed with local lifecycle review. `ServerStatsCollector` now owns tracked Stats collection request tasks through `requestStartCollecting(for:using:)` and `requestStopCollecting()`, exposes `pendingStatsCollectionRequestIDs` and `waitForStatsCollectionRequest(_:)`, cancels stale visibility/retry requests, waits canceled queued start work from stop requests, and makes `startCollecting(for:using:)` cancellation-aware after pending stop/collection waits so a canceled queued start cannot create a replacement lease after a newer stop intent wins. `ServerStatsView` no longer starts collection from Retry with `Task { await ... }` and no longer uses `.task(id: makeTaskKey())` to directly await start/stop; it sends visible/hidden/retry/disappear intent synchronously to the collector. Initial RED failed to build because the request APIs and wait hook did not exist. GREEN focused verification passed 10 Swift Testing tests across `ServerStatsCollectorLifecycleTests` and `ServerStatsIntentBoundaryTests`; expanded Stats verification passed 10 XCTest parsing/domain tests plus the 10 Swift Testing lifecycle/boundary tests; source scan showed Stats UI has only request API calls and no direct await start/stop; `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Local review found no Critical or Important issues.
- 2026-06-21: Post-Task-67 scan selected Task 68 as the next executable lifecycle slice. `ServerStatsView` still starts Stats collection work directly from SwiftUI: Retry wraps `await statsCollector.startCollecting(...)` in a `Task`, visibility uses `.task(id: makeTaskKey())` to await start/stop, and disappearance calls the low-level stop helper directly. Historical Task 18 allowed this as an intermediate state, but the current Swift lifecycle rule is stricter: UI should send intent while `ServerStatsCollector` owns tracked, awaitable lifecycle-critical tasks. Task 68 should add collector-owned start/stop request APIs, preserve borrowed lease behavior, and keep queued-start cancellation from creating a replacement Stats lease after a newer stop intent wins.
- 2026-06-21: Task 67 RED/GREEN completed with review fixes. RED added `TerminalRichPasteUploadRequestTests` and `TerminalRichPasteIntentBoundaryTests`; after fixing test syntax, the focused suite failed to compile because `TerminalRichPasteUploadRequestResult`, session/pane rich paste request APIs, pending request IDs, wait hooks, and injectable upload/lease seams did not exist. GREEN adds `TerminalRichPasteUploadRequest` under TerminalSessions Application to own `lease.withExclusiveClient`, awaited `lease.close()`, progress/result mapping, and shell-escaped remote path input. `ConnectionSessionManager` and `TerminalTabManager` now own tracked rich paste upload request dictionaries, same-entity supersession, pending IDs, wait hooks, close/reset cancellation, default `TerminalRichPasteCoordinator` upload adaptation, and DEBUG lease/upload seams. `TerminalRichPasteSupport` now only intercepts paste, presents prompt/progress/banner state, and sends upload intent through `requestSessionRichPasteUpload(...)` / `requestPaneRichPasteUpload(...)`; it no longer stores `activePasteTask`, resolves leases, instantiates the coordinator, closes leases, or directly sends uploaded paths to terminal surfaces. `RemoteClipboardTransferService` no longer starts a delayed stale-file sweep task; cleanup is best-effort and awaited inside upload before the rich paste request closes its lease. Independent read-only review found two Important issues: close/reset cancellation dropped rich-paste request handles before tasks actually exited, and superseded requests could still clear newer visible progress. Follow-up RED reproduced early `closeSessionAndWait`/`closePaneAndWait` completion and stale progress cleanup; GREEN keeps canceled request handles until task defer cleanup, makes close/disconnect/reset await canceled rich-paste tasks before SSH unregister, and gates progress callbacks on the current request ID. Re-review then found root-session shell teardown still started before canceled rich-paste tasks exited because `closeSessionUI` created the shell teardown task immediately; strengthened RED proved the shell cancel handler started before the upload gate opened. Final GREEN carries an inert `ShellTeardownRequest` out of `closeSessionUI`, then runs shell/runtime teardown and unregister only after canceled rich-paste tasks exit. Focused GREEN verification passed `ConnectionLifecycleIntegrationTests`, `TerminalRichPasteIntentBoundaryTests`, and `TerminalRichPasteUploadRequestTests` with 102 Swift Testing tests using `ENABLE_DEBUG_DYLIB=NO`; source scan showed UI files contain only manager request APIs while application request code owns `withExclusiveClient` and `await lease.close()`, and `RemoteClipboardTransferService` has no `Task(priority: .utility)` stale sweep; `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. The independent reviewer and re-review reported no Critical findings; all Important findings were fixed before commit.
- 2026-06-21: Task 66 re-review completed clean after follow-up fixes. The reviewer confirmed the prior Critical queued-disconnect gap, wrong-server cancellation gap, and macOS inline-create ordering regression are resolved; no Critical, Important, or Minor findings remain. Task 67 is selected as the next executable lifecycle slice: Terminal rich paste image upload still has UI-owned `activePasteTask`, direct lease resolution/close, direct `TerminalRichPasteCoordinator.performRichPaste(...)`, and a delayed stale-file cleanup task in `RemoteClipboardTransferService` that can outlive the lease. The next task should move image upload request ownership into TerminalSessions Application/manager APIs while leaving prompt and notice presentation in UI.
- 2026-06-21: Task 66 external read-only review completed and follow-up fixes passed. Reviewer found one Critical and two Important issues: pending navigation created before `BrowserState` existed was not canceled by `disconnect(serverId:)`, wrong-server navigation intent canceled the current tab request before validating, and macOS inline folder creation fired navigation intent then immediately computed a destination folder name and created the directory against stale entries. Follow-up RED added `disconnectCancelsQueuedNavigationBeforeRuntimeStateExists`, `wrongServerNavigationIntentDoesNotCancelCurrentTabRequest`, and a source-boundary assertion for navigation-dependent inline creation; the focused suite failed on all three behaviors before the fix. GREEN adds `serverId` to `NavigationRequest`, makes disconnect cancel pending navigation by server even without runtime state, validates tab/server identity before canceling/publishing a request, and continues macOS inline folder creation only from `.loadedDirectory(destinationPath)` completion while routing creation through `requestMutation`. Focused verification passed `RemoteFileBrowserStoreTests` plus `RemoteFileNavigationIntentBoundaryTests` with 20 Swift Testing tests; source scan showed scoped UI navigation uses `requestNavigation` and no inline-create fire-and-continue task remains; `git diff --check` passed. Reviewer Minor about `resetForTesting()` was classified as plan wording drift: `RemoteFileBrowserStore` has no reset hook and its tests use fresh store/defaults instances, so no cleanup hook is required for this task.
- 2026-06-21: Task 66 RED/GREEN completed with local lifecycle review fix. `RemoteFileBrowserStore` now owns tracked navigation request tasks through `requestNavigation(_:in:server:onCompleted:)`, with `RemoteFileNavigationAction`, `RemoteFileNavigationResult`, visible pending request IDs, an await hook, same-tab cancellation, cleanup integration, and stale completion guards. `RemoteFileBrowserScreen`, `RemoteFileBrowserIOSScreen`, `RemoteFileBrowserMacScreen`, and `ConnectionTabsView` now send RemoteFiles initial load, refresh, go up, breadcrumb open, directory open, and entry activation intent through the store request API instead of owning async navigation tasks. Initial RED failed to compile because `requestNavigation`, pending IDs, wait hooks, and navigation result types did not exist. The first GREEN attempt passed source-boundary tests but exposed an over-strong test assumption about same-server SFTP operation serialization; the test was narrowed to avoid coupling to adapter queueing while preserving stale-result coverage. Local review then found an Important stale state-write gap in symlink activation: a canceled blocked `stat` could still select a stale file after a newer activation. Review-fix RED reproduced `/latest.log` overwriting `/current.log`; GREEN passes request IDs into activation and checks current request identity after remote `stat` before writing state. Final focused verification passed `RemoteFileBrowserStoreTests` plus `RemoteFileNavigationIntentBoundaryTests` with 18 Swift Testing tests; source scan showed only request API calls in scoped UI; `git diff --check` passed.
- 2026-06-21: Post-Task-65 scan selected Task 66 as the next executable lifecycle slice after local source scans and two read-only explorer reviews. The non-Terminal explorer recommended RemoteFiles directory navigation/activation because `RemoteFileBrowserScreen`, `RemoteFileBrowserIOSScreen`, `RemoteFileBrowserMacScreen`, and `ConnectionTabsView` still wrap initial load, refresh, go up, breadcrumb open, directory open, and entry activation in SwiftUI-owned async work while `RemoteFileBrowserStore` already owns the lower-level stale-result guard. The Terminal explorer recommended rich paste upload/lease lifecycle as the highest-risk remaining TerminalSessions slice, but that is deferred so Task 66 can complete a cohesive RemoteFiles request boundary after Task 64's preview-load boundary and Task 65's Terminal credential-load boundary. Stats retry, AppLock server unlock, iOS active-connection open orchestration, Ghostty config reload, Store product reload, terminal retry, host retrust, rich paste upload/lease lifecycle, and title/PWD/background callbacks remain deferred.
- 2026-06-21: Task 65 RED/GREEN completed with review fix. `TerminalContainerView` and split `TerminalView` no longer directly await manager `loadCredentials(for:)` from SwiftUI credential-load paths; they synchronously send intent to `ConnectionSessionManager.requestSessionCredentialLoad(...)` and `TerminalTabManager.requestPaneCredentialLoad(...)`, then update only presentation `@State` from callbacks guarded by current server/pane identity. The managers now own tracked credential-load request tasks, duplicate same-session/pane coalescing, pending request IDs, wait hooks, close/reset cancellation, stale completion guards, and keep cancellation from surfacing as a user-facing credential failure. Initial RED failed to compile because request APIs, pending IDs, and wait hooks did not exist. Independent review found one Important issue: close cancellation removed task handles before blocked credential providers exited, so wait hooks were not truly awaitable. Follow-up RED failed two close-cancellation tests until cancellation was changed to unpublish visible pending IDs while retaining task records until task `defer` cleanup; after the fix, `ConnectionLifecycleIntegrationTests` passed 92 Swift Testing tests. Final focused verification passed `ConnectionLifecycleIntegrationTests` plus `TerminalCredentialLoadIntentBoundaryTests` with 94 Swift Testing tests; source scan showed only UI request API calls and application-layer low-level helper calls. `git diff --check` passed. Remaining lifecycle slices for terminal retry, host retrust, rich paste upload/lease lifecycle, title/PWD/background callbacks, iOS active-connection open orchestration, RemoteFiles navigation, Stats retry, Ghostty config reload, Store product reload, and AppLock server unlock remain deferred.
- 2026-06-21: Post-Task-64 scan selected Task 65 as the next executable lifecycle slice after two read-only explorer reviews plus local scans. The TerminalSessions explorer recommended terminal credential-load ownership as the smallest high-risk remaining terminal slice: `TerminalContainerView` starts credential loading from `.task` and `Task { await loadCredentialsIfNeeded(force:) }`, directly awaits `ConnectionSessionManager.loadCredentials(for:)`, and split `TerminalView` directly awaits `TerminalTabManager.loadCredentials(for:)` inside SwiftUI `.task` work. Credential loading reads Keychain-backed server credentials and gates terminal surface creation/reconnect, so it is more lifecycle-critical than display metadata callbacks. The non-Terminal explorer recommended RemoteFiles directory navigation/activation as a clean follow-up because UI still wraps `goUp`, `refresh`, `openDirectory`, `openBreadcrumb`, and `activate` in `Task {}`; that remains deferred to a later task. Rich paste upload/lease lifecycle, title/PWD/background callbacks, iOS active-connection open orchestration, RemoteFiles navigation, Stats retry, Ghostty config reload, Store product reload, and AppLock server unlock are explicitly out of Task 65.
- 2026-06-21: Task 64 RED/GREEN completed with review fixes. Initial RED failed to compile because `RemoteFileBrowserStore.requestPreviewLoad(...)`, `pendingPreviewLoadRequestIDs`, and `waitForPreviewLoadRequest(_:)` did not exist; a review-cycle RED then reproduced missing `focus(_:in:)` cleanup. GREEN routes macOS/iOS preview callbacks through synchronous `requestPreviewLoad(...)` intent, while `RemoteFileBrowserStore` owns tracked preview-load tasks, duplicate same-tab/same-entry/same-flag coalescing, cancellation, and cleanup. Review found Critical awaitability/stale-completion gaps: cancellation removed the task handle before work exited, and canceled reads that ignored cancellation could still pass stale `viewerRequestIDs` checks. Fixes keep canceled task handles until task `defer` cleanup, unpublish only the active tab request on cancel, invalidate `viewerRequestIDs`, check `Task.isCancelled` after remote awaits and before success/error writes, remove unused request state, and reset `isLoadingViewer` during directory loads. Important review coverage gaps were closed with tests for `clearViewer(for:)`, `focus(_:in:)`, `loadDirectory(path:in:server:)`, `removeRuntimeState(for:)`, and `disconnect(serverId:)` proving visible pending state clears immediately, canceled work remains awaitable until the blocked fake read exits, and stale payload/error writes do not return. Focused GREEN verification passed 14 Swift Testing tests in 2 suites with `ENABLE_DEBUG_DYLIB=NO`; source scan and full build verification are recorded before commit.
- 2026-06-21: Post-Task-63 scan selected Task 64 as the next executable lifecycle slice. Terminal root/split process-exit, input, resize, surface attach, retry, host retrust, and voice ownership have request APIs in TerminalSessions, so the next repeatedly deferred non-TerminalSessions hotspot is RemoteFiles preview loading. `RemoteFileInspectorView` only sends synchronous `onLoadPreview` intent from `.task(id:)`, but the macOS and iOS platform containers still wrap that intent in `Task { await browser.loadPreview(...) }`, causing SwiftUI to own remote preview read/download work and making cleanup depend on request IDs rather than an awaitable/tracked task. Task 64 should add a store-owned `requestPreviewLoad(...)` boundary and route platform preview callbacks through it. Do not widen Task 64 into directory navigation/goUp/breadcrumbs, file activation, transfers, drops/file promises, preview text save, rich paste, credential reload, Stats retry, or terminal title/PWD/background parsing.
- 2026-06-21: Task 63 RED/GREEN completed with independent review. `ConnectionSessionManager` now owns tracked root process-exit requests via `requestSessionProcessExit(forSession:)`, with pending request IDs, an await hook, duplicate same-session coalescing, missing-session rejection, DEBUG operation seam, and close/reset cleanup. Root `TerminalContainerView` process-exit callbacks now synchronously send intent through the manager request API and no longer wrap process exit in `DispatchQueue.main.async { ConnectionSessionManager.shared.handleShellExit(for:) }`. RED focused verification failed to compile because `setProcessExitOperationForTesting(...)` and the request bookkeeping APIs did not exist on `ConnectionSessionManager`. GREEN focused verification passed 12 Swift Testing tests in 2 suites with `ENABLE_DEBUG_DYLIB=NO`. Source scan showed only the two root `requestSessionProcessExit` callbacks in `TerminalContainerView`; remaining `DispatchQueue.main.async` hits in `SSHTerminalWrapper` are non-process-exit callback bridges and stay deferred with rich paste, credential reload, title/PWD/background parsing, RemoteFiles navigation/preview, Stats retry, and theme/background color parsing. `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. API cleanup matched the existing `requestSessionInput`, `requestSessionResize`, and `requestPaneProcessExit` request style; UI supplies only intent while manager-owned work handles tracking, coalescing, cancellation, and low-level exit invocation. Independent code review found no Critical or Important issues.
- 2026-06-21: Post-Task-62 scan selected Task 63 as the next executable lifecycle slice after two read-only explorer reviews. The TerminalSessions explorer recommended root terminal process-exit because Task 62 deliberately fixed only split panes; `TerminalContainerView` still wraps root `onProcessExit` in `DispatchQueue.main.async` and directly calls `ConnectionSessionManager.handleShellExit(for:)`, while `ConnectionSessionManager` exposes only a low-level synchronous handler and no tracked request API. The cross-feature explorer recommended RemoteFiles preview loading as the next non-TerminalSessions slice, but that remains deferred until the root/split process-exit boundary is symmetrical. Task 63 should mirror the Task 62 request API on `ConnectionSessionManager` and route root UI callbacks through it. Do not widen Task 63 into rich paste, credential reload, title/PWD/background callbacks, RemoteFiles navigation/preview/drop/file-representation, Stats retry, or theme/background parsing.
- 2026-06-21: Task 62 RED/GREEN completed through focused implementation and review. `TerminalTabManager` now owns tracked split-pane process-exit requests via `requestPaneProcessExit(forPane:)`, with pending request IDs, an await hook, duplicate same-pane coalescing, missing-pane rejection, DEBUG operation seam, and close/reset cleanup. Split `TerminalView.handlePaneExit(paneId:)` now sends synchronous process-exit intent through its injected `tabManager` and no longer creates `Task { await tabManager.handlePaneExit(for:) }` from SwiftUI. RED focused verification failed to build because the process-exit testing seam/request APIs did not exist. GREEN focused verification passed 6 Swift Testing tests in 2 suites with `ENABLE_DEBUG_DYLIB=NO`; the source scan showed only callback routing plus `requestPaneProcessExit`, with no UI-owned pane-exit task wrapper. `git diff --check` passed and iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Independent code review found no Critical or Important issues. Task 62 stayed scoped to split panes only; root process-exit, rich paste, credential reload, title/PWD/background parsing, RemoteFiles navigation, Stats retry, and theme/background color parsing remain deferred slices.
- 2026-06-21: Post-Task-61 scan selected Task 62 as the next executable lifecycle slice, then narrowed it after read-only explorer review. The working tree was clean after Task 61, so terminal UI, RemoteFiles, Stats, Settings, and App hotspots were rescanned. The narrowest remaining TerminalSessions bridge is split-pane process-exit handling: `TerminalView.handlePaneExit(paneId:)` still launches a SwiftUI-owned `Task` to await `TerminalTabManager.handlePaneExit(for:)`, while the manager exposes only a low-level async handler and no tracked request API. Root process exit still has a direct `DispatchQueue.main.async` bridge to `ConnectionSessionManager.handleShellExit(for:)`, but it is not bundled into Task 62 because the safer root fix likely needs a separate main-actor callback bridge decision. Task 62 should not revisit raw SSH ownership; it should add a tracked pane process-exit request API and route split UI callbacks through it. Rich paste upload ownership is a larger follow-up because it includes prompt state, leases, upload coordination, and active upload cancellation; credential reload, title/PWD/background callbacks, RemoteFiles navigation/preview/drop/file-representation, Stats retry, root process-exit, and theme/background parsing also remain deferred.
- 2026-06-21: Task 61 RED/GREEN completed with local review. `SSHTerminalWrapper` root terminal resize callbacks, `SSHTerminalPaneWrapper` split-pane resize callbacks, and iOS active redraw resize now send synchronous resize intent to `ConnectionSessionManager.requestSessionResize(...)` or `TerminalTabManager.requestPaneResize(...)`; UI files no longer create `Task { await ...resize... }` wrappers for resize. The managers now own tracked resize request tasks, reject invalid dimensions and missing sessions/panes, coalesce duplicate same-entity requests to one request ID, re-read and apply the latest size until no newer size is pending, recheck entity liveness before each low-level resize, and cancel/clear pending resize bookkeeping during real session/pane close paths plus DEBUG reset cleanup. Initial RED failed to compile because `TerminalResizeRequestSize`, resize request APIs, pending IDs, wait hooks, and DEBUG seams did not exist. A follow-up RED reproduced a subtler ordering gap where a new size arriving while an earlier resize operation was awaiting would be lost; the GREEN fix changed the manager-owned task to loop until the observed stored size stops changing. Focused GREEN verification passed 13 Swift Testing tests in 2 suites with `ENABLE_DEBUG_DYLIB=NO`. Source scan showed only `requestSessionResize` / `requestPaneResize` calls in the scoped UI files and no direct UI `resizeSession` / `resizePane` wrappers. `git diff --check` passed. iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Current tool constraints did not permit spawning an independent reviewer without an explicit subagent request, so review was local against the Task 61 plan and Swift lifecycle checklist; no Critical or Important issues remained. Remaining lifecycle `Task` slices for rich paste, title/PWD/background parsing, process-exit/pane lifecycle, RemoteFiles navigation/preview/drop/file-representation, Stats retry, and credential reload remain deferred to later tasks.
- 2026-06-21: Post-Task-60 scan selected Task 61 as the next executable lifecycle slice. The working tree was clean after Task 60, so terminal UI, RemoteFiles, Stats, and Settings hotspots were rescanned. A read-only explorer and local scan found the narrowest remaining TerminalSessions bridge in terminal resize callbacks: root `SSHTerminalWrapper` macOS/iOS paths, split `SSHTerminalPaneWrapper` paths, and the iOS active-connection redraw path still launch UI-owned `Task` wrappers around manager resize APIs. Task 20 already moved raw SSH resize ownership into managers, so Task 61 should not revisit raw client ownership; it should move resize request task ownership, pending tracking, coalescing, and close cleanup into `ConnectionSessionManager` and `TerminalTabManager`. Broader RemoteFiles navigation/preview tasks, rich paste lifecycle, title/PWD/background callbacks, process-exit/pane lifecycle, and Stats retry remain deferred to later slices.
- 2026-06-21: Task 60 RED/GREEN completed with review fixes. `SSHTerminalCoordinator.sendToSSH(_:)`, reused split-pane terminal write callbacks, and split-pane coordinator input now send synchronous intent to `ConnectionSessionManager.requestSessionInput(...)` or `TerminalTabManager.requestPaneInput(...)` instead of creating UI-owned `Task { await ...sendInput(...) }` wrappers. The managers own tracked input request tasks, reject empty payloads and missing sessions/panes, serialize rapid writes per session/pane by awaiting the previous request task, recheck liveness before low-level send, expose pending request IDs plus wait hooks, and reset DEBUG input seams during test cleanup. Review found one Important issue: close paths canceled install/retry/host-retrust work but did not cancel/clear the newly introduced input request bookkeeping. Follow-up RED tests reproduced this through the real `closeSessionAndWait(...)` and `closePaneAndWait(...)` paths, failing because `pendingInputRequestIDs` remained non-empty after close. The fix added close-path `cancelInputRequests(for:)` helpers that scan all matching request records, cancel/remove them, and clear the latest-request plus last-task indexes before session/pane state is removed. The initial RED failed to compile because request APIs, pending IDs, wait hooks, and DEBUG input seams did not exist; the close-path RED failed with the expected non-empty pending request assertions. GREEN focused verification passed 10 Swift Testing tests in 2 suites with `ENABLE_DEBUG_DYLIB=NO`. The boundary scan showed only `requestSessionInput` / `requestPaneInput` in the terminal wrapper and split wrapper input paths, with no direct UI `sendInput` calls. `git diff --check` passed. A concurrent test/build attempt hit Xcode `build.db` lock, then the focused test was rerun sequentially and passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Remaining `Task {}` hits in terminal wrapper/split files are existing resize, rich-paste, title/background parsing, process-exit/pane lifecycle, file navigation, and credential reload paths and remain deferred to later slices.
- 2026-06-21: Post-Task-59 scan selected Task 60 as the next executable lifecycle slice, then corrected it after read-only review. The first checkpoint planned resize request tracking, but a focused explorer pointed out that Task 20 already moved raw resize ownership into managers and the current resize callbacks already call `resizeSession` / `resizePane` rather than raw SSH clients. The remaining higher-risk terminal UI bridge is input: root `SSHTerminalCoordinator.sendToSSH(_:)` and split pane write callbacks still launch UI-owned `Task` wrappers around `sendInput`, and rapid writes can race because ordering is not owned by a manager request queue. Task 60 is therefore corrected to terminal input intent ownership. It should not widen into resize, rich paste, title/background parsing, process-exit, or RemoteFiles navigation tasks.
- 2026-06-21: Task 59 RED/GREEN completed with review fixes. `SSHTerminalWrapper` and split `SSHTerminalPaneWrapper` no longer decide shell-missing, shell-start-in-flight, reconnect-reset, app-active, or background-suspend attach policy before starting runtime work. They now pass value-only `TerminalSurfaceAttachContext` plus the concrete `GhosttyTerminalView` to `ConnectionSessionManager.requestSurfaceAttach(...)` or `TerminalTabManager.requestSurfaceAttach(...)`. The managers own tracked surface attach request tasks, revalidate duplicate pending intent against the latest UI context, store that latest context for the task to recheck before attaching, reject existing shell/shell-start-in-flight cases, expose pending request IDs plus wait hooks, and reset DEBUG attach seams during test cleanup. Root-session requests consume reconnect reset only after an accepted attach decision and require app active, view active, no background suspension, and auto-reconnect for disconnected sessions; macOS and iOS root wrappers both pass the `sshAutoReconnect` preference. Split-pane requests use the same active-context and shell guards without adding root-only reconnect-reset behavior. Initial RED failed to compile because `TerminalSurfaceAttachContext`, request APIs, pending IDs, wait hooks, and DEBUG attach seams did not exist. Review found two Important issues: inactive duplicate context was being treated as accepted, and macOS root context hard-coded auto-reconnect. Both were fixed, and narrow re-review reported no remaining findings. GREEN focused verification passed 7 Swift Testing tests in 2 suites with `ENABLE_DEBUG_DYLIB=NO`. The boundary scan showed no forbidden root wrapper references to `shellId(for:)`, `isShellStartInFlight`, `consumeTerminalReconnectReset`, `isSuspendingForBackground`, or direct `Task { await ConnectionSessionManager.shared.attachSurface... }`, and no forbidden split wrapper references to `shellId(for:)`, `isShellStartInFlight`, or direct `Task { await TerminalTabManager.shared.attachSurface... }`. `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Remaining `Task {}` hits in terminal wrapper/split files are existing credential reload, process-exit/pane lifecycle, file navigation, resize/input/rich-paste/title/background parsing paths and remain deferred to later slices.
- 2026-06-21: Post-Task-58 scan selected Task 59 as the next executable lifecycle slice. The working tree was clean after Task 58, so remaining SwiftUI lifecycle hotspots were rescanned. A read-only explorer and local scan found the clearest next TerminalSessions gap in terminal surface attach/start policy: `SSHTerminalWrapper` and split `SSHTerminalPaneWrapper` still create untracked attach `Task` wrappers and let representables decide shell-missing, shell-start-in-flight, reconnect-reset, app-active, and background-suspend policy before calling application managers. This can start runtime work from SwiftUI/representable callbacks and still relies on stale display `connectionState` in the iOS update path. Task 59 should move attach/start policy into `ConnectionSessionManager` and `TerminalTabManager` request APIs, keep UI limited to surface/presentation context, and defer resize/input/rich-paste callback task bridges to later slices.
- 2026-06-21: Task 58 RED/GREEN completed with review fix. `iOSContentView.disconnectActiveConnection(_:)`, `iOSContentView.disconnectCurrentServerSessions()`, and `ConnectionTabsView.disconnectFromServer()` now synchronously send server-disconnect intent to `ServerConnectionLifecycleCoordinator.shared.requestServerDisconnect(...)` instead of launching SwiftUI-owned `Task` blocks that manually await terminal manager teardown. `ServerConnectionLifecycleCoordinator` lives in App/Application as the cross-feature owner for server-scoped disconnect request ordering; it tracks request tasks by request ID, coalesces duplicate same-server intent, awaits RemoteFiles teardown before file-tab cleanup and terminal disconnect, then drains queued presentation callbacks after teardown completes. Initial RED focused tests failed to compile because `ServerConnectionLifecycleCoordinator` did not exist. An intermediate GREEN attempt exposed boundary-test failures where UI closure literals still contained direct `await sessionManager.disconnectServerAndWait` / `await tabManager.disconnectServerAndWait`; passing the async manager methods as side-effectful actions fixed the boundary. Review found no Critical issues and one Important callback-coalescing edge: completion callbacks appended by synchronous same-server reentry during completion delivery were appended after the old snapshot and then dropped. Review-fix RED reproduced the missing `complete-2` callback; GREEN drains completion callbacks by index until no newly appended callbacks remain, preserving one teardown chain for reentrant duplicate intent. Narrow re-review found no remaining Critical, Important, or Minor issues. Final focused tests passed 6 Swift Testing tests in 2 suites. The scoped source scan shows the three disconnect helpers call `requestServerDisconnect(...)` and contain no helper-local `Task {}` wrappers or direct old await calls; remaining `Task {}` hits in the scanned files are existing non-disconnect file navigation, Active Connection open, terminal-state recovery, and deferred UI paths. `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`.
- 2026-06-21: Post-Task-57 scan selected Task 58 as the next executable lifecycle slice. Current plan checkboxes were complete and the working tree was clean after Task 57, so the codebase was rescanned for remaining SwiftUI-owned lifecycle work. Task 38 already made `RemoteFileBrowserStore.disconnect(serverId:)` trackable/awaitable, but iOS active-connection disconnect, iOS current-server disconnect, and shared tab-container server disconnect still create SwiftUI-owned `Task` blocks that manually sequence RemoteFiles teardown, file-tab cleanup, terminal manager disconnect, and navigation completion. This is lifecycle-critical cross-feature orchestration and should live in an App/Application owner. Task 58 should add a tracked `ServerConnectionLifecycleCoordinator`, preserve existing UI callbacks, and leave broader RemoteFiles navigation operations, terminal surface attach, rich paste, and resize/title task cleanup deferred to later slices.
- 2026-06-21: Task 57 RED/GREEN completed with review fixes. `TerminalContainerView.retrustHostAndRetry()` and split `TerminalView.retrustHostAndRetry()` no longer create SwiftUI-owned retrust `Task` blocks or directly await `retrustHostAndReconnect`; they synchronously send host-retrust intent to `ConnectionSessionManager.requestSessionHostRetrust` or `TerminalTabManager.requestPaneHostRetrust` and only update `reconnectToken` from presentation callbacks when reconnect succeeds. Both managers now own tracked host-retrust request tasks, expose pending request IDs and await hooks for lifecycle tests, coalesce duplicate same-session/pane intent, keep trusted-host mutation plus reconnect inside the application layer, clear request state after completion, and cancel pending retrust requests with `false` callbacks when the owning session or pane closes. RED failed to compile until the request APIs, pending IDs, wait hooks, and DEBUG operation seams existed. A later focused run after adding close-cancellation tests hit an Xcode runner startup/finish hang without XCTest assertion output; after wiring close cancellation, the focused suite passed 90 Swift Testing tests in 2 suites. Review found no Critical issues and two Important cancellation gaps: canceled retrust tasks could still reach known-host mutation, and close-cancellation tests did not prove there was no later success callback. GREEN review fixes added preflight and post-mutation ownership/cancellation guards before retrust/reconnect work, and strengthened close-cancellation tests to keep callback history at `[false]` after blocked work returns. Final focused tests passed 90 Swift Testing tests in 2 suites; source scan shows the retrust helpers now call request APIs and contain no retrust-owned `Task {}` or direct old helper awaits; remaining `Task {}` hits in those files are existing non-retrust paths for credential reload, pane lifecycle, paste, and title/selection work. `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`.
- 2026-06-21: Post-Task-56 scan selected Task 57 as the next executable lifecycle slice. Current plan checkboxes were complete, so the codebase was rescanned for remaining SwiftUI-owned lifecycle tasks and direct resource mutation after terminal retry/install/voice ownership moved to manager/store request APIs. The clearest focused TerminalSessions gap is host-key retrust from terminal error alerts: root `TerminalContainerView` and split `TerminalView` still launch `Task {}` from `retrustHostAndRetry()` and directly await manager helpers that remove known-host entries and reconnect. This is lifecycle-critical because trusted-host mutation plus reconnect should be tracked by TerminalSessions Application owners, not by SwiftUI alert actions. Task 57 should add manager-owned tracked retrust request APIs, preserve existing alert/reconnectToken UX, and leave broader remaining iOS active-connection, RemoteFiles navigation, and terminal surface attach guard cleanup deferred to later slices.
- 2026-06-21: Task 56 RED/GREEN completed with local lifecycle review. `TerminalContainerView`, split `TerminalView`, and `VoiceRecordingView` no longer create or observe `AudioService` directly and no longer call `startRecording()`, `stopRecording()`, or `cancelRecording()` from SwiftUI. `TerminalVoiceInputStore` is the TerminalSessions Application owner for the shared terminal voice `AudioService`, tracks start/stop/cancel request tasks by ID, coalesces duplicate same-target intent, forwards audio presentation state to SwiftUI, preserves partial-transcription fallback, and keeps cancellation separate from permission/transcription failure. RED failed to compile until `TerminalVoiceInputStore`, `TerminalVoiceInputTarget`, the fake-audio seam, pending request IDs, and await hooks existed; an added cancellation-ordering RED then proved a late start completion could reopen recording after cancel, and GREEN passed after stale/canceled start completions cancel audio and skip stale callbacks. Final focused tests passed 8 Swift Testing tests; the direct voice lifecycle source scan produced no matches; the broader terminal UI task scan still reports existing non-voice `Task` hits in credential reload, retrust host, pane exit, paste, and title/selection paths; `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. Task 56 deliberately leaves split pane text send through the existing focused `GhosttyTerminalView` path until a narrower pane send-text application API is introduced.
- 2026-06-21: Post-Task-55 scan selected Task 56 as the next executable lifecycle slice. Current plan checkboxes were complete, so the codebase was rescanned for remaining SwiftUI-owned lifecycle tasks, direct resource ownership, and deferred ledger hits. RemoteFiles transfer/drop/file-promise and TerminalThemes persistence/sync were already completed under Task 40E4c and Task 40E5, so they are not the next slice. The clearest focused TerminalSessions gap is terminal voice input: `TerminalContainerView`, split `TerminalView`, and `VoiceRecordingView` still create or consume `AudioService` directly from SwiftUI, launch voice start/stop transcription tasks from buttons and keyboard handlers, and call `cancelRecording()` directly from view lifecycle or overlay callbacks. Task 56 should add a TerminalSessions Application voice intent owner with tracked start/stop/cancel request APIs, preserve existing root and split terminal voice UX, and leave broader iOS floating voice-return presentation and split-pane text-send API cleanup deferred unless required by the focused tests.
- 2026-06-21: Task 55 RED/GREEN completed with review fix. `TerminalContainerView` and split `TerminalView` no longer launch retry work from SwiftUI-owned `Task` blocks or directly await `retrySessionConnection` / `retryPaneConnection`; retry buttons, timeout callbacks, and watchdog callbacks synchronously send intent to `ConnectionSessionManager.requestSessionRetry` or `TerminalTabManager.requestPaneRetry`. Both managers now own tracked retry request tasks, expose pending request IDs plus await hooks for ordering tests, coalesce duplicate same-session/pane retry intent, keep cancellation as lifecycle completion rather than credential failure, and call every duplicate caller's completion callback with the final `TerminalReconnectRequestResult`. RED failed to compile until the request APIs, pending request state, await hooks, and DEBUG retry-operation injection hooks existed. Review found no Critical issues and one Important source-boundary gap: the first `TerminalRetryIntentBoundaryTests` matched only narrow exact strings and could miss multiline `Task` wrappers or direct old helper calls outside the helper slice. The boundary tests were strengthened with regex full-source scans for UI-owned retry wrappers and direct old helper calls, and the new test file was staged with the implementation. Final focused tests passed 86 Swift Testing tests; terminal UI retry source scan produced no matches; `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. The broad manager task scan still reports previously classified runtime/persist/detached tasks outside this retry slice.
- 2026-06-21: Post-Task-54 scan selected Task 55 as the next executable lifecycle slice. Current plan checkboxes were complete, so the codebase was rescanned for remaining SwiftUI-owned `Task` work and deferred ledger hits. The clearest focused TerminalSessions gap is terminal retry intent: `TerminalContainerView` and split `TerminalView` still launch retry work from SwiftUI-owned `Task` wrappers and directly await `retrySessionConnection` / `retryPaneConnection`, while the managers expose only async low-level retry helpers rather than tracked request APIs. Task 55 should add manager-owned tracked request APIs for session and pane retry intent, preserve duplicate retry coalescing and credential-load result semantics, and leave broader voice recording, iOS active-connection action orchestration, mosh fallback banner timing, and RemoteFiles navigation/mutation tasks deferred to later slices.
- 2026-06-21: Task 54 RED/GREEN completed with review fixes. `TerminalContainerView` and split `TerminalView` no longer launch tmux/mosh install work from SwiftUI-owned `Task` blocks; install buttons synchronously send intent to `ConnectionSessionManager` or `TerminalTabManager`. Both managers now own tracked tmux and mosh install request tasks, expose pending request IDs plus await hooks for ordering tests, coalesce duplicate same-session/pane tmux and mosh request intent, keep mosh cancellation separate from ordinary failure, and record ordinary mosh install failures. Close paths for sessions and panes now cancel pending install requests and run completion callbacks so presentation state can clear on lifecycle cancellation. The tmux install helpers now await the six-attempt availability poll in the request task instead of scheduling an internal untracked follow-up task. RED failed to compile until the manager request/testing APIs existed. Review found three Important lifecycle issues: close did not cancel pending install requests, cancellation could leave mosh UI cleanup callbacks unsent, and duplicate mosh callers lost callbacks. Review-fix RED reproduced missing duplicate callbacks and a pending close-cancellation wait; GREEN passed after callbacks were stored per duplicate request and close cancellation completed pending requests. Final focused tests passed 84 Swift Testing tests; the terminal UI install source scan produced no matches; `git diff --check` passed; iOS `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. The broad manager task scan still reports previously classified runtime/persist/detached tasks outside this install slice.
- 2026-06-21: Post-Task-53 scan selected Task 54 as the next executable lifecycle slice. Current plan checkboxes were complete, so the codebase was rescanned for remaining SwiftUI-owned `Task` work and deferred ledger hits. The clearest focused TerminalSessions gap is terminal install intent: `TerminalContainerView` and split `TerminalView` launch tmux and mosh install work from alert buttons, while both managers expose only awaitable low-level install helpers rather than tracked request APIs. The tmux install helpers also schedule an internal untracked poll task after sending the install script, so the UI-owned task can return before install lifecycle state settles. Task 54 should add manager-owned tracked request APIs for session and pane tmux/mosh install intent, make tmux install polling awaitable, and leave broader retry, voice recording, mosh fallback banner timing, and RemoteFiles navigation tasks deferred to later slices.
- 2026-06-21: Task 53 RED/GREEN completed with review fixes. `VVTermApp.swift` and both AppDelegate implementations no longer directly orchestrate terminal teardown, background suspension, app-lock, app-sync refresh, or server-language side effects; they send intent to `AppLifecycleCoordinator`. `AppLifecycleCoordinator` owns tracked request tasks for background lock, background suspension, remote-notification refresh completion, and termination teardown, with await hooks for ordering tests. The old blocking termination semaphore bridge was removed after it proved unsafe on MainActor; macOS termination now uses `applicationShouldTerminate(_:)` / `.terminateLater` with a timeout-bounded tracked teardown request, and iOS termination sends a tracked best-effort request. RED failed to compile until the coordinator APIs existed, review-cycle RED exposed missing background lock tracking, and a focused timeout regression test prevented a hanging termination request. Final focused tests passed 7 Swift Testing tests; source scans showed `VVTermApp.swift` only sends coordinator intent; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment / AppIntents metadata warnings.
- 2026-06-21: Post-Task-52 scan selected Task 53 as the next executable lifecycle slice. Current plan checkboxes were complete, so the codebase was rescanned for remaining SwiftUI/App-owned lifecycle `Task` work, direct app lifecycle singleton orchestration, and deferred ledger hits. The clearest focused App-layer gap is `VVTermApp.swift`: AppDelegate termination owns the semaphore bridge plus a `Task` that awaits terminal manager teardown, iOS background owns a `Task` that suspends sessions and locks the app, foreground/remote notification delegates directly call `AppSyncCoordinator.shared`, and root locale hooks call `ServerManager.shared.handleAppLanguageChange()` directly. Existing `AppSyncCoordinatorTests` already cover sync task coalescing, so Task 53 should not replace that owner; it should introduce an App Application lifecycle coordinator that receives delegate/root intent and delegates to the existing sync, terminal, app-lock, and server-language owners. Broader remaining hits in terminal UI retry/tmux/voice flows, RemoteFiles navigation/preview view tasks, and low-level Application/Core internally tracked tasks remain deferred to later slices.
- 2026-06-21: Task 52 RED/GREEN completed with review fixes. `AppLockContainer`, `AppLockGateView`, and `GeneralSettingsView` no longer own biometric authentication `Task` work; they send synchronous intent to `AppLockManager.requestAppUnlock()` or `requestFullAppLockChange(_:)`. `AppLockManager` owns tracked request tasks, exposes pending request IDs plus `waitForAppLockRequest(_:)`, preserves existing async behavior boundaries, and treats `CancellationError` as lifecycle completion rather than a user-facing auth failure. RED failed to compile until the request APIs and tracking state existed; review-fix RED proved cancellation still polluted `lastErrorMessage`. Final focused tests passed 6 XCTest tests plus 2 Swift Testing tests; the source scan showed only manager-owned app-lock tasks; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings / AppIntents metadata skip warning. Broader SwiftUI task hits in terminal, RemoteFiles, Settings language change, App sync, and low-level Application/Core paths remain deferred to later slices.
- 2026-06-21: Post-Task-51 scan selected Task 52 as the next executable lifecycle slice. Current plan checkboxes were all complete, so the codebase was rescanned for SwiftUI-owned lifecycle `Task` work, direct resource/singleton calls, and stale terminal runtime state. `AppLockContainer`, `AppLockGateView`, and the full-app-lock toggle in `GeneralSettingsView` are a focused remaining Security/Settings hit: SwiftUI launches authentication tasks directly for app unlock and full-lock enablement even though `AppLockManager` is already the stable Application owner for biometric authentication state. Broader hits remain intentionally deferred for later classification, including Terminal view retry/tmux/voice tasks, RemoteFiles navigation/preview tasks, App app-delegate sync calls, and low-level Application/Core tasks that are already tracked or need separate ownership audits.
- 2026-06-21: Task 51 RED/GREEN completed with review fix. `ServerFormSheet` no longer owns the Test Connection async `Task`, no longer launches `Task.detached`, and no longer directly reaches `SSHConnectionOperationService.shared` or `RemoteMoshManager.shared`; it sends synchronous intent to `ServerConnectionTester` in Servers Application. `ServerConnectionTester` owns tracked connection-test request tasks, exposes pending request IDs plus `waitForConnectionTestRequest`, records ordinary `ServerConnectionTestFailure`, preserves cancellation as lifecycle state rather than failure, and always calls `onCompleted` so SwiftUI can clear transient testing state after success, failure, or cancellation. RED first failed to compile until the connection tester/protocol existed; review-fix RED failed until `onCompleted` existed. Final focused tests passed 6 Swift Testing tests; scoped source scans showed the UI helper only delegates to `connectionTester.requestConnectionTest`; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings. Broader SwiftUI task hits in terminal, RemoteFiles, Settings, and other low-level paths remain deferred to later slices.
- 2026-06-21: Post-Task-50 scan selected Task 51 as the next executable lifecycle slice. Current plan checkboxes were all complete, so the codebase was rescanned for SwiftUI-owned lifecycle `Task` work, direct resource/singleton calls, and stale terminal runtime state. `ServerFormSheet` connection testing is the clearest remaining Servers feature hit: the Test Connection button starts a SwiftUI-owned `Task`, `runConnectionTest(force:)` launches `Task.detached`, and the UI file directly reaches `SSHConnectionOperationService.shared` plus `RemoteMoshManager.shared`. Broader hits remain intentionally deferred for later classification, including Terminal view retry/voice lifecycle tasks, RemoteFiles navigation/preview tasks, Settings language-change task ownership, and low-level Application/Core tasks that are already tracked or need separate ownership audits.
- 2026-06-21: Task 50 RED/GREEN completed with review fixes. `MoveServerSheet.moveServer()` no longer owns an async move `Task` or directly calls `moveServer(_:to:preferredEnvironment:)`; it sends synchronous intent to `ServerManager.requestServerMove`. `ServerManager` now owns tracked server move request tasks, exposes pending request IDs plus `waitForServerMoveRequest`, records `ServerMoveFailure`, preserves Pro-required move failures for the existing upgrade sheet, routes ordinary failures to the UI error callback, and calls success only after the existing application-layer move path updates server metadata plus workspace selection metadata. RED failed to compile until the move request APIs and failure state existed. Review found missing ordinary failure coverage and a literal source-boundary check; both were fixed, and a mutation RED proved suppressing `onFailed` breaks the ordinary failure test. Final focused tests passed 25 Swift Testing tests; a scoped `moveServer()` source scan showed only `requestServerMove` ownership; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings. Broader `Task {` hits in `ServerFormSheet.swift` are outside Task 50 and remain deferred to later slices.
- 2026-06-21: Post-Task-49 scan selected Task 50 as the next executable lifecycle slice. Current plan checkboxes were all complete, so the codebase was rescanned for SwiftUI-owned lifecycle `Task` work, direct resource/singleton calls, and stale terminal runtime state. `MoveServerSheet.moveServer()` is the clearest remaining Servers feature hit: it starts a SwiftUI-owned `Task` and directly calls `moveServer(_:to:preferredEnvironment:)` for user-initiated server relocation. Broader hits remain intentionally deferred for later classification, including RemoteFiles preview/navigation UI tasks, terminal voice recording intent ownership, residual terminal display-state reads from `ConnectionState`, and low-level Application/Core tasks that are already tracked or need separate ownership audits.
- 2026-06-21: Task 49 RED/GREEN completed with review fixes. `ServerFormSheet.saveServer()` no longer owns an async server create/update save `Task` or directly calls `updateServer(_:credentials:)` / `addServer(_:credentials:)`; it sends synchronous intent to `ServerManager.requestServerSave`. `ServerManager` now owns tracked server create/update save request tasks, exposes pending request IDs plus `waitForServerSaveRequest`, records `ServerSaveFailure`, preserves Pro-required create failures for the upgrade sheet, returns the persisted server to UI callbacks, and keeps credential-store failures from mutating metadata through the existing application-layer update path. RED failed to compile until the save request APIs and failure state existed. Review found missing Pro-required coverage and source-boundary clarity gaps, all fixed. Final focused tests passed 22 Swift Testing tests; a scoped `saveServer()` source scan showed only `requestServerSave` ownership; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings. Broader `Task {` hits in `ServerFormSheet.swift` are connection-test and move-server flows intentionally deferred to later tasks.
- 2026-06-21: Post-Task-48 scan selected Task 49 as the next executable lifecycle slice. Current plan checkboxes were all complete, so the codebase was rescanned for SwiftUI-owned lifecycle `Task` work, direct resource/singleton calls, and stale terminal runtime state. `ServerFormSheet.saveServer()` is the clearest remaining Servers feature hit: it starts a SwiftUI-owned `Task` and directly calls `updateServer(_:credentials:)` / `addServer(_:credentials:)` for credential-backed server persistence. `MoveServerSheet.moveServer()` is also lifecycle-critical, but it is intentionally deferred to a later, separate task so this slice stays focused on create/update save ownership and credential ordering.
- 2026-06-21: Task 48 RED/GREEN completed. `EnvironmentFormSheet` no longer owns an async environment save `Task` or directly calls `updateEnvironment` / `updateWorkspace`; it sends synchronous intent to `ServerManager.requestEnvironmentSave`. `ServerManager` now owns tracked environment create/update request tasks, exposes pending request IDs plus `waitForEnvironmentSaveRequest`, records `ServerEnvironmentSaveFailure`, preserves Pro-required create failures in the application layer, returns the persisted workspace after create, and returns the `updateEnvironment(_:in:)` result after update so assigned servers keep existing behavior. RED failed to compile until save request APIs and failure state existed. GREEN focused tests passed 18 Swift Testing tests; the EnvironmentForm source boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings. Local review found no Critical or Important issues.
- 2026-06-21: Post-Task-47 scan selected Task 48 as the next executable lifecycle slice. Current plan checkboxes were all complete, so the codebase was rescanned for SwiftUI-owned lifecycle `Task` work, direct resource/singleton calls, and stale terminal runtime state. `EnvironmentFormSheet.saveEnvironment()` is the clearest unplanned Servers feature hit: it starts a SwiftUI-owned `Task` and directly calls `updateEnvironment` / `updateWorkspace` for user-initiated environment persistence. Broader hits remain intentionally deferred for later classification, including Server form save/move request ownership, RemoteFiles preview/navigation UI tasks that mostly load view data, terminal voice recording intent ownership, and residual terminal display-state reads from `ConnectionState`.
- 2026-06-21: Task 47 RED/GREEN completed. `WorkspaceFormSheet` no longer owns async workspace save/delete `Task` blocks or directly calls `addWorkspace`, `updateWorkspace`, or `deleteWorkspace`; it sends synchronous intent to `ServerManager.requestWorkspaceSave` and `requestWorkspaceDeletion`. `ServerManager` now owns tracked workspace create/update request tasks, exposes pending request IDs plus `waitForWorkspaceSaveRequest`, records `ServerWorkspaceSaveFailure`, preserves Pro-required failures for the upgrade sheet, and returns saved workspace values to UI callbacks only after the application-layer CRUD path succeeds. RED failed to compile until save request APIs and failure state existed. GREEN focused tests passed 16 Swift Testing tests; the WorkspaceForm source boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings.
- 2026-06-21: Task 46 RED/GREEN completed with review fix. `SyncSettingsView` no longer directly observes `CloudKitManager.shared` or calls `AppSyncCoordinator.shared`; it observes `SyncSettingsStore` in Settings Application and sends sync-toggle/recheck intent through that store. `SyncSettingsStore` owns CloudKit status bridging through `SyncSettingsCloudStatusProviding`, app-sync intent through `SyncSettingsCoordinating`, tracks returned coordinator tasks for sync-toggle and status refresh, and coalesces in-flight CloudKit status refresh requests. Initial RED failed to compile until the store/protocols existed. Review found a status-ordering issue where a void publisher plus post-publish property reads could lag behind real `@Published` updates; review-fix RED reproduced stale `.idle` / `available` state, and GREEN passed after the provider protocol emitted complete `SyncSettingsCloudStatusSnapshot` values with `CloudKitManager` using `CombineLatest4`. Final focused store/boundary tests passed 9 Swift Testing tests; source scan found no direct CloudKit/app-sync singleton references in `SyncSettingsView.swift`; `git diff --check` passed; iOS build-for-testing passed after a sequential rerun because an earlier parallel build hit Xcode's `build.db` lock; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing XCTest deployment warnings.
- 2026-06-21: Task 45 RED/GREEN completed with review fix. `ServerFormSheet` no longer directly calls `KeychainManager.shared` for stored SSH key lists, stored key material, or edit-server credentials; it sends credential read intent through `ServerFormCredentialProvider` in Servers Application. The provider owns the server-form credential read boundary through `ServerFormCredentialLibrary`, decodes stored key data to form-ready values, preserves underlying keychain read errors for explicit stored-key loading, and matches reusable keys by private key plus passphrase outside SwiftUI. UI behavior is preserved for selected stored keys, including refreshing the public key field when stored private key data is absent. Initial RED failed to compile until the provider/protocol/value type existed. Review found automatic matching regressed by surfacing a broken candidate instead of skipping it; review-fix RED failed until candidate-scoped matching existed, and GREEN passed after matching used the loaded picker candidates and skipped per-candidate read/decode failures. Re-review found no Critical or Important issues, and the remaining Minor non-throwing API clarity note was addressed. Final focused provider/boundary tests passed 7 Swift Testing tests; source scan found no direct `KeychainManager.shared` in `ServerFormSheet.swift`; `git diff --check` passed; iOS build-for-testing passed after a sequential rerun because the first parallel build hit Xcode's `build.db` lock; signed macOS build-for-testing failed on missing local Mac Development signing assets, then macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO`. A task-introduced `ServerFormCredentialProvider.shared` main-actor warning was removed by keeping the provider non-main-actor; final macOS warning scan showed only existing unrelated Swift 6 / XCTest deployment warnings.
- 2026-06-21: Task 44 RED/GREEN completed with review fix. Terminal accessory CloudKit sync now has TerminalAccessories application-layer protocol seams, manager-owned startup/foreground/sync-toggle/cloud-resolution tasks, DEBUG-only await hooks, and cancellation/sync-enabled guards that drop CloudKit results which resume after sync is disabled. Initial RED failed to compile until injectable cloud sync / pending drain dependencies and startup await hooks existed; review-fix RED failed because a stale remote custom action was merged after sync was disabled. GREEN `TerminalAccessoryPreferencesManagerTests` passed 5 XCTest tests; source scan found no old untracked startup/observer cloud sync task forms; `git diff --check` passed; iOS build-for-testing passed; signed macOS build-for-testing failed on missing local Mac Development signing assets, then macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO` and existing unrelated Swift 6 / XCTest deployment warnings. Guard warning for added `Task` was reviewed: the tasks are stored and tracked by `TerminalAccessoryPreferencesManager`.
- 2026-06-21: Task 43 RED/GREEN completed with review fix. Store startup product/entitlement refresh and review-mode disable entitlement refresh are now owned by `StoreManager` as stored tasks, canceled in `deinit`, clear only their current task IDs, and expose DEBUG-only await hooks for lifecycle ordering tests. Review found a superseded review-mode refresh could still run entitlement work after cancellation; follow-up RED coverage failed with two refreshes until `startReviewModeRefresh()` checked cancellation before invoking the entitlement action, and re-review found no Critical or Important issues. Verification: initial RED failed because Store refresh operation injection and await hooks did not exist; review-fix RED failed because a canceled superseded refresh still ran entitlement work; GREEN `StoreManagerLifecycleTests` passed 7 Swift Testing tests; Store lifecycle source scan produced no matches for old untracked startup/review refresh task forms; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation and XCTest deployment warnings. Guard warning for added `Task` was reviewed: the tasks are stored and tracked by `StoreManager`.
- 2026-06-21: Task 42 RED/GREEN completed with review fix. Store purchase and restore buttons now send synchronous intent to `StoreManager.requestPurchase(of:)` and `StoreManager.requestRestorePurchases()` instead of starting SwiftUI-owned StoreKit tasks. `StoreManager` owns pending purchase/restore request tasks by request ID, exposes awaitable waits, records request-level failures, and keeps `purchase(_:)` / `restorePurchases()` as the StoreKit behavior boundary. Review found real purchase/restore catch paths still translated `CancellationError` into failed UI state; follow-up RED coverage failed until cancellation-aware Store state helpers existed, and re-review found no Critical or Important issues. Verification: initial RED failed because Store request tracking APIs did not exist; review-fix RED failed because cancellation helper seams did not exist; GREEN focused suite passed 3 XCTest tests plus 5 Swift Testing tests; Store UI boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation and XCTest deployment warnings. Guard warning for added `Task` was reviewed: the tasks are owned and tracked by `StoreManager`, not SwiftUI.
- 2026-06-21: Task 41 RED/GREEN completed before commit. Terminal open intent now flows through `TerminalTabManager.requestTabOpen(...)`, `TerminalTabManager.requestServerTerminalOpen(...)`, and `ConnectionSessionManager.requestConnectionOpen(...)`, so SwiftUI buttons, menus, duplicate-tab, macOS sidebar, and iOS server-list/new-tab flows no longer create their own terminal-open tasks, branch around the application owner for existing tabs, or hide open failures behind `try?`/no-op catches. Managers track pending request IDs, preserve cancellation separately from failures, expose awaitable request waits for tests, and reuse the existing `openTab`/`openConnection` teardown and duplicate-open gates. Review fixes closed two AppLock ordering gaps: existing-tab focus now unlocks before selecting, and `ServerSidebarView` selects the server only from the manager success callback. Verification: RED `TerminalOpenIntentBoundaryTests` failed with 5 issues before the route change; review-fix RED failed until `requestServerTerminalOpen(...)` exposed a manager-owned unlock boundary; second review-fix RED failed until the server sidebar stopped preselecting before unlock; GREEN focused suite passed 14 XCTest tests plus 79 Swift Testing tests; terminal-open UI boundary scan produced no matches; `git diff --check` passed; iOS and macOS build-for-testing passed with existing warnings only. Re-review found no Critical or Important issues.
- 2026-06-21: Post-Task-35 closure audit found the plan was not actually ready for final merge review. Current non-exempt gaps are now tracked as Tasks 36-40: terminal runner close must await the stored runner finish path, terminal reconnect orchestration still lives in SwiftUI, iOS RemoteFiles disconnect drops returned teardown tasks, Core SSH needs tighter disconnect timeout/cancellation diagnostics, and cross-feature save/delete/sync/download/window ownership still needs a scoped sweep.
- 2026-06-21: Task 36 RED/GREEN completed. RED verification showed `closeSessionAndWait(_:)` already waited for a delayed stored runner task, while `closePaneAndWait(_:)` returned before a delayed stored runtime shell task finished. `TerminalConnectionRuntime.close(mode:)` now awaits the stored shell task in every close branch, and regression tests cover both session and pane close ordering. Verification: focused lifecycle/runtime suite passed 57 Swift Testing tests, and `git diff --check` passed.
- 2026-06-21: Task 37 slice 1 RED/GREEN completed. Application-layer APIs now own root auto/manual reconnect decisions, split-pane manual reconnect decisions, watchdog scheduling predicates, iOS selected-session foreground reconnect action, and retrust/mosh install-then-reconnect sequencing. SwiftUI terminal views still own `reconnectInFlight`, rebuild tokens, and the 20-second watchdog sleep bridge, so Task 37 remains open for the full coordinator/timing move. Verification: focused Task 37 suite passed 64 Swift Testing tests, and `git diff --check` passed.
- 2026-06-21: Task 37 slice 2 RED/GREEN completed. `ConnectionSessionManager` and `TerminalTabManager` now own connect watchdog timer tasks and generation cancellation; root and split SwiftUI views no longer store watchdog tokens, sleep for the 20-second timeout, or call timeout handlers directly. Task 37 remains open for moving remaining credential-loading and `reconnectInFlight` retry-state orchestration out of the views. Verification: focused Task 37 suite passed 67 Swift Testing tests, and `git diff --check` passed.
- 2026-06-21: Task 37 final RED/GREEN, API cleanup, and review fixes completed. Root, split, and iOS terminal views no longer own retry in-flight state, call Keychain directly, execute reconnect directly, or derive foreground reconnect from registry state in SwiftUI. Managers now load credentials through application-layer providers, gate duplicate retry intent, revalidate liveness after awaited credential loading, execute foreground/open-active reconnect intent, return wrapper credentials or UI actions to views, and keep reconnect/watchdog/retrust/mosh sequencing in TerminalSessions Application. Boundary scan found no `reconnectInFlight`, direct `KeychainManager.shared.getCredentials`, old watchdog token/sleep, direct `reconnect(session:)`, direct live-runtime lookup, direct known-host reset, or direct reconnect policy calls in the target SwiftUI files. Verification: focused Task 37 suite passed 74 Swift Testing tests, and `git diff --check` passed.
- 2026-06-21: Task 38 RED/GREEN and review fix completed. RED proved a same-server RemoteFiles operation could start while a dropped disconnect task was still closing the previous SFTP lease, and review added coverage for a second disconnect registered after the first wait. `RemoteFileBrowserStore` now tracks pending disconnect tasks and loops until no same-server disconnect remains before later service work; iOS active-connection and current-server disconnect flows now await the returned RemoteFiles disconnect task before terminal session teardown/navigation. Verification: `RemoteFileBrowserStoreTests` passed 6 Swift Testing tests, and `git diff --check` passed.
- 2026-06-21: Task 40A RED/GREEN completed. Server edit save now runs through `ServerManager.updateServer(_:credentials:)`, so credential storage failure prevents metadata mutation instead of letting `ServerFormSheet` update metadata first and write Keychain later. `ServerFormSheet.saveServer()` no longer directly stores/deletes server credentials on edit save; remaining Keychain reads/import helpers are deferred to broader cleanup. Task 40 remains open for sync ownership, voice download ownership, AppKit window ownership, and remaining destructive action tracking. Verification: `ServerManagerBootstrapTests` passed 11 Swift Testing tests, `git diff --check` passed, and `xcodebuild build-for-testing -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- 2026-06-21: Task 40B RED/GREEN completed with review fixes. AppDelegate launch/foreground/remote-notification sync and `SyncSettingsView` recheck/toggle sync now send intent to `AppSyncCoordinator`, which stores/coalesces sync tasks, waits for tracked refresh before remote notification completion, queues a settings-owned reload after any already-running foreground refresh, and cancels stale settings enable work when a later disable intent arrives. `CloudKitManager.handleSyncToggle(_:)` is awaitable and cancellation-aware after account status checks, and subscription setup rechecks cancellation/sync-enabled state before treating existing subscriptions or saves as valid. Task 40 remains open for voice download ownership, AppKit window ownership, and remaining destructive action tracking. Verification: `AppSyncCoordinatorTests` passed 5 Swift Testing tests; `AppSyncCoordinatorTests` + `ServerManagerBootstrapTests` passed 16 Swift Testing tests; `git diff --check` passed; `xcodebuild build-for-testing -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed.
- 2026-06-21: Task 40C RED/GREEN completed. `TranscriptionSettingsView` no longer owns `MLXModelManager` instances or starts download tasks; voice model download, cancel, remove, and clear-storage intent now goes through `VoiceModelDownloadStore`, which owns stable managers and tracks/coalesces download tasks by model kind. Cancel clears the tracked task before forwarding cancellation so immediate retry starts a fresh application-owned operation, and URLSession delegate callbacks now ignore stale canceled tasks before touching active download state. Task 40 remains open for AppKit window ownership and remaining destructive action tracking. Verification: `VoiceModelDownloadStoreTests`, `TranscriptionSettingsStoreTests`, and `MLXModelCatalogTests` passed 8 XCTest tests plus 2 Swift Testing tests.
- 2026-06-21: Task 40D RED/GREEN completed. `AboutView` and `ProUpgradeSheet` no longer own singleton AppKit windows; About presentation lives in `AboutWindowPresenter`, Pro upgrade presentation lives in `ProUpgradeWindowPresenter`, and shared paywall presentation copy lives in Store Application instead of the UI file. UI now sends show/close intent while Application owns stable `NSWindow` lifetimes. Task 40 remains open for remaining destructive action tracking. Verification: `AppKitWindowOwnershipBoundaryTests` passed 1 Swift Testing test; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO`.
- 2026-06-21: Task 40E1 RED/GREEN completed. Server/workspace delete buttons, swipe actions, and workspace switcher deletion now send intent to `ServerManager.requestServerDeletion` or `requestWorkspaceDeletion` instead of launching untracked SwiftUI tasks that swallow destructive-action failures. `ServerManager` tracks pending deletion request tasks, captures `ServerDeletionFailure`, exposes an awaitable request wait for ordering tests, and runs success continuations only after the application-layer delete path succeeds. Task 40E remains open for environment deletion, Settings Keychain/trusted-host destructive flows, RemoteFiles mutation tasks, and TerminalThemes persistence/sync failure handling. Verification: `ServerManagerBootstrapTests` + `ServerDeletionIntentBoundaryTests` passed 13 Swift Testing tests; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation warnings.
- 2026-06-21: Task 40E2 RED/GREEN completed. macOS and iOS environment deletion no longer starts SwiftUI-owned `Task { try? await serverManager.deleteEnvironment(...) }`; UI sends intent to `ServerManager.requestEnvironmentDeletion`, which tracks the request with the same application-layer deletion request owner and runs selection updates only after `deleteEnvironment` succeeds. `ServerDeletionFailure.Operation` now distinguishes environment deletion by workspace and environment IDs for diagnostics. Task 40E remains open for Settings Keychain/trusted-host destructive flows, RemoteFiles mutation tasks, and TerminalThemes persistence/sync failure handling. Verification: `ServerManagerBootstrapTests` + `ServerDeletionIntentBoundaryTests` passed 14 Swift Testing tests; environment-delete `try?` boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation warnings.
- 2026-06-21: Task 40E3a RED/GREEN completed. `TerminalSettingsView` no longer owns trusted-host reset/refresh tasks or calls `KnownHostsStore.shared`; UI sends intent to `TrustedHostsSettingsStore`, which owns tracked request tasks and prevents stale refresh completions from overwriting a later reset count. Task 40E3 remains open for Keychain stored-key import/delete and generated-key save/delete ownership, and Task 40E remains open for RemoteFiles mutation tasks and TerminalThemes persistence/sync failure handling. Verification: `TrustedHostsSettingsStoreTests` + `SettingsLifecycleBoundaryTests` passed 3 Swift Testing tests; trusted-host UI boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation warnings.
- 2026-06-21: Task 40E3b/c RED/GREEN completed. `KeychainSettingsView` no longer calls `KeychainManager.shared`, invokes `SSHKeyGenerator.generate`, or owns SSH key generation tasks directly; UI sends SSH key import/delete/generate intent to `SSHKeySettingsStore`, which owns Keychain persistence through `SSHKeyLibrary`, generator access through `SSHKeyPairGenerating`, and tracked generation request tasks. Task 40E3 is complete, and Task 40E remains open for RemoteFiles mutation tasks and TerminalThemes persistence/sync failure handling. Verification: `SSHKeySettingsStoreTests` + `SettingsLifecycleBoundaryTests` passed 6 Swift Testing tests; SSH key settings UI boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation and XCTest deployment warnings.
- 2026-06-21: Task 40E4a RED/GREEN completed. `RemoteFileBrowserScreen.performOperation` no longer launches UI-owned tasks for browser mutations; it delegates create folder, rename, move, delete, and permission-change mutation lifecycle to `RemoteFileBrowserStore.requestMutation`, which tracks pending mutation request IDs and exposes awaitable request completion. Task 40E4 remains open for preview-save and transfer/drop/file-promise ownership, and Task 40E remains open for TerminalThemes persistence/sync failure handling. Verification: `RemoteFileBrowserStoreTests` + `RemoteFileMutationIntentBoundaryTests` passed 9 Swift Testing tests; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation and XCTest deployment warnings.
- 2026-06-21: Task 40E4b RED/GREEN completed. Edited text preview saves no longer start from `RemoteFileInspectorView` as UI-owned `Task` work, and platform preview containers no longer call `saveTextPreview` directly. UI sends a `RemoteFileTextSaveRequest`; `RemoteFileBrowserStore.requestTextPreviewSave` owns the async save task through the mutation registry and keeps completion awaitable. Task 40E4 remains open for transfer/drop/file-promise ownership, and Task 40E remains open for TerminalThemes persistence/sync failure handling. Verification: `RemoteFilePreviewCoordinatorTests` + `RemoteFileMutationIntentBoundaryTests` passed 4 Swift Testing tests; preview-save UI boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation and XCTest deployment warnings. Code review: no findings; noted failure-path and stale-selection coverage as acceptable follow-up risk, not a 40E4b blocker.
- 2026-06-21: Task 40E4c RED/GREEN completed. Transfer/drop/file-promise lifecycle ownership moved to `RemoteFileBrowserStore.requestTransfer`, with pending request IDs and awaitable transfer request waiting. `RemoteFileBrowserScreen.performTransfer` now owns only notice presentation, local drop URL resolution plus upload planning runs inside the tracked transfer request, remote drops/copies and platform downloads reuse the same request owner, and macOS file-promise export completion delegates download work to the store instead of awaiting in `FilePromiseDelegate`. Task 40E4 is complete, and Task 40E remains open for TerminalThemes persistence/sync failure handling. Verification: `RemoteFileBrowserStoreTests` + `RemoteFileMutationIntentBoundaryTests` passed 12 Swift Testing tests; transfer/drop/file-promise UI boundary scan produced no matches; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation and XCTest deployment warnings.
- 2026-06-21: Task 40E5 RED/GREEN completed with review fixes. `TerminalThemeManager` now owns custom-theme persistence through `TerminalThemeCustomThemeStoring`, owns CloudKit fetch/drain through TerminalThemes application-layer protocols, and tracks startup/theme/preference/foreground CloudKit push tasks with awaitable request IDs. Custom theme create/update/delete and remote merge publish `customThemes` only after local persistence succeeds, the concrete UserDefaults store avoids committing defaults when file sync throws, and Settings custom-theme delete UI now preserves throwing intent and surfaces persistence failures. Task 40E is complete. Verification: `TerminalThemeManagerLifecycleTests`, `TerminalThemeValidationTests`, `TerminalThemeStoragePathsTests`, and `SettingsLifecycleBoundaryTests` passed 9 Swift Testing tests plus 4 XCTest tests; custom-theme boundary scan found no UI-swallowed delete or swallowed `saveThemes` failure; `git diff --check` passed; iOS build-for-testing passed; macOS build-for-testing passed with existing Swift 6 isolation and XCTest deployment warnings.
- 2026-06-21: Task 31 completed, with Task 36 ledger correction. Terminal runtime/client factory ownership is centralized in `TerminalConnectionRuntime`; session and tab managers still hold temporary application-boundary bridge maps and shell registry leases for runtime lookup/registration, but runner finish ordering is protected by awaitable runtime close paths and late/missing shell registrations are rejected before runner follow-up callbacks mutate closed state.
- 2026-06-21: Task 32 RED/GREEN and API cleanup completed. `TerminalConnectionRunner` now depends on `TerminalConnectionSurface` and abstract connection operations instead of `GhosttyTerminalView`; `GhosttyTerminalView` adaptation lives at the surface registry/application boundary, and runner tests cover fake-surface size reads, stream writes, and process-exit notification without constructing a UI surface.
- 2026-06-21: Final audit after Task 32 found repo-wide drift against the Swift test context rule: multiple older `VVTermTests/**/*.swift` files still lack `Test Context` headers. Task 33 is added to close this rule before final ready-for-merge review.
- 2026-06-21: Task 33 RED scan listed legacy `VVTermTests/**/*.swift` files missing `Test Context`; the sweep added file-level headers only, and the GREEN scan produced no output.
- 2026-06-21: Task 33 verification passed: `git diff --check`, GREEN context scan, and `xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO`. Boundary check confirmed Swift test diffs only add comment lines.
- 2026-06-21: Task 33 review completed locally because the current harness only permits new subagents when explicitly requested. Review found and fixed misplaced context headers in three legacy banner files, then re-ran the GREEN context scan, header-format scan, `git diff --check`, and build-for-testing successfully.
- 2026-06-21: Task 34 RED final suite exposed stale TerminalAccessories and RemoteFiles test expectations plus a real PKCS#1 RSA derivation crash. Focused GREEN passed after replacing Security.framework private-key import with pure Swift ASN.1 parsing, making both RSA mpint helpers Data-slice safe, and updating stale expectations; final iOS unit verification passed with 104 XCTest tests and 282 Swift Testing tests in 46 suites.
- 2026-06-21: Task 35 RED full-suite verification exposed a main-actor teardown wait hang in `ConnectionSessionManager`; the waiter now removes completed tracked tasks itself instead of relying only on a separate cleanup task. Focused lifecycle verification passed 55 Swift Testing tests, including the previously hanging disconnect/reopen case.

- 2026-06-20: Plan created from local code audit, four read-only explorer audits, and current Swift/libssh2 references.
- 2026-06-21: Task 14 completed in commit-sized slices. Runtime/live transport truth now comes from `TerminalConnectionRegistry`, `activeServerIds`, `openServerIds`, and `hasLiveRuntime`; `ConnectionState` is explicitly treated as a user-facing display snapshot and is no longer persisted or used for high-risk open/retry/watchdog lifecycle decisions.
- 2026-06-21: Task 14 API/boundary cleanup completed. New APIs are application-layer intent/policy boundaries: `hasLiveRuntime(forSessionId:)`, `hasLiveRuntime(forPaneId:)`, `TerminalAutoReconnectPolicy`, `TerminalManualReconnectPolicy`, `reconnectPane(_:)`, `handlePaneExit(for:)`, `TerminalConnectWatchdogAction`, and manager-owned `handleConnectWatchdogTimeout(...)` methods.
- 2026-06-21: Remaining lifecycle-sensitive UI hits are intentionally deferred to Task 15: `SSHTerminalWrapper` and split-pane terminal wrapper attach/start guards still read `shellId` / `isShellStartInFlight` from UI-adjacent code. They are terminal surface attach guards rather than connected-server or retry policy truth, but they should be classified by the Task 15 audit before further changes.
- 2026-06-21: Task 15 audit classification completed. Terminal session `SSHClient()` construction in `ConnectionSessionManager` and `TerminalTabManager` is application-layer runtime construction and remains allowed; no representable coordinator constructs `SSHClient`.
- 2026-06-21: Task 15 tracked/exempt `Task.detached` hits: `runtime.shellTask` in both terminal managers is stored on runtime state; `scheduleSSHUnregister` returns a task that close paths can store/await; `RemoteFileTransferCoordinator` file-system work awaits `.value`; `ServerStatsCollector.collectTask` is stored and canceled by the collector.
- 2026-06-21: Task 15 non-exempt lifecycle hits requiring tests before implementation: stale shell cleanup in `ConnectionSessionManager.handleStaleShellStartContext`, `ConnectionSessionManager.registerSSHClient`, `TerminalTabManager.handleStaleShellStartContext`, and `TerminalTabManager.registerSSHClient` still uses untracked `Task.detached`; managed tmux kill in `ConnectionSessionManager.killTmuxIfNeeded` and `TerminalTabManager.killTmuxIfNeeded` is still fire-and-forget.
- 2026-06-21: Task 15 non-exempt SwiftUI lifecycle hits requiring tests before implementation: `SSHTerminalWrapper` macOS/iOS coordinator `deinit` and iOS `dismantleUIView` can still initiate business teardown through `trackShellTeardownForClosedSession`; split-pane `TerminalView` coordinator `deinit` and `cancelShell()` still call manager detach through untracked `Task` from UI lifecycle code.
- 2026-06-21: Task 15 deferred cross-feature ownership hits: `SSHSFTPAdapter` and `ServerStatsCollector` still create owned `SSHClient` instances through `RemoteConnectionLease`; they are not SwiftUI-owned, but they remain broader RemoteFiles/Stats lease-boundary cleanup candidates after the terminal lifecycle sweep.
- 2026-06-21: Task 15 shell cleanup slice completed. Rejected, stale, and replaced shell cleanup in `ConnectionSessionManager` and `TerminalTabManager` now enters per-server teardown tracking so immediate reopen waits for cleanup instead of racing a detached disconnect. Remaining non-exempt hits: managed tmux kill fire-and-forget and SwiftUI lifecycle teardown calls.
- 2026-06-21: Task 15 tmux kill slice completed. `killTmuxIfNeeded` in both terminal managers now tracks managed remote tmux kill tasks per server, so immediate open waits for the kill operation instead of racing a fire-and-forget remote command. Remaining non-exempt hits: SwiftUI lifecycle teardown calls in `SSHTerminalWrapper` and split-pane `TerminalView`.
- 2026-06-21: Task 15 SwiftUI surface lifecycle slice completed. `SSHTerminalWrapper` and split-pane `TerminalView` no longer perform business teardown from coordinator `deinit`; `dismantleUIView` / `dismantleNSView` now only detach or pause live surfaces, and closed-session cleanup is routed through manager-owned application-layer intent APIs. Verification: `TerminalSurfaceTeardownTests` passed, then the focused connection lifecycle/auth suite passed 16 XCTest tests plus 46 Swift Testing tests.
- 2026-06-21: Task 15 final verification completed. The documented focused suite passed 16 XCTest tests plus 49 Swift Testing tests, and `xcodebuild build-for-testing -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` succeeded. Remaining architecture work is the previously deferred RemoteFiles/Stats lease-boundary cleanup, not an unresolved TerminalSessions lifecycle hit.
- 2026-06-21: RemoteFiles/Stats lease-boundary audit completed with three read-only fan-out explorers. Findings: `RemoteConnectionLease.close()` is awaitable and idempotent per lease, but RemoteFiles and Stats still expose raw `SSHClient` at feature boundaries; RemoteFiles needs a per-lease exclusive operation gate before borrowed terminal clients can safely run SFTP; Stats stop/restart must await or track close work instead of dropping returned tasks from SwiftUI.
- 2026-06-21: Task 16 RED/GREEN completed. Added lease-ordering tests for concurrent close, non-overlapping exclusive operations, and close waiting for a protected operation; then implemented `RemoteConnectionLease.withExclusiveClient` with private actor-owned per-lease serialization. API cleanup found no new UI/application raw-client exposure; mutable gate state remains private to `RemoteConnectionLeaseState`. Verification: `RemoteConnectionLeaseTests` passed 6 Swift Testing tests and `git diff --check` passed.
- 2026-06-21: Task 17 RED/GREEN completed. Added `SSHSFTPAdapterTests` covering borrowed disconnect safety, owned disconnect waiting for in-flight SFTP work, per-server lease serialization, and borrowed registration retry after failure. RED failed on missing `SFTPRemoteFileClient` and adapter seams; GREEN passed 4 `SSHSFTPAdapterTests` after introducing the RemoteFiles SFTP capability protocol and routing adapter work through `RemoteConnectionLease.withExclusiveClient`.
- 2026-06-21: Task 17 API/boundary cleanup completed. RemoteFiles application code still depends on `SSHSFTPAdapter` rather than raw `SSHClient`; raw `SSHClient` use is confined to RemoteFiles infrastructure default provider/factory and feature-boundary conformance. `SSHSFTPAdapterTests` and `RemoteFileBrowserStoreTests` include Test Context headers. Verification: focused RemoteFiles suite passed 8 Swift Testing tests and `git diff --check` passed.
- 2026-06-21: Task 18 RED/GREEN completed. Added `ServerStatsCollectorLifecycleTests` for awaited owned stop, restart waiting for pending stop, borrowed shared-client stop safety, failed collection close-before-retry ordering, and cancellation-as-lifecycle behavior. RED failed on missing `StatsConnection`, injectable collector initializer, and `stopCollectingAndWait`; GREEN passed 5 Swift Testing tests after adding pending stop tracking and injectable connection/collection seams.
- 2026-06-21: Task 18 API/boundary cleanup completed. `stopCollecting()` remains a synchronous UI intent helper but stores the pending stop task; `stopCollectingAndWait()` is the explicit awaitable API; `startCollecting(...)` waits for pending stop before replacing connection state. `ServerStatsView` awaits visibility-driven stop and only sends stored stop intent from `onDisappear`. Verification: focused Stats lifecycle suite passed 5 Swift Testing tests; `git diff --check` passed; code review found no code issues after lifecycle fixes.
- 2026-06-21: Task 19 RED/GREEN completed. Added `collectorUsesCommandExecutorWithoutRawSSHClientOwnership`; RED failed because a non-`SSHClient` lease executor was ignored and Stats never populated executor-backed system info. GREEN passed after platform collectors moved to `any RemoteCommandExecuting`, Stats platform detection moved to `RemoteCommandExecuting.remoteEnvironment().platform`, and Stats UI switched from `sharedClientProvider` to borrowed lease providers.
- 2026-06-21: Task 19 API/boundary cleanup completed. Stats Domain stayed pure, platform collectors remain in Infrastructure, `ServerStatsView` only sends visibility/retry intent with a borrowed lease provider and no longer keys lifecycle on `ObjectIdentifier(SSHClient)`, and all touched Stats test files include Test Context headers. Verification: focused Stats suite passed 10 XCTest tests plus 6 Swift Testing tests; `git diff --check` passed; code review found no blocking issues and the stale shared-SSH comment was aligned to lease vocabulary before commit.
- 2026-06-21: Task 20 audit classification completed. Non-exempt hits were RemoteFiles/App raw borrowed-client provider wiring and Terminal Rich Paste UI-side raw-client-to-lease wrapping. Exempt hits are Stats and RemoteFiles owned `SSHClient()` infrastructure fallback construction, TerminalSessions application-layer runtime construction/private raw-client helpers, `RemoteConnectionLease.withExclusiveClient`, Stats `disconnectWhenDone: false` inside the lease-gated connection bridge, and UI event `Task {}` wrappers that send store/collector intent rather than owning teardown.
- 2026-06-21: Task 20 RED/GREEN completed for RemoteFiles lease boundary. `SSHSFTPAdapterTests.borrowedLeaseProviderIsTheRemoteFilesConnectionBoundary` first failed to compile because `SSHSFTPAdapter` still accepted `borrowedClientProvider`; GREEN passed after `SSHSFTPAdapter`, app composition, and terminal rich-paste runtime paths consumed `RemoteConnectionLease` providers. `sharedStatsClient` is now private to terminal managers and tests assert `sharedStatsLease(...).client` identity instead.
- 2026-06-21: Task 20 API/boundary cleanup completed after code review. Reviewer found iOS UI still pulled raw `SSHClient`/`shellId` for resize and raw terminal helpers were still module-internal; fixed by routing iOS refresh resize through `ConnectionSessionManager.resizeSession(...)`, reusing that manager intent in redraw-after-close, and making raw terminal client helpers private. Verification: expanded focused suite passed 24 XCTest tests plus 67 Swift Testing tests; `git diff --check` passed; `xcodebuild build-for-testing -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO` passed; re-review found no remaining issues.
- 2026-06-21: Post-Task-20 plan audit reconciled historical checklist drift. Tasks 1-13 are now marked complete because their current code/test artifacts exist in-tree: generation-guard shell registration, awaitable close APIs, application-layer runner/runtime/registry, terminal surface registry, cancellation-aware auth gate, libssh2 session driver and abort tests, `RemoteCommandExecuting`, known-host verification service, and `RemoteConnectionLease`.
- 2026-06-21: Post-Task-20 remaining gap classification selected Core SSH/FFI for the next wave. RemoteFiles/Stats raw lease boundaries are complete from Task 20; broad UI `Task {}` hits are lower priority unless they own lifecycle-critical teardown. The highest-risk remaining area is concentrated in `SSHClient.swift` and `LibSSH2SessionDriver.swift`: direct auth/channel/SFTP libssh2 calls, keyboard-interactive callback lifetime, raw error preservation, and legacy known-host storage compatibility.
- 2026-06-21: Task 21 audit classification completed. Exempt low-level boundaries: `LibSSH2Runtime` process-global init lock; `LibSSH2SessionDriver` socket/address/session pointer operations with local pointer lifetimes; `SSHClientAbortState` and `AtomicSocket` locks for emergency fd abort; `KeyboardInteractiveContext` lock and callback context owned by `SSHSession`; test fake locks in `LibSSH2SessionLifecycleTests`. Non-exempt Task 21 slice: auth method discovery, auth status, password/keyboard-interactive/public-key auth, auth last-error mapping, and host-key fingerprint reads still happen directly in `SSHClient.swift` and must move behind `LibSSH2SessionDriving` for the RED auth raw-error test. Deferred follow-up candidates: channel, SCP, SFTP, and keepalive libssh2 calls still live in `SSHClient.swift` and should be split only after the auth boundary is stable.
- 2026-06-21: Task 21 known-host audit found `SSHClient` already uses `KnownHostVerificationService`, while `KnownHostsManager.shared` remains in terminal trust-reset UI, settings count/clear UI, `ServerManager.deleteServer`, and compatibility tests. Step 5 must either move these app/UI call sites to actor-backed `KnownHostsStore` APIs or document `KnownHostsManager` as a narrow synchronous compatibility facade with tests protecting the chosen contract.
- 2026-06-21: Task 21 RED completed. Added `testPublicKeyAuthFailurePreservesRawLibSSH2Error`; the first focused run failed to compile because `LibSSH2RawError.Operation.authentication` and auth operations were not yet modeled by `LibSSH2SessionDriving`.
- 2026-06-21: Task 21 auth/host-key boundary GREEN completed. `LibSSH2SessionDriving` now owns auth method discovery, authenticated-state checks, password/keyboard-interactive/public-key auth calls, auth last-error capture, and host-key fingerprint reads; `SSHClient` preserves non-credential libssh2 auth failures as `SSHError.libssh2` with raw operation/code/message before translation. Verification: `LibSSH2SessionLifecycleTests` and `SSHErrorRetryableTests` passed.
- 2026-06-21: Task 21 known-host ownership completed. App/UI call sites in terminal trust reset, settings count/clear, and server deletion now call actor-backed `KnownHostsStore` APIs; `KnownHostsManager.shared` remains only in the synchronous compatibility facade and `KnownHostsManagerTests`.
- 2026-06-21: Task 21 code-review fixes completed. Auth method discovery failures now preserve raw `.authentication` libssh2 errors before later auth attempts can overwrite diagnostics; normal credential rejection remains `SSHError.authenticationFailed`; auth lifecycle tests clean up their shared known-host entry before and after each test; `ServerManager` computes known-host removal candidates from the post-delete server state before awaiting actor-backed cleanup.
- 2026-06-21: Task 21 final focused verification completed. `LibSSH2SessionLifecycleTests`, `SSHAuthenticationGateCancellationTests`, `SSHErrorRetryableTests`, `KnownHostsManagerTests`, and `ServerManagerBootstrapTests` passed: 7 XCTest tests plus 17 Swift Testing tests. `git diff --check` passed. Boundary scan confirmed direct auth/host-key/last-error libssh2 calls are confined to `LibSSH2SessionDriver.swift`, and `KnownHostsManager.shared` is confined to the compatibility facade and its tests.
- 2026-06-21: Task 21 re-review completed with no blocking findings. Residual risk accepted for this slice: auth lifecycle tests still use `KnownHostsStore.shared` with per-test cleanup rather than injecting an isolated host-key store.
- 2026-06-21: Post-Task-21 Core SSH FFI wave planning completed. Remaining direct libssh2 calls are split into four reviewable tasks: shell channel setup/teardown (Task 22), channel I/O plus exec/upload/resize/SCP open (Task 23), SFTP session and handle operations including seek (Task 24), and keepalive plus final FFI audit (Task 25). This keeps `SSHSession` as the channel/SFTP state owner while moving unsafe C calls into `LibSSH2SessionDriver`.
- 2026-06-21: Task 22 RED completed. Added `testShellPtyFailureClosesAndFreesOpenedChannel`; the first focused run failed to compile because the fake/driver did not yet expose `channelOpenResult`, `ptyResult`, `channelEvents()`, or channel lifecycle event cases.
- 2026-06-21: Task 22 GREEN completed. `LibSSH2SessionDriving` now owns shell channel open, environment setup, PTY request, shell/exec startup for `startShell`, and channel close/free teardown used by shell and exec cleanup paths. `SSHSession` remains the owner of shell ids, `ShellChannelState`, `ExecRequest`, continuations, and cleanup ordering. Verification: `LibSSH2SessionLifecycleTests` and `TerminalSurfaceTeardownTests` passed.
- 2026-06-21: Task 22 boundary scan completed. Task 22 direct C calls are confined to `LibSSH2SessionDriver.swift` lines 193 and 302-363. Remaining `SSHClient.swift` direct channel hits are deferred to Task 23: exec request open/startup at lines 1992 and 2014; SCP/exec upload close/free/open/startup at lines 2205-2304; upload finish close/free at lines 2345 and 2370.
- 2026-06-21: Task 22 final verification completed. `LibSSH2SessionLifecycleTests` passed 6 XCTest tests; `ConnectionLifecycleIntegrationTests` and `TerminalSurfaceTeardownTests` passed 49 Swift Testing tests; `git diff --check` passed. Review found no blocking issues. Accepted residual risk: close/free diagnostics currently log return codes only; Task 23/25 may tighten teardown raw-error diagnostics.
- 2026-06-21: Task 23 RED completed. Added fake-driver lifecycle tests for shell write retry after `LIBSSH2_ERROR_EAGAIN` and exec startup retry/read/EOF/close ordering; the first focused run failed to compile because `LibSSH2SessionDriving` and the fake driver did not yet expose channel write/read/EOF scripts and call capture.
- 2026-06-21: Task 23 channel I/O boundary GREEN completed. `LibSSH2SessionDriving` now owns channel read/write/EOF, upload EOF/wait/exit, resize, extended-data handling, SCP open, and session block-direction calls. `SSHSession` still owns shell state, exec requests, upload retry policy, cancellation checks, and continuation completion. `execute(_:)` now starts the I/O loop after registering the exec request so lifecycle ordering does not depend on task scheduling.
- 2026-06-21: Task 23 API/boundary cleanup completed. New driver API names match the Task 23 boundary (`readChannel`, `writeChannel`, `isChannelEOF`, `openSCPChannel`, `sessionBlockDirections`), unsafe buffer/path pointer conversion is confined to `LibSSH2SessionDriver`, and raw channel pointers remain stored only in `SSHSession` state objects. Boundary scan shows Task 23 calls are confined to `LibSSH2SessionDriver.swift`; remaining direct `SSHClient.swift` `libssh2_` hits are SFTP session/handle operations for Task 24 and keepalive for Task 25.
- 2026-06-21: Task 23 review fix completed. Review found an exec-upload non-zero-exit double close/free risk after `finishUploadChannel` consumed the channel; added `testExecUploadNonZeroExitDoesNotCloseFreedChannelTwice` and clear the outer upload channel optional after successful `finishUploadChannel` ownership transfer. Re-review confirmed the Critical is resolved with no new Critical or Important findings. Final verification: `LibSSH2SessionLifecycleTests` passed 9 XCTest tests; `RemoteTerminalBootstrapTests` and `TerminalSurfaceTeardownTests` passed 13 Swift Testing tests; `git diff --check` passed.
- 2026-06-21: Task 24 RED completed. Added `testSFTPDirectoryReadFailureClosesHandleExactlyOnce`; the first focused run failed to compile because `LibSSH2SessionDriving` and the fake driver did not yet expose SFTP init/open/readdir/close/last-error operations or SFTP event capture.
- 2026-06-21: Task 24 SFTP boundary GREEN completed. `LibSSH2SessionDriving` now owns SFTP init/shutdown, open/close handle, directory read, seek, read/write, stat, symlink, statvfs, mkdir, rename, unlink, rmdir, and last-error calls. `SSHSession` remains the owner of cached `sftpSession`, remote-file async ordering, cancellation checks, and RemoteFiles error mapping. Verification: `LibSSH2SessionLifecycleTests` passed 10 XCTest tests; `SSHSFTPAdapterTests` and `RemoteFileBrowserStoreTests` passed 9 Swift Testing tests; `git diff --check` passed.
- 2026-06-21: Task 24 API/boundary cleanup completed before review. New SFTP driver APIs are low-level boundary operations; `LibSSH2SessionDriver` does not store SFTP pointers; path and buffer unsafe pointer lifetimes are confined to non-escaping driver methods. Boundary scan shows SFTP C calls are confined to `LibSSH2SessionDriver.swift`; the only remaining direct `SSHClient.swift` `libssh2_` hit is keepalive for Task 25. RemoteFiles still enters through `SSHSFTPAdapter`/leases rather than raw UI-owned clients.
- 2026-06-21: Task 24 review completed. Review found no Critical, Important, or Minor issues and confirmed the SFTP ownership boundary, injected-driver error mapping, non-escaping pointer lifetime, and RemoteFiles lease/adapter entry point.
- 2026-06-21: Task 25 RED completed. Added `testKeepAliveUsesDriverBoundary`; the first focused run failed to compile because `RecordingLibSSH2SessionDriver` did not yet expose keepalive invocation tracking, proving keepalive still lacked an injectable driver boundary.
- 2026-06-21: Task 25 GREEN completed. `LibSSH2SessionDriving.sendKeepAlive(session:)` now owns `libssh2_keepalive_send`; `SSHSession.sendKeepAlive()` only checks that a session exists and delegates to the driver. Verification: focused keepalive test passed.
- 2026-06-21: Task 25 final Core SSH FFI scan completed. Direct `libssh2_` calls are confined to `LibSSH2SessionDriver.swift`; `SSHClient.swift` has no remaining direct `libssh2_` function calls. Remaining allowed low-level hits are: `LibSSH2Runtime` process-global init `NSLock`; `LibSSH2SessionDriver` socket/address, auth, channel, SFTP, keepalive, and last-error pointer lifetimes; `KnownHostsManager` synchronous compatibility-facade lock; `SSHClientAbortState` and `AtomicSocket` emergency socket-abort locks; keyboard-interactive callback context `UnsafePointer` / `UnsafeMutablePointer` / `nonisolated(unsafe)` boundaries owned by `SSHSession`; `SSHSession.downloadFile` local Swift buffer-to-`Data` copy after driver SFTP reads; and `fdSet` local `fd_set` bit mutation for C `select` compatibility.
- 2026-06-21: Task 25 final verification completed. `rg -n "libssh2_|withUnsafe|UnsafeMutable|UnsafePointer|NSLock|nonisolated\\(unsafe\\)" VVTerm/Core/SSH -g '*.swift'` produced only the classified Core SSH low-level boundaries; `git diff --check` passed; the documented focused suite passed 11 XCTest tests plus 15 Swift Testing tests.
- 2026-06-21: Task 25 review completed. Reviewer found no code-level keepalive issue; the only Important finding was the missing classification for the two `SSHClient.swift` `withUnsafe` hits, which is now documented above.
- 2026-06-21: Post-Task-25 plan consistency audit reconciled stale commit checkboxes for Task 22 and Task 24 against existing commits `cd210e1` and `3590af0`; no code changed in this reconciliation.
- 2026-06-21: Post-Task-25 whole-plan fan-out audit completed. Remaining non-Core lifecycle gaps are split into executable Tasks 26 through 32: test-context tightening, remote lease close semantics, server/workspace delete teardown, app termination and LRU eviction cleanup, RemoteFiles/Stats lease provider boundaries, centralized terminal runtime ownership, and TerminalConnectionRunner surface protocol decoupling.
- 2026-06-21: Task 26 test-context tightening completed before review. `ConnectionSessionManagerOpenTests.testDisconnectServerAndWaitClearsSSHRegistrationBeforeReturning` and `ServerManagerBootstrapTests.knownHostRemovalCandidatesUsePostDeleteServerState` now include explicit Given/When/Then comments and assertion messages without changing production behavior. Verification: focused Task 26 suite passed 1 XCTest plus 8 Swift Testing tests; plan closure scans confirmed Task 26 Step 5 remains the first active step before commit, stub-language scan has no output, direct lowercase `libssh2_` calls remain confined to `LibSSH2SessionDriver.swift`; `git diff --check` passed.
- 2026-06-21: Task 26 review completed. Reviewer found no Critical or Important issues; the Minor stale Step 3 expected-result wording was updated before commit.
- 2026-06-21: Task 27 RED completed. Added `RemoteConnectionLeaseTests.closeRejectsQueuedOperationsAfterCloseBegins` for the close-after-queue lifecycle ordering rule. The first method-level `-only-testing` selector matched 0 Swift Testing tests, so the effective RED command ran `RemoteConnectionLeaseTests` and failed because the queued operation returned normally and its body ran after close began.
- 2026-06-21: Task 27 GREEN and API cleanup completed before review. `RemoteConnectionLeaseState` now owns throwing operation waiters, cancels queued waiters when close begins, allows the active operation to finish, resumes close waiters, and keeps the public lease boundary to `close()` plus `withExclusiveClient(_:)`. Verification: `RemoteConnectionLeaseTests` passed 7 Swift Testing tests.
- 2026-06-21: Task 27 review completed. Subagent review was not spawned because the current tool contract permits spawning only when the user explicitly requests subagents; local read-only review found no Critical or Important issues against the Swift lifecycle checklist.
- 2026-06-21: Task 28 RED completed. Added deletion ordering tests for server and workspace deletion. The first focused run failed to compile because `ServerManager.makeForTesting` and an injected awaitable deletion teardown boundary did not exist.
- 2026-06-21: Task 28 GREEN and API cleanup completed before review. `ServerManager` now has a narrow `ServerDeletionTeardown` boundary and credential deletion closure; production deletion awaits `ConnectionSessionManager.disconnectServerAndWait(_:)` and `TerminalTabManager.disconnectServerAndWait(_:)` before keychain deletion and metadata removal. Test managers skip local persistence and pending sync mutation recording. Verification: `ServerManagerBootstrapTests` plus `ConnectionLifecycleIntegrationTests` passed 56 Swift Testing tests; `git diff --check` passed.
- 2026-06-21: Task 28 review completed. Subagent review was not spawned because the current tool contract permits spawning only when the user explicitly requests subagents; local read-only review found and fixed stale test-context wording, then found no Critical or Important issues.
## Self-Review

- Spec coverage: This plan covers stable owners, UI intent boundaries, explicit lifecycle state, awaitable teardown, C/FFI boundaries, typed errors, cancellation, tests, logging, and commit granularity.
- Plan hygiene scan: This file avoids unresolved stub language and vague implementation instructions.
- Type consistency: `TerminalEntityID`, `TerminalEntityConnectionState`, `TerminalConnectionRuntime`, `TerminalConnectionRegistry`, `TerminalSurfaceRegistry`, `RemoteCommandExecuting`, and `RemoteConnectionLease` are defined before later tasks consume them.
- Scope check: The plan is large but phased. Tasks 1 through 25 completed the initial terminal lifecycle, RemoteFiles/Stats lease, known-host, and Core SSH FFI waves; Tasks 26 through 32 now cover the remaining non-Core lifecycle and boundary gaps found by the post-Task-25 audit.
