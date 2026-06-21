# Swift Best Practice Refactor Index

This is the active, slim index for the VVTerm Swift lifecycle refactor.

The full historical implementation plan was archived to
`docs/refactor-swift-best-practice-1.md`. Do not read the archive wholesale during
normal work. Use this file first, then open only the archive section needed for a
specific task or audit question.

## Goal

Refactor VVTerm so Swift-owned long-lived resources have stable application or
infrastructure owners, lifecycle work is awaitable or tracked, SwiftUI only sends
user intent, and SSH/libssh2 behavior is testable without real network access.

## Reading Rules

- Start here for every refactor turn.
- Read `docs/engineering/swift-best-practices.md` before Swift or Swift test edits.
- Use `rg` to locate archive sections, then read a small range with `sed -n`.
- Do not `cat` or broad-read `docs/refactor-swift-best-practice-1.md`.
- Keep completed historical detail in the archive unless it changes active work.
- Update this index after each completed task or plan correction.

Useful archive lookups:

```bash
rg -n "^## Task 14|^## Task 15|^## Progress Ledger|^## Current Evidence" docs/refactor-swift-best-practice-1.md
sed -n '<start>,<end>p' docs/refactor-swift-best-practice-1.md
```

## Global Constraints

- Feature-first architecture remains binding: app-owned code lands in `Features`,
  `Core`, or `App` based on ownership.
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
  from view existence, optional object presence, selected tab, or cached terminal
  surfaces.
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

## Task Index

Archived source: `docs/refactor-swift-best-practice-1.md`.

- [x] Task 1: Reject late shell registration.
- [x] Task 2: Make session and pane close awaitable.
- [x] Task 3: Extract `TerminalConnectionRunner` from UI.
- [x] Task 4: Introduce terminal entity state.
- [x] Task 5: Add `TerminalConnectionRuntime` actor.
- [x] Task 6: Move tab SSH ownership out of coordinators.
- [x] Task 7: Move split pane SSH ownership out of coordinators.
- [x] Task 8: Extract terminal surface registry.
- [x] Task 9: Make authentication gate cancellation-aware.
- [x] Task 10: Add testable libssh2 session boundary.
- [x] Task 11: Make blocking SSH operations abortable.
- [x] Task 12: Preserve tmux, mosh, and known-host error semantics.
- [x] Task 13: Add `RemoteConnectionLease` for cross-feature use.
- [x] Task 14: Remove duplicated runtime sources of truth.
- [ ] Task 15: Final lifecycle sweep.

## Current Focus

Task 15 is the current top-level closure task.

Before touching code for Task 15:

1. Run the audit commands below.
2. Classify each lifecycle-critical hit as fixed, tracked by a current manager
   API, or explicitly exempt.
3. Add focused regression tests before changing production code.
4. Keep every resulting commit scoped to one lifecycle invariant or boundary.

Audit commands:

```bash
rg -n "SSHClient\\(" VVTerm/Features VVTerm/App -g '*.swift'
rg -n "Task\\.detached|Task \\{" VVTerm/Features VVTerm/Core VVTerm/App -g '*.swift'
rg -n "deinit|dismantleUIView|dismantleNSView" VVTerm/Features VVTerm/Core VVTerm/App -g '*.swift'
```

Focused lifecycle verification:

```bash
xcodebuild test \
  -project VVTerm.xcodeproj \
  -scheme VVTerm \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -skip-testing:VVTermUITests \
  -only-testing:VVTermTests/ConnectionSessionManagerOpenTests \
  -only-testing:VVTermTests/ConnectionLifecycleIntegrationTests \
  -only-testing:VVTermTests/TerminalSurfaceTeardownTests \
  -only-testing:VVTermTests/SSHAuthenticationGateTests \
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

## Progress Ledger

- 2026-06-21: Slimmed the active plan into this index and archived the full
  historical plan at `docs/refactor-swift-best-practice-1.md` to reduce context
  consumption. Future turns should read this index first and only open targeted
  archive ranges when historical task detail is needed.
- 2026-06-20: Original full plan created from local code audit, read-only
  explorer audits, and Swift/libssh2 references. See archive for detailed task
  instructions and historical evidence.

## Ready-For-Merge Gate

- [ ] Task 15 final lifecycle audit has no unclassified lifecycle-critical hits.
- [ ] All production lifecycle-critical `Task` usage is awaited, returned, or
  stored by an application/infrastructure owner.
- [ ] SwiftUI lifecycle callbacks only clean UI surfaces and do not own business
  teardown.
- [ ] Focused lifecycle tests pass with `ENABLE_DEBUG_DYLIB=NO`.
- [ ] `git diff --check` passes.
- [ ] iOS `build-for-testing` passes or any Xcode hang is reported honestly with
  command and symptom.
