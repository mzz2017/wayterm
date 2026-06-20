# Swift Apple Lifecycle Review Checklist

Before finishing Swift changes, verify:

- There is exactly one stable owner for each long-lived resource.
- UI sends lifecycle intent instead of orchestrating multi-step teardown or reconnect flows.
- Every close, disconnect, retry, reconnect, auth, save, delete, sync, and cleanup path is awaited or tracked.
- No lifecycle-critical work runs in untracked `Task {}` or `Task.detached {}`.
- SwiftUI lifecycle callbacks release UI surfaces only, or call an application-layer lifecycle API.
- Non-trivial lifecycle state is modeled explicitly rather than inferred from optional values or view existence.
- Shared mutable state is actor-isolated or `@MainActor`.
- Heavy parsing, crypto, file IO, and network IO do not run on `@MainActor` unless unavoidable.
- C/FFI pointer lifetimes are local and obvious.
- C/FFI error codes are logged before translation.
- Sensitive C/FFI paths are serialized when thread-safety is uncertain.
- Expected failures remain internally distinguishable.
- Regression tests cover lifecycle ordering when feasible.
- Unit test files include test context: protected behavior, target invariant, fake assumptions, and the condition under which the test should be updated rather than treated as a regression.
- Individual test methods have clear intent via descriptive names plus Given/When/Then comments or equivalent display names and assertion messages.
- Verification commands actually completed; otherwise, report the limitation.
