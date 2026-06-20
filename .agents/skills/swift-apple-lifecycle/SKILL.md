---
name: swift-apple-lifecycle
description: Use for Swift, SwiftUI, iOS, macOS, Apple platform, SSH/resource lifecycle, concurrency, teardown, reconnect, async ordering, C/FFI, or Swift bugfix/review work. Trigger when code touches UIViewRepresentable/NSViewRepresentable, Coordinator, long-lived resources, Task/Task.detached, actors, connection/session managers, or lifecycle-critical close/disconnect/auth/save/delete flows.
---

# Swift Apple Lifecycle

Use this skill to keep Swift and SwiftUI changes aligned with VVTerm's ownership, lifecycle, and concurrency rules.

## References

- Read `references/review-checklist.md` before the final response for Swift changes.

## Workflow

0. Before editing Swift or Swift test files, read `docs/engineering/swift-best-practices.md`, say in the first work update that it was read, then run `python3 .codex/hooks/swift_lifecycle_guard.py --mark-best-practices-read`.
1. Identify the stable owner of every long-lived resource touched by the change.
2. Trace lifecycle intent from UI to application/infrastructure layers. UI should send intent; managers, actors, services, or stores should own orchestration.
3. Check every close/disconnect/retry/reconnect/auth/save/delete path for awaitable or tracked critical work.
4. Replace lifecycle-critical fire-and-forget work with structured concurrency, awaited work, stored `Task`s, or an explicit queue/gate.
5. Use explicit state for non-trivial lifecycles instead of deriving business lifecycle from SwiftUI view presence.
6. Keep SwiftUI lifecycle callbacks limited to UI-surface cleanup unless they call into an application-layer lifecycle API.
7. Preserve low-level diagnostic detail at C/FFI boundaries while keeping user-facing errors actionable.
8. Add regression tests for lifecycle ordering when feasible.
9. Verify with focused tests or builds, and report exactly what completed.

## Review Focus

- Flag `Task {}` and `Task.detached {}` when they perform critical teardown, auth, persistence, sync, or resource cleanup.
- Flag SwiftUI `View`, representable, or Coordinator code that creates or solely owns long-lived resources.
- Flag close/reopen flows that can report completion before underlying teardown has completed.
- Flag C/FFI calls with unclear pointer lifetime, missing raw error logging, or uncertain thread safety.
