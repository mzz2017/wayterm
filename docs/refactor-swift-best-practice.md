# Swift Best Practice Refactor Index

This is the active, slim index for the VVTerm Swift lifecycle refactor.

The full historical implementation plan is archived at
`docs/refactor-swift-best-practice-1.md`. Do not read the archive wholesale
during normal work. Use this file first, then open only the archive section
needed for a specific task or audit question.

## Goal

Refactor VVTerm so Swift-owned long-lived resources have stable application or
infrastructure owners, lifecycle work is awaitable or tracked, SwiftUI only
sends user intent, and SSH/libssh2 behavior is testable without real network
access.

## Reading Rules

- Start here for every refactor turn.
- Read `docs/engineering/swift-best-practices.md` before Swift or Swift test
  edits, then run `.codex/hooks/swift_lifecycle_guard.py
  --mark-best-practices-read`.
- Use `rg` to locate archive sections, then read a small range with `sed -n`.
- Do not `cat` or broad-read `docs/refactor-swift-best-practice-1.md`.
- Keep completed historical detail in the archive unless it changes active work.
- Keep this file bounded: current Must-Fix scope, current/next task, recent
  ledger, and ready-for-merge gate only.

Useful archive lookups:

```bash
rg -n "^## Task 80|^### Must-Fix|^## Progress Ledger|Task 76" docs/refactor-swift-best-practice-1.md
sed -n '<start>,<end>p' docs/refactor-swift-best-practice-1.md
```

## Global Constraints

- Feature-first architecture remains binding: app-owned code lands in
  `Features`, `Core`, or `App` based on ownership.
- UI sends intent only: open, close, retry, disconnect, trust host, install
  tmux/mosh, resize, send input.
- SwiftUI `View`, `UIViewRepresentable`, `NSViewRepresentable`, and Coordinator
  must not be the sole owner of SSH clients, sockets, shell tasks, file handles,
  timers, or background workers.
- Lifecycle-critical work such as disconnect, close, retry, reconnect, auth,
  save, delete, sync, and cleanup must be awaited or tracked.
- Avoid untracked `Task {}` and `Task.detached {}` for lifecycle-critical work.
  If a call site cannot await, store or return a `Task` and make later
  operations wait on it.
- Non-trivial lifecycle state must be explicit; do not infer business lifecycle
  from view existence, optional object presence, selected tab, or cached
  terminal surfaces.
- C/FFI pointer lifetimes must stay local and obvious; raw C error codes must be
  logged before translation.
- libssh2 handles must not be shared simultaneously. `libssh2_init` uses
  process-global state and must remain serialized.
- Bug fixes and refactors require regression tests when feasible. Test lifecycle
  ordering, not only UI symptoms.
- Unit test files must include test context: protected behavior, target
  invariant, fake assumptions, and when the test should be updated instead of
  treated as a regression.
- iOS simulator focused tests use `ENABLE_DEBUG_DYLIB=NO`,
  `-parallel-testing-enabled NO`, and `-skip-testing:VVTermUITests`.
- Do not claim tests pass unless the test command actually completed.
- Commit atomically. Each commit must represent one invariant, boundary move, or
  documentation update.

## Active Architecture Direction

- `TerminalConnectionRegistry` is the runtime truth for open/active transport
  state.
- `ConnectionState` and `activeTransport` in session or pane models are display
  snapshots, not authoritative runtime truth.
- Prefer manager or application-layer APIs for lifecycle intent:
  `open`, `close`, `retry`, `disconnect`, `reconnect`, `wait`.
- RemoteFiles, Stats, rich paste, tmux, and mosh should use explicit leases or
  command-execution abstractions instead of owning raw shared SSH clients.

## Frozen Closure Scope

After Task 76, the refactor is bounded by this finite closure scope. Only
Must-Fix items block ready-for-merge. Accepted exceptions and Later items are
preserved in the archive.

### Must-Fix Before Ready-for-Merge

- [x] 1. Split static teardown manager boundary. Completed by Task 77.
- [x] 2. Split terminal UI injected-manager boundary. Completed by Task 78.
- [x] 3. Rich paste runtime manager injection. Completed by Task 79.
- [x] 4. iOS foreground reconnect request tracking. Completed by Task 80.
- [x] 5. Server connection-test cancellation and stale callbacks.
  - Evidence: `ServerConnectionTester` stores request tasks and exposes wait,
    but `ServerFormSheet` starts tests without retaining/canceling the request;
    field changes reset UI state only.
  - Required fix: add cancellation/supersede semantics and stale-callback guards
    so changed form input cannot receive an old connection-test result.
  - Status: completed by Task 81.
- [x] 6. RemoteFiles transfer/mutation cancellation on disconnect.
  - Evidence: `RemoteFileBrowserStore` stores remote operation requests, but
    `disconnect(serverId:)` cancels navigation/preview/move state only before
    closing the adapter; UI transfer calls ignore request IDs.
  - Required fix: expose cancel APIs for active transfer/mutation requests,
    cancel same-server operations on disconnect/close, and add ordering tests.
  - Status: completed by Task 82.
- [x] 7. ServerManager startup load tracking.
  - Evidence: `ServerManager` starts `Task { await loadData() }` from init
    without storing or returning the task.
  - Required fix: store/return the startup load task or move startup load into
    an application lifecycle coordinator so startup load ordering is observable
    and awaitable.
  - Status: completed by Task 83.
- [ ] 8. SSHClient untracked channel cleanup tasks.
  - Evidence: `SSHClient` uses untracked `Task {}` from stream termination /
    exec cancellation paths that eventually close/free libssh2 channels.
  - Required fix: track these cleanup tasks in the owning `SSHClient` / runtime
    or make later disconnect/close paths await them.
- [ ] 9. SSHClient mosh stream teardown tracking.
  - Evidence: `SSHClient` mosh stream termination cancels the stream task and
    starts untracked shell teardown, which can stop a live `MoshClientSession`.
  - Required fix: track/await this teardown from the owning `SSHClient` /
    runtime before merge.
- [ ] 10. SSH exec/upload raw libssh2 error preservation.
  - Evidence: `SSHClient` still collapses non-EAGAIN exec channel open/startup/
    write and upload close/wait errors to generic errors after reading or
    encountering raw libssh2 state.
  - Required fix: preserve/log `LibSSH2RawError` before translation on these
    exec/upload paths.

## Current Focus

Next executable slice: Must-Fix 8, SSHClient untracked channel cleanup tasks.

Before code:

1. Inspect `VVTerm/Core/SSH/SSHClient.swift` stream termination and exec
   cancellation paths that close or free libssh2 channels.
2. Add a compact Task 84 section here with files, interfaces, RED tests,
   expected verification, API/boundary cleanup, and commit scope.
3. Follow TDD: RED test first, then implementation, then focused verification.
4. After Task 84, do API/boundary cleanup before moving to Must-Fix 9.

## Task 81: Server Connection-Test Cancellation

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerConnectionTester.swift`
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`
- Test: `VVTermTests/ServerConnectionTesterTests.swift`
- Test: `VVTermTests/ServerFormConnectionTestBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `ServerConnectionTester.requestConnectionTest(...)`.
  - Existing `ServerConnectionTester.pendingConnectionTestRequestIDs`.
  - Existing `ServerConnectionTester.waitForConnectionTestRequest(_:)`.
  - Existing `ServerFormSheet.ConnectionTestSnapshot`.
- Produces:
  - `ServerConnectionTester.requestConnectionTest(id:server:credentials:onSucceeded:onFailed:onCompleted:) -> UUID`.
  - `ServerConnectionTester.cancelConnectionTestRequest(_:)`.
  - `ServerFormSheet.activeConnectionTestRequestID`.
  - Server form field changes cancel the active test and stale callbacks cannot update success/error/testing state.

- [x] **Step 1: Add RED cancellation and stale-callback tests**

Extend `ServerConnectionTesterTests`:
- `connectionTestRequestCancellationClearsPendingAndSkipsLateSuccess`
  - Start a delayed request.
  - Call `cancelConnectionTestRequest(_:)`.
  - Assert `pendingConnectionTestRequestIDs` no longer contains the request ID.
  - Finish the fake successfully.
  - Await `waitForConnectionTestRequest(_:)`.
  - Assert success/failure callbacks did not run and `connectionTestFailure` stayed nil.
- `connectionTestRequestCancellationSkipsLateFailure`
  - Start a delayed request.
  - Cancel it.
  - Finish the fake with `FakeConnectionTestError.rejected`.
  - Await the request.
  - Assert failure callback did not run and `connectionTestFailure` stayed nil.

Extend `ServerFormConnectionTestBoundaryTests`:
- `serverFormConnectionTestHelperCancelsActiveRequestAndGuardsCallbacks`
  - Slice `resetConnectionTestState()` through `applyConnectionTestFailure(...)`.
  - Assert the source contains `activeConnectionTestRequestID`.
  - Assert reset/cancel logic calls `connectionTester.cancelConnectionTestRequest`.
  - Assert `requestConnectionTest(force:)` creates a stable request ID and passes it via `requestConnectionTest(id:`.
  - Assert success, failure, and completion callbacks guard `activeConnectionTestRequestID == requestID`.
  - Assert success/failure callbacks also guard `connectionSnapshot == snapshot`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerConnectionTesterTests -only-testing:VVTermTests/ServerFormConnectionTestBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: tests fail because `cancelConnectionTestRequest(_:)`, caller-provided request IDs, `activeConnectionTestRequestID`, and stale callback guards do not exist.

- [x] **Step 2: Add cancelable application-layer request ownership**

Update `ServerConnectionTester.swift`:
- Replace `[UUID: Task<Void, Never>]` with a private request record that stores `task` and cancellation state.
- Add `cancelConnectionTestRequest(_:)` that marks a request canceled, removes it from visible pending IDs, and cancels its task while keeping `waitForConnectionTestRequest(_:)` awaitable until the task exits.
- Add optional caller-provided request identity through `requestConnectionTest(id: UUID = UUID(), ...)`.
- Before success/failure callbacks or `connectionTestFailure` writes, guard that the request was not canceled and `Task.isCancelled` is false.
- Keep cancellation as lifecycle completion, not a connection failure.

- [x] **Step 3: Route form reset/supersede through cancellation**

Update `ServerFormSheet.swift`:
- Add `@State private var activeConnectionTestRequestID: UUID?`.
- Add `cancelActiveConnectionTest()` that clears the active ID, sets `isTestingConnection = false`, and calls `connectionTester.cancelConnectionTestRequest(_:)`.
- Call `cancelActiveConnectionTest()` from `resetConnectionTestState()` and before starting a new forced test.
- In `requestConnectionTest(force:)`, create `let requestID = UUID()`, assign `activeConnectionTestRequestID = requestID`, and pass `id: requestID`.
- In success/failure/completion callbacks, guard `activeConnectionTestRequestID == requestID`; in success/failure, also guard `connectionSnapshot == snapshot`.
- Do not change credential building, test server construction, validation rules, or user-facing copy.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerConnectionTesterTests -only-testing:VVTermTests/ServerFormConnectionTestBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "activeConnectionTestRequestID|cancelConnectionTestRequest|requestConnectionTest\\(id:|connectionSnapshot == snapshot|pendingConnectionTestRequestIDs|waitForConnectionTestRequest" VVTerm/Features/Servers/Application/ServerConnectionTester.swift VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift VVTermTests/ServerConnectionTesterTests.swift VVTermTests/ServerFormConnectionTestBoundaryTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows the form cancels active requests and guards stale callbacks, while temporary SSH/mosh test work remains owned by `ServerConnectionTester`.

- [x] **Step 5: API and boundary cleanup**

Before review, verify `cancelConnectionTestRequest(_:)` naming matches other manager-owned cancellation APIs, `pendingConnectionTestRequestIDs` reports visible pending work only, wait hooks remain awaitable for canceled-but-running work, UI owns only presentation state/request identity, and no temporary helper or stale callback path remains.

- [x] **Step 6: Review and commit**

Perform local lifecycle review against the Swift checklist unless the user explicitly authorizes new subagents. Fix Critical and Important findings, update Must-Fix 5 status plus Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Task 82: RemoteFiles Transfer and Mutation Disconnect Cancellation

**Files:**
- Modify: `VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift`
- Modify: `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift`
- Test: `VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift`
- Test: `VVTermTests/RemoteFileMutationIntentBoundaryTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `RemoteFileBrowserStore.requestMutation(...)`.
  - Existing `RemoteFileBrowserStore.requestTransfer(...)`.
  - Existing `pendingMutationRequestIDs`, `pendingTransferRequestIDs`, `waitForMutationRequest(_:)`, and `waitForTransferRequest(_:)`.
  - Existing `RemoteFileBrowserScreen.performOperation(...)` and `performTransfer(...)`.
- Produces:
  - `RemoteFileBrowserStore.requestMutation(serverId:operation:onSuccess:onFailure:) -> UUID`.
  - `RemoteFileBrowserStore.requestTransfer(serverId:operation:onProgress:onSuccess:onFailure:) -> UUID`.
  - `RemoteFileBrowserStore.cancelMutationRequests(for:)`.
  - `RemoteFileBrowserStore.cancelTransferRequests(for:)`.
  - `disconnect(serverId:)` cancels same-server visible mutation and transfer requests while keeping wait hooks awaitable until blocked operations exit.
  - RemoteFiles UI helpers pass `server.id` into mutation/transfer requests.

- [x] **Step 1: Add RED disconnect cancellation tests**

Extend `RemoteFileBrowserStoreTests`:
- `disconnectCancelsVisibleMutationRequestsForServerAndSkipsLateSuccess`
  - Start `requestMutation(serverId: server.id, operation:)` with a blocked `RemoteFileMutationGate`.
  - Assert `pendingMutationRequestIDs` contains the request ID.
  - Call `disconnect(serverId: server.id)`.
  - Assert visible pending mutation state clears immediately.
  - Release the gate and await `waitForMutationRequest(_:)`.
  - Assert success/failure callbacks did not run after cancellation.
- `disconnectCancelsVisibleTransferRequestsForServerAndSkipsLateProgressAndSuccess`
  - Start `requestTransfer(serverId: server.id, operation:)` with a blocked gate.
  - Call `disconnect(serverId: server.id)` before the operation emits progress.
  - Assert visible pending transfer state clears immediately.
  - Release the gate and await `waitForTransferRequest(_:)`.
  - Assert progress, success, and failure callbacks did not run after cancellation.
- `disconnectLeavesOtherServerMutationAndTransferRequestsPending`
  - Start one mutation and one transfer for a different server.
  - Disconnect `server.id`.
  - Assert the other server's request IDs remain visible until their gates release.

Extend `RemoteFileMutationIntentBoundaryTests`:
- Update `browserScreenDelegatesMutationTaskOwnershipToStore` to assert mutation helpers call `browser.requestMutation(serverId: server.id, ...)`.
- Update `transferAndDropDelegatesTaskOwnershipToStore` to assert transfer helpers call `browser.requestTransfer(serverId: server.id, ...)`.
- Add a macOS export assertion that direct `browser.requestTransfer(...)` in `RemoteFileBrowserMacScreen` also passes `serverId: server.id`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: tests fail because mutation/transfer request APIs do not accept `serverId`, disconnect does not cancel mutation/transfer requests, and UI helpers do not pass server identity.

- [x] **Step 2: Add server-scoped mutation and transfer request records**

Update `RemoteFileBrowserStore.swift`:
- Replace mutation and transfer task dictionaries with private records containing `serverId: UUID?`, `task`, and cancellation state.
- Keep existing overloads source-compatible by adding default `serverId: UUID? = nil`.
- Add `cancelMutationRequests(for serverId: UUID)` and `cancelTransferRequests(for serverId: UUID)` that mark matching requests canceled, remove them from visible pending IDs, and cancel their tasks.
- Update `pendingMutationRequestIDs` and `pendingTransferRequestIDs` to expose only non-canceled request IDs.
- Keep `waitForMutationRequest(_:)` and `waitForTransferRequest(_:)` awaitable for canceled-but-running tasks until the operation exits.
- Guard mutation success/failure callbacks, transfer progress callbacks, and transfer success/failure callbacks with request cancellation and `Task.isCancelled`.
- Treat cancellation as lifecycle state, not a user-facing transfer/mutation failure.

- [x] **Step 3: Cancel same-server requests from disconnect**

Update `disconnect(serverId:)`:
- Call `cancelMutationRequests(for: serverId)` and `cancelTransferRequests(for: serverId)` before adapter disconnect.
- Keep existing move-destination/navigation/preview cancellation behavior unchanged.
- Do not await mutation/transfer requests in `disconnect`; only keep their wait hooks available for tests and later lifecycle callers.

- [x] **Step 4: Pass server identity from UI helpers**

Update `RemoteFileBrowserScreen.swift`:
- In both `performOperation` overloads, call `browser.requestMutation(serverId: server.id, ...)`.
- In both `performTransfer` paths, call `browser.requestTransfer(serverId: server.id, ...)`.
- Keep error presentation, transfer progress, upload planning, and user-facing copy unchanged.

Update `RemoteFileBrowserMacScreen.swift`:
- In AppKit file export, call `browser.requestTransfer(serverId: server.id, ...)`.

- [x] **Step 5: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/RemoteFileBrowserStoreTests -only-testing:VVTermTests/RemoteFileMutationIntentBoundaryTests ENABLE_DEBUG_DYLIB=NO
rg -n "requestMutation\\(serverId:|requestTransfer\\(serverId:|cancelMutationRequests|cancelTransferRequests|pendingMutationRequestIDs|pendingTransferRequestIDs|waitForMutationRequest|waitForTransferRequest" VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift VVTermTests/Features/RemoteFiles/RemoteFileBrowserStoreTests.swift VVTermTests/RemoteFileMutationIntentBoundaryTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows UI passes server identity and disconnect cancels same-server mutation/transfer requests without stale progress/success/failure callbacks.

- [x] **Step 6: API and boundary cleanup**

Before review, verify mutation/transfer request API naming remains source-compatible and grammatical, RemoteFiles UI still sends intent only, canceled visible pending state is distinct from awaitable running work, no temporary test-only production helpers were added, and disconnect ordering still waits for pending adapter teardown before new same-server SFTP operations.

- [x] **Step 7: Review and commit**

Perform local lifecycle review against the Swift checklist unless the user explicitly authorizes new subagents. Fix Critical and Important findings, update Must-Fix 6 status plus Progress Ledger with RED/GREEN evidence, verification, review outcome, and cleanup notes, then commit atomically.

## Task 83: ServerManager Startup Load Tracking

**Files:**
- Modify: `VVTerm/Features/Servers/Application/ServerManager.swift`
- Test: `VVTermTests/ServerManagerBootstrapTests.swift`
- Modify: `docs/refactor-swift-best-practice.md`

**Interfaces:**
- Consumes:
  - Existing `ServerManager` initialization path.
  - Existing `ServerManager.loadData()`.
  - Existing `ServerManager.makeForTesting(...)`.
- Produces:
  - `ServerManager.pendingStartupLoadRequestIDs`.
  - `ServerManager.waitForStartupLoadRequest(_:)`.
  - `ServerManager.makeForTesting(startStartupLoad:startupLoadAction:...)`.
  - Startup load launched from initialization is owned by `ServerManager`,
    visible as pending while running, and awaitable for tests or later
    lifecycle ordering.

- [x] **Step 1: Add RED startup-load lifecycle tests**

Extend `ServerManagerBootstrapTests`:
- `startupLoadRequestTracksOperationUntilCompletion`
  - Create a testing manager with `startStartupLoad: true` and a gated fake
    startup load action.
  - Assert exactly one startup request ID is visible while the fake load is
    blocked.
  - Start a waiter with `waitForStartupLoadRequest(_:)` and assert it does not
    return before the fake load is released.
  - Release the gate, await the request, and assert pending startup load state
    clears.
- `serverManagerInitDoesNotLaunchUntrackedLoadTask`
  - Inspect `ServerManager.swift`.
  - Assert the init path no longer contains raw `Task { await loadData() }`.
  - Assert startup load is routed through a named owner method such as
    `startStartupLoad()`.

Expected RED command:

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests ENABLE_DEBUG_DYLIB=NO
```

Expected RED result: tests fail because `pendingStartupLoadRequestIDs`,
`waitForStartupLoadRequest(_:)`, startup-load injection, and named startup task
ownership do not exist.

- [x] **Step 2: Add tracked startup-load ownership**

Update `ServerManager.swift`:
- Add a private `StartupLoadAction` dependency defaulting to
  `await manager.loadData()`.
- Add private `startupLoadRequestID` and `startupLoadTask` storage.
- Replace `Task { await loadData() }` in initialization with
  `startStartupLoad()`.
- `startStartupLoad()` creates one request ID, stores the task, runs
  `startupLoadAction(self)`, and clears request/task storage in `defer` only
  when the request ID still matches.
- Expose `pendingStartupLoadRequestIDs` and
  `waitForStartupLoadRequest(_:)`.
- Keep `loadLocalData()` synchronous local bootstrap behavior unchanged.

- [x] **Step 3: Extend testing factory only as needed**

Update `makeForTesting(...)`:
- Add `startStartupLoad: Bool = false`.
- Add `startupLoadAction: StartupLoadAction? = nil`.
- Preserve existing call sites and defaults.
- If `startStartupLoad` is true, allow tests to exercise the same tracked
  startup load path without real CloudKit.

- [x] **Step 4: Run focused verification**

```bash
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -skip-testing:VVTermUITests -only-testing:VVTermTests/ServerManagerBootstrapTests ENABLE_DEBUG_DYLIB=NO
rg -n "pendingStartupLoadRequestIDs|waitForStartupLoadRequest|startStartupLoad|startupLoadTask|Task \\{ await loadData\\(\\) \\}" VVTerm/Features/Servers/Application/ServerManager.swift VVTermTests/ServerManagerBootstrapTests.swift
git diff --check
```

Expected GREEN result: focused tests pass; source scan shows startup load is
named/tracked/awaitable and the old untracked init task is gone.

- [x] **Step 5: API and boundary cleanup**

Before review, verify startup-load API naming matches existing
pending/wait request APIs, `ServerManager` remains the application-layer owner,
test-only injection does not leak production behavior, local bootstrap is still
synchronous, and no stale startup request state remains after completion.

- [x] **Step 6: Review and commit**

Perform local lifecycle review against the Swift checklist unless the user
explicitly authorizes new subagents. Fix Critical and Important findings,
update Must-Fix 7 status plus Progress Ledger with RED/GREEN evidence,
verification, review outcome, and cleanup notes, then commit atomically.

## Verification Template

Focused iOS tests:

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

Compile gate:

```bash
xcodebuild build-for-testing \
  -project VVTerm.xcodeproj \
  -scheme VVTerm \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -skip-testing:VVTermUITests \
  ENABLE_DEBUG_DYLIB=NO
```

## Progress Ledger

- 2026-06-22: Task 83 RED/GREEN completed with local lifecycle review and no
  new subagents. `ServerManager` now owns startup data loading through a named
  `startStartupLoad()` path with `startupLoadTask`, visible
  `pendingStartupLoadRequestIDs`, and `waitForStartupLoadRequest(_:)`; the
  initialization path no longer launches raw `Task { await loadData() }`.
  `makeForTesting(startStartupLoad:startupLoadAction:)` lets tests exercise the
  same startup ownership path without CloudKit. Initial RED failed as expected
  because the testing factory and pending/wait startup APIs did not exist.
  GREEN focused verification passed `ServerManagerBootstrapTests`; source scan
  showed the startup owner method, task storage, pending IDs, wait hook, and no
  production raw init load task. `git diff --check` passed; iOS
  `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. API/boundary cleanup
  found naming consistent with existing pending/wait request APIs, local
  bootstrap remains synchronous, test-only injection does not change production
  load behavior, and startup request state clears after completion.
- 2026-06-21: Task 82 RED/GREEN completed with local lifecycle review and no
  new subagents. `RemoteFileBrowserStore` now owns server-scoped mutation and
  transfer request records with visible pending state, awaitable request tasks,
  and `cancelMutationRequests(for:)` / `cancelTransferRequests(for:)`;
  `disconnect(serverId:)` cancels same-server mutation/transfer requests before
  adapter teardown while preserving wait hooks until blocked operations exit.
  RemoteFiles UI helpers now pass `server.id` into store-owned mutation and
  transfer requests instead of relying on unscoped request IDs. Initial RED
  failed as expected because the request APIs did not accept `serverId`. GREEN
  verification passed `RemoteFileBrowserStoreTests` and
  `RemoteFileMutationIntentBoundaryTests` separately and together; source scan
  showed server-scoped request calls, cancel APIs, pending IDs, and wait hooks
  in the expected Application/UI/test files. `git diff --check` passed; iOS
  `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. API/boundary cleanup
  found the API source-compatible through default `serverId: nil`, RemoteFiles
  UI still sends intent only, canceled visible state remains distinct from
  awaitable running work, and no temporary test-only production helper remains.
- 2026-06-21: Task 81 RED/GREEN completed with local lifecycle review and no
  new subagents. `ServerConnectionTester` now owns cancelable connection-test
  requests through caller-stable request IDs, visible pending state, awaitable
  request tasks, and `cancelConnectionTestRequest(_:)`; canceled requests skip
  late success/failure callbacks and do not write `connectionTestFailure`.
  `ServerFormSheet` now stores only `activeConnectionTestRequestID` plus
  presentation state, cancels the active application-layer request when fields
  reset or a new forced test starts, and guards success/failure/completion
  callbacks by active request ID plus the original `ConnectionTestSnapshot`.
  Initial RED failed as expected because `cancelConnectionTestRequest(_:)` did
  not exist. GREEN focused verification passed `ServerConnectionTesterTests`
  and `ServerFormConnectionTestBoundaryTests`; source scan showed active request
  identity, cancellation, snapshot guards, pending IDs, and wait hooks in the
  expected Application/UI files. `git diff --check` passed; iOS
  `build-for-testing` passed with `ENABLE_DEBUG_DYLIB=NO`. API/boundary cleanup
  found request/cancel/wait names consistent with existing manager-owned
  patterns, visible pending state separated from canceled-but-running work, no
  UI-owned temporary SSH/mosh task, and no stale callback path remaining in the
  server form connection-test helper.
- 2026-06-21: Slimmed the active worktree plan into this index and archived the
  full current historical plan, including Tasks 1-80 and the closure audit, at
  `docs/refactor-swift-best-practice-1.md`. Future turns should read this index
  first and only open targeted archive ranges when historical task detail is
  needed.
- 2026-06-21: Task 80 RED/GREEN completed with local lifecycle review and no
  new subagents. `ConnectionSessionManager` now owns tracked iOS foreground
  reconnect requests through `requestForegroundReconnectForSelectedSession(...)`,
  `pendingForegroundReconnectRequestIDs`, and
  `waitForForegroundReconnectRequest(_:)`; duplicate selected-session requests
  coalesce reconnect work while preserving each callback's own presentation
  action. `iOSContentView.attemptForegroundReconnectIfNeeded(refreshTerminal:)`
  now sends synchronous intent to the manager and no longer starts a local
  reconnect `Task`. Verification passed the focused lifecycle/source-boundary
  suites, `git diff --check`, and iOS `build-for-testing` with
  `ENABLE_DEBUG_DYLIB=NO`.
- 2026-06-21: Task 79 RED/GREEN completed with local lifecycle review and no
  new subagents. Rich-paste runtime factories now receive `sessionManager` /
  `tabManager` from root and split terminal coordinators; upload lifecycle
  ownership remains in existing manager-owned request APIs.

## Ready-For-Merge Gate

- [ ] Every Must-Fix item above is complete or explicitly reclassified with
  evidence.
- [ ] Every Must-Fix item has focused RED/GREEN test coverage or a documented
  source-boundary reason.
- [ ] Final source scan confirms no unresolved Must-Fix evidence remains.
- [ ] `git diff --check` passes.
- [ ] Focused lifecycle tests pass with `ENABLE_DEBUG_DYLIB=NO`.
- [ ] iOS `build-for-testing` passes or any Xcode hang is reported honestly
  with command and symptom.
- [ ] Final local or authorized subagent review reports no Critical or Important
  findings against the remaining diff.
