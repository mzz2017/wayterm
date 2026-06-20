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

- [ ] **Step 1: Write failing tests for closed entity registration**

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

- [ ] **Step 2: Run red test**

Run:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalConnectionRegistryTests ENABLE_DEBUG_DYLIB=NO
```

Expected: fail to compile because `generation`, `closeEntity`, and `rejectedShellToClose` do not exist.

- [ ] **Step 3: Implement generation guard**

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

- [ ] **Step 4: Thread generation through managers**

Add generation arguments to `ConnectionSessionManager.registerSSHClient` and `TerminalTabManager.registerSSHClient`. Store generation returned from `tryBeginShellStart` in the caller until shell registration. In this task, keep existing `SSHConnectionRunner` placement unchanged.

- [ ] **Step 5: Run green test**

Run the same focused command. Expected: `TerminalConnectionRegistryTests` passes.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing tests**

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

- [ ] **Step 2: Run red tests**

Run:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ConnectionSessionManagerOpenTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
```

Expected: fail to compile because `closeSessionAndWait` and `closePaneAndWait` do not exist.

- [ ] **Step 3: Implement awaitable close APIs**

Keep existing synchronous `closeSession` as a UI intent wrapper:

```swift
func closeSession(_ session: ConnectionSession, notingSessionEnd: Bool = true) {
    Task { @MainActor in
        await closeSessionAndWait(session, notingSessionEnd: notingSessionEnd)
    }
}
```

Move current close body into `closeSessionAndWait` and await unregister plus shell teardown before returning. Mirror this pattern in `TerminalTabManager`.

- [ ] **Step 4: Replace UI close call sites that can await**

For UI button handlers that are sync, call the wrapper. For async flows like disconnect, call `await closeSessionAndWait` or `await disconnectServerAndWait`.

- [ ] **Step 5: Run green tests**

Run the focused command from Step 2. Expected: tests pass.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing tests**

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

- [ ] **Step 2: Run red test**

Run:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/TerminalConnectionRunnerTests ENABLE_DEBUG_DYLIB=NO
```

Expected: fail to compile because the runner file and testing probe do not exist.

- [ ] **Step 3: Move runner unchanged**

Move `SSHConnectionRunner` from `SSHTerminalWrapper.swift` to `TerminalConnectionRunner.swift`. Rename it to `TerminalConnectionRunner`. Keep behavior identical except for names.

- [ ] **Step 4: Update UI imports/usages**

Replace `SSHConnectionRunner.run` with `TerminalConnectionRunner.run` in tab and pane code.

- [ ] **Step 5: Run green tests and compile**

Run the focused runner test. Then run:

```bash
xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing tests**

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

- [ ] **Step 2: Run red test**

Expected: compile failure because the new types do not exist.

- [ ] **Step 3: Add new domain types**

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

- [ ] **Step 4: Keep compatibility**

Do not remove `ConnectionState` in this task. Add bridging only. Existing UI behavior must remain unchanged.

- [ ] **Step 5: Run tests**

Run `TerminalEntityStateTests`, `ConnectionSessionDomainTests`, and `TerminalSplitNodeTests`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write fake SSH protocol and tests**

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

- [ ] **Step 2: Run red test**

Expected: compile failure because runtime and testing configuration do not exist.

- [ ] **Step 3: Implement runtime with injected client**

The runtime owns a single client instance and tracks `connectTask`, `shellId`, and `state`. `close(mode:)` cancels connect, closes shell if present, disconnects when requested, and only returns after cleanup.

- [ ] **Step 4: Implement registry**

`TerminalConnectionRegistry` stores `[TerminalEntityID: TerminalConnectionRuntime]`, maps server IDs to entity IDs, and exposes `waitForServerTeardown(_:)`.

- [ ] **Step 5: Run focused tests**

Run `TerminalConnectionRuntimeTests` and `TerminalConnectionRegistryTests`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing test**

Add a test that no `SSHClient` is created by coordinator by injecting a runtime factory into `ConnectionSessionManager` and asserting `attachSurface` starts the runtime.

- [ ] **Step 2: Run red test**

Expected: compile failure for missing attach/send/resize API.

- [ ] **Step 3: Change `SSHTerminalWrapper.Coordinator`**

Remove `let sshClient: SSHClient`, `var shellTask`, and `var shellId` from both macOS and iOS coordinators. `sendToSSH`, resize callbacks, and onReady call manager APIs only.

- [ ] **Step 4: Move rich paste client resolution**

`TerminalRichPasteSupport` resolves a `RemoteConnectionLease` or command executor from the manager, not the coordinator's client.

- [ ] **Step 5: Run tests and compile**

Run `ConnectionSessionManagerOpenTests`, `TerminalConnectionRuntimeTests`, and `build-for-testing`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing tests**

Add tests that closing a pane waits for runtime close and that late pane shell registration is rejected after close.

- [ ] **Step 2: Run red tests**

Expected: compile failure or failing assertions because pane close is not awaitable yet.

- [ ] **Step 3: Remove pane coordinator SSH ownership**

Remove `SSHClient`, `shellTask`, and `shellId` from `SSHTerminalPaneWrapper.Coordinator`. Replace `Task.detached` close paths with `await TerminalTabManager.shared.closePaneAndWait(paneId)`.

- [ ] **Step 4: Use same runtime APIs as tabs**

Panes and tabs use `TerminalEntityID` to address runtime. Keep pane-specific layout state in `TerminalTabManager`.

- [ ] **Step 5: Run focused tests**

Run `ConnectionLifecycleIntegrationTests` and `TerminalConnectionRuntimeTests`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing surface tests**

Add tests proving surface detach does not close SSH runtime by itself and repeated cleanup is idempotent.

- [ ] **Step 2: Run red test**

Expected: fail because `TerminalSurfaceRegistry` does not exist.

- [ ] **Step 3: Move terminal view storage**

Move `terminalViews`, access order, browse/find state callbacks, and cleanup into `TerminalSurfaceRegistry`. Managers keep state and intent methods only.

- [ ] **Step 4: Keep SwiftUI lifecycle surface-only**

`dismantleUIView`, `dismantleNSView`, and coordinator `deinit` can detach or pause surfaces, but they must not close SSH. Closing SSH happens through explicit app-layer close intent.

- [ ] **Step 5: Run tests**

Run `TerminalSurfaceTeardownTests`, `ConnectionSessionManagerOpenTests`, and `ConnectionLifecycleIntegrationTests`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing cancellation tests**

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

- [ ] **Step 2: Run red tests**

Expected: failing assertion because canceled waiter can remain queued.

- [ ] **Step 3: Implement cancellable waiter IDs**

Store waiters by UUID per key. Use `withTaskCancellationHandler` to remove a canceled waiter. Resume only live waiters.

- [ ] **Step 4: Preserve existing behavior**

Run existing overlap tests to prove same-key serialization and different-key parallelism remain.

- [ ] **Step 5: Commit**

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

- [ ] **Step 1: Write failing fd cleanup test**

```swift
func testSessionInitFailureClosesSocketExactlyOnce() async {
    let fake = RecordingLibSSH2SessionDriver(sessionInitResult: .failure(-1))
    let session = SSHSession(config: .testing, driver: fake)

    await XCTAssertThrowsErrorAsync(try await session.connect())

    let closeCount = await fake.closeCount(for: .configuredSocket)
    XCTAssertEqual(closeCount, 1)
}
```

- [ ] **Step 2: Run red test**

Expected: compile failure because driver injection does not exist.

- [ ] **Step 3: Introduce driver without broad behavior change**

Move C calls behind driver methods. Preserve current behavior first. Then fix double-close by ensuring fd ownership transfers to exactly one cleanup path.

- [ ] **Step 4: Add raw error mapping tests**

Inject handshake/auth/channel/SFTP raw codes and assert internal errors preserve operation, raw code, and last message.

- [ ] **Step 5: Run focused tests**

Run `LibSSH2SessionLifecycleTests` and `SSHErrorRetryableTests`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing timeout abort test**

Test that a fake blocking handshake receives abort when timeout fires.

- [ ] **Step 2: Run red test**

Expected: abort count is zero.

- [ ] **Step 3: Add timeout abort hook**

Change timeout wrapper so timeout calls `pendingSession.abort()` or driver socket abort before throwing `.timeout`.

- [ ] **Step 4: Remove unsafe shared flag where possible**

Replace `_isAborted` and `_sessionForAbort` with a small synchronized abort state object. Keep nonisolated `abort()` only as a narrow fd-close path.

- [ ] **Step 5: Run tests**

Run `LibSSH2SessionLifecycleTests` and `build-for-testing`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing tests**

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

- [ ] **Step 2: Run red tests**

Expected: cancellation is swallowed or new host auto-save behavior fails the test.

- [ ] **Step 3: Introduce command executor**

Move tmux/mosh helper dependencies from raw `SSHClient` to `RemoteCommandExecuting` while keeping call sites bridged through `SSHClient`.

- [ ] **Step 4: Introduce known-host service boundary**

Low-level `SSHSession` obtains a verification result and returns a typed error or requires policy callback before saving.

- [ ] **Step 5: Run tests**

Run tmux, mosh, known-host, and SSH retryability tests.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write failing lease tests**

Test borrowed leases do not disconnect the underlying client on close, while owned leases do.

- [ ] **Step 2: Run red tests**

Expected: compile failure because lease type does not exist.

- [ ] **Step 3: Implement lease**

Lease owns close semantics. RemoteFiles and Stats no longer decide raw client disconnect with untracked `Task.detached`.

- [ ] **Step 4: Update feature adapters**

`SSHSFTPAdapter.disconnect(serverId:)` becomes async or returns a tracked task. `ServerStatsCollector.stopCollecting()` awaits or stores owned lease close.

- [ ] **Step 5: Run tests**

Run RemoteFiles, Stats, and lifecycle tests listed above.

- [ ] **Step 6: Commit**

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

- [ ] **Step 5: Commit**

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

- [ ] **Step 1: Run audit commands**

```bash
rg -n "sharedStatsClient|activeSSHClient|getSSHClient|SSHClient\\(|ObjectIdentifier\\(.*SSHClient|stopCollecting\\(\\)" VVTerm/Features/RemoteFiles VVTerm/Features/Stats VVTerm/Features/TerminalSessions VVTerm/App -g '*.swift'
rg -n "RemoteConnectionLease\\(|withExclusiveClient|disconnectWhenDone: false" VVTerm/Features/RemoteFiles VVTerm/Features/Stats VVTerm/Core/SSH -g '*.swift'
rg -n "Task\\.detached|Task \\{" VVTerm/Features/RemoteFiles VVTerm/Features/Stats -g '*.swift'
```

- [ ] **Step 2: Classify every hit**

Write classifications into the Progress Ledger. Every remaining raw-client hit must be private infrastructure construction, a test fake, or a temporary item assigned to the next plan wave.

- [ ] **Step 3: Add regression tests for non-exempt hits**

Use the smallest focused tests in `SSHSFTPAdapterTests`, `ServerStatsCollectorLifecycleTests`, or `ConnectionLifecycleIntegrationTests`.

- [ ] **Step 4: Run final focused suite**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteConnectionLeaseTests -only-testing:VVTermTests/SSHSFTPAdapterTests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/ServerStatsCollectorLifecycleTests -only-testing:VVTermTests/StatsParsingUtilsTests -only-testing:VVTermTests/ServerStatsDomainTests -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests ENABLE_DEBUG_DYLIB=NO
```

Then run:

```bash
xcodebuild build-for-testing -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests ENABLE_DEBUG_DYLIB=NO
```

- [ ] **Step 5: Commit**

```bash
git add docs/refactor-swift-best-practice.md VVTerm VVTermTests
git commit -m "refactor: complete remote lease boundary cleanup"
```

## Progress Ledger

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
- Next task: Task 20 RemoteFiles/Stats Lease Boundary Final Sweep.

## Self-Review

- Spec coverage: This plan covers stable owners, UI intent boundaries, explicit lifecycle state, awaitable teardown, C/FFI boundaries, typed errors, cancellation, tests, logging, and commit granularity.
- Placeholder scan: This file avoids unresolved placeholder language and vague implementation instructions.
- Type consistency: `TerminalEntityID`, `TerminalEntityConnectionState`, `TerminalConnectionRuntime`, `TerminalConnectionRegistry`, `TerminalSurfaceRegistry`, `RemoteCommandExecuting`, and `RemoteConnectionLease` are defined before later tasks consume them.
- Scope check: The plan is large but phased. Task 1 through Task 8 address the current SSH tab/pane lifecycle bug class before broader Core SSH and cross-feature cleanup.
