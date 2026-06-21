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

## Progress Ledger

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
- Next task: Task 29.

## Self-Review

- Spec coverage: This plan covers stable owners, UI intent boundaries, explicit lifecycle state, awaitable teardown, C/FFI boundaries, typed errors, cancellation, tests, logging, and commit granularity.
- Plan hygiene scan: This file avoids unresolved stub language and vague implementation instructions.
- Type consistency: `TerminalEntityID`, `TerminalEntityConnectionState`, `TerminalConnectionRuntime`, `TerminalConnectionRegistry`, `TerminalSurfaceRegistry`, `RemoteCommandExecuting`, and `RemoteConnectionLease` are defined before later tasks consume them.
- Scope check: The plan is large but phased. Tasks 1 through 25 completed the initial terminal lifecycle, RemoteFiles/Stats lease, known-host, and Core SSH FFI waves; Tasks 26 through 32 now cover the remaining non-Core lifecycle and boundary gaps found by the post-Task-25 audit.
