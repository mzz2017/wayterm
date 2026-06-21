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
- [ ] 5. Server connection-test cancellation and stale callbacks.
  - Evidence: `ServerConnectionTester` stores request tasks and exposes wait,
    but `ServerFormSheet` starts tests without retaining/canceling the request;
    field changes reset UI state only.
  - Required fix: add cancellation/supersede semantics and stale-callback guards
    so changed form input cannot receive an old connection-test result.
- [ ] 6. RemoteFiles transfer/mutation cancellation on disconnect.
  - Evidence: `RemoteFileBrowserStore` stores remote operation requests, but
    `disconnect(serverId:)` cancels navigation/preview/move state only before
    closing the adapter; UI transfer calls ignore request IDs.
  - Required fix: expose cancel APIs for active transfer/mutation requests,
    cancel same-server operations on disconnect/close, and add ordering tests.
- [ ] 7. ServerManager startup load tracking.
  - Evidence: `ServerManager` starts `Task { await loadData() }` from init
    without storing or returning the task.
  - Required fix: store/return the startup load task or move startup load into
    an application lifecycle coordinator so startup load ordering is observable
    and awaitable.
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

Next executable slice: Must-Fix 5, Server connection-test cancellation and stale
callbacks.

Before code:

1. Inspect `VVTerm/Features/Servers/Application/ServerConnectionTester.swift`
   and `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`.
2. Add a compact Task 81 section here with files, interfaces, RED tests,
   expected verification, API/boundary cleanup, and commit scope.
3. Follow TDD: RED test first, then implementation, then focused verification.
4. After Task 81, do API/boundary cleanup before moving to Must-Fix 6.

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
