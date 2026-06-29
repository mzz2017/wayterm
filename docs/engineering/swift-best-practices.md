# Swift Best Practices for Codex Agents

Applies to all Swift, SwiftUI, and Apple-platform code. Unless the user explicitly requests otherwise, do not introduce implementations that violate this guide.

## 1. Ownership and Architecture

- Long-lived resources must have one stable owner.
  - SSH clients, sockets, file handles, database handles, timers, observers, and background workers must be owned by a manager, actor, service, or store.
  - SwiftUI `View`, `UIViewRepresentable`, `NSViewRepresentable`, and Coordinator must not be the sole owner of critical long-lived resources.

- UI sends intent; application layer owns lifecycle.
  - UI may call `open`, `close`, `retry`, `disconnect`, `save`.
  - UI must not directly orchestrate multi-step resource teardown/reconnect flows.

- Prefer explicit state machines for non-trivial lifecycles.
  - Use states like `idle`, `connecting`, `connected`, `closing`, `disconnected`, `failed`.
  - Do not infer lifecycle only from view existence, selected tab, or optional object presence.

- Keep feature boundaries clean.
  - Domain: pure models and rules.
  - Application: state, orchestration, lifecycle, use cases.
  - Infrastructure: storage, networking, SSH, file system, external APIs.
  - UI: rendering and user interaction only.

## 2. Swift Concurrency

- Prefer structured concurrency.
  - Use `async` functions and `await` all critical work.
  - Use `TaskGroup` for child work that must complete before the parent completes.
  - Avoid untracked `Task {}` and `Task.detached {}` for critical operations.

- Fire-and-forget is forbidden for lifecycle-critical work.
  - Disconnect, close, save, delete, sync, authentication, and cleanup tasks must be tracked or awaited.
  - If a task cannot be awaited at the call site, return/store a `Task` and make later operations wait on it.

- Escaping callbacks that perform lifecycle-critical work must be owned, tracked, or explicitly invalidated.
  - Do not rely on `[weak self]` to silently skip close, disconnect, cancel, auth completion, save, delete, sync, or cleanup.
  - If the receiver may disappear before the callback fires, move the callback state into a stable owner, registry, actor, or cancellation token.
  - Late callbacks should either complete cleanup through a retained lifecycle owner, observe an explicit invalidated state, or report cancellation.

- Use actors for shared mutable state and resource ownership.
  - Shared mutable state accessed across concurrency domains should live in an `actor` or be isolated to `@MainActor`.
  - Actors are a good fit for long-lived resources, callback registries, caches, gates, and external systems that need serialized access.
  - Do not turn pure values, parsers, formatters, validators, or stateless policy helpers into actors just to satisfy concurrency warnings.
  - Do not rely on `DispatchQueue` or locks when actor isolation is a natural fit.

- Be explicit about actor isolation.
  - UI state and SwiftUI observable objects should usually be `@MainActor`.
  - Non-UI work should not run on `@MainActor` unless it must touch UI state.
  - In modules or targets with default global actor isolation, use plain `nonisolated` for pure domain values and synchronous helper APIs that have no shared mutable state, lifecycle ownership, or UI dependency.
  - Treat `nonisolated` as a normal boundary tool; reserve `nonisolated(unsafe)` for rare cases with a documented ownership or synchronization invariant.

- Actor methods are reentrant across suspension points.
  - After `await`, re-check state, request identifiers, generation tokens, and cancellation before mutating lifecycle state.
  - Do not assume an actor method is an uninterrupted transaction from entry to return.

- Avoid mixing old and new concurrency without a boundary.
  - Wrap callback, delegate, GCD, or C async APIs behind async functions.
  - Keep continuations small, audited, and resumed exactly once.

- Cancellation must be part of the design.
  - Long-running tasks must check `Task.isCancelled` or `Task.checkCancellation()`.
  - Teardown should cancel in-flight work before releasing resources.

- Enable and respect strict concurrency checks where possible.
  - New code should be compatible with Swift 6-style concurrency checking.
  - Avoid unsafe `nonisolated(unsafe)` unless there is no reasonable alternative and the invariant is documented.

## 3. SwiftUI State and Lifecycle

- SwiftUI views are values; do not treat them as stable objects.
  - Do not store critical runtime ownership in a `View`.
  - Do not assume `onDisappear`, `dismantleUIView`, or `dismantleNSView` means business lifecycle ended.

- Choose state wrappers by ownership.
  - `@State`: view-local value state.
  - `@Binding`: parent-owned state edited by child.
  - `@StateObject` / `@Observable` owner: when the view creates and owns the model.
  - `@ObservedObject` / injected observable: when another layer owns the model.
  - `@EnvironmentObject` / environment: only for truly shared app-level dependencies.

- Keep SwiftUI body pure.
  - Do not start network connections, SSH sessions, database writes, or destructive operations directly from `body`.
  - Use explicit event handlers or `.task(id:)` with cancellation-aware logic.

- View lifecycle cleanup is not a substitute for application cleanup.
  - If a user closes a tab, call the application-layer close operation.
  - Lifecycle callbacks may release UI surfaces, but must not be the only path that closes business resources.

- Avoid duplicated sources of truth.
  - Selection, connection state, tab lists, and error state should have one authoritative owner.
  - Derived UI state should be computed from authoritative state.

## 4. Resource Lifecycle

- Every open must have a matching close.
  - The owner that creates a resource must define its teardown path.
  - Teardown must be idempotent.

- Teardown must be awaitable.
  - Callers that may immediately recreate the same resource must wait for teardown completion.
  - Do not report a resource as closed while underlying close/disconnect work is still running.

- Use per-resource serialization where external systems require it.
  - Authentication, key usage, file writes, and socket reconnects may need gates/queues.
  - If an external C library has unclear thread safety, serialize sensitive paths conservatively.

- Add timeouts around external teardown.
  - Network disconnect, channel close, subprocess termination, and C-library cleanup should not block indefinitely.

## 5. Error Handling

- Use typed errors for expected failures.
  - Prefer domain-specific `Error` enums.
  - Preserve underlying error messages for logs/debugging.

- Do not collapse distinct failures into generic errors too early.
  - Authentication failed, host key mismatch, network unavailable, timeout, cancellation, and missing credentials should remain distinguishable internally.

- Cancellation is not failure.
  - Handle `CancellationError` separately when user intent or lifecycle cancellation is expected.

- User-facing errors should be clear and actionable.
  - Internal logs may include low-level error codes.
  - UI messages should describe what the user can do.

## 6. API Design and Naming

- Follow Swift API Design Guidelines.
  - Names should be clear at the use site.
  - Prefer fluent, grammatical call sites.
  - Avoid abbreviations unless they are universal in the domain.

- Boolean names should read naturally.
  - Good: `isConnected`, `hasActiveSession`, `shouldReconnect`.
  - Avoid ambiguous names like `connected`, `active`, `flag`.

- Methods should express side effects.
  - `make`, `create`, `load`, `save`, `delete`, `connect`, `disconnect`, `close`, `reset` should mean what they say.
  - Avoid hiding mutation behind innocent-looking computed properties.

- Use access control intentionally.
  - Default to the narrowest access that supports tests and architecture.
  - Do not expose mutable state publicly just to make UI code convenient.

## 7. Optionals and Data Modeling

- Use optionals only for genuinely absent values.
  - Do not use `nil` to mean multiple states like "not loaded", "failed", and "empty".
  - Model those as enums.

- Prefer enums with associated values for state.
  - Good: `ConnectionState.connecting(attempt:)`, `.failed(message:)`.
  - Avoid parallel booleans like `isLoading`, `hasError`, `isConnected` when they can conflict.

- Keep domain models value-semantic where possible.
  - Use structs for immutable or copyable domain data.
  - Use classes/actors for identity, ownership, and mutable runtime resources.

## 8. C / Objective-C / FFI Boundaries

- Treat C APIs as unsafe boundaries.
  - Keep pointer lifetimes local and obvious.
  - Do not let `withUnsafeBytes` pointers escape.
  - Document ownership rules for C resources.

- Document callback and pointer ownership contracts at FFI boundaries.
  - For `Unmanaged.passUnretained`, state which Swift owner keeps the object alive until callbacks are impossible.
  - For `const char *`, raw buffers, and userdata pointers, state whether the callee copies synchronously or may retain the pointer.
  - Prefer invalidation tokens or context objects over passing raw view/controller pointers as callback userdata.

- Serialize C library calls when thread-safety is uncertain.
  - Especially auth callbacks, cryptographic signing, global library init/exit, and session teardown.

- Wrap C resources in Swift types.
  - Provide one Swift owner responsible for init, use, cancellation, and cleanup.
  - Make cleanup idempotent.

- Log raw C error codes before translating them.
  - Preserve enough evidence to distinguish bad credentials from callback failure, timeout, socket close, or protocol error.

## 9. Testing

- Bug fixes require regression tests when feasible.
  - Test the lifecycle/state rule that failed, not only the final UI symptom.

- Unit test files must carry enough context for future failure triage.
  - At the top of each test file, include a short `Test Context` comment that states the production behavior or user workflow being protected, the invariant or rule under test, and when the test should be updated instead of treated as a product regression.
  - For regression tests, name the original failure mode in product terms, not only the implementation detail. Do not include secrets, hostnames, credentials, or private user data.
  - Document important fake, clock, scheduler, actor, keychain, network, and C/FFI assumptions in the test file before the tests that depend on them.
  - Each test method must make its goal clear through a descriptive name plus Given/When/Then comments, or an equivalent `@Test` display name and assertion messages.
  - Non-obvious assertions must include a message explaining what behavior would have broken if the assertion fails.
  - If a product or architecture decision changes the intended behavior, update the test context in the same change as the assertion update.

- Async lifecycle code needs ordering tests.
  - Test that close waits for teardown.
  - Test that open waits for pending close.
  - Test that duplicate opens are serialized or rejected.

- Tests should avoid real network unless they are integration tests.
  - Use small actors, fake clients, fake clocks, or injected closures for lifecycle ordering.

- Do not claim tests pass unless they actually ran and completed.
  - If Xcode test execution hangs or only build-for-testing passed, state that explicitly.

## 10. Logging and Diagnostics

- Log at component boundaries.
  - Open requested, credentials loaded, SSH connect started, auth started, auth result, shell registered, close requested, teardown finished.

- Logs must include stable identifiers.
  - Include `serverId`, `sessionId`, client identity where useful, and current state.
  - Do not log secrets, passwords, private keys, tokens, or raw credential material.

- Temporary diagnostic logs should be removed or downgraded after root cause is confirmed.

## 11. Performance

- Keep main actor work small.
  - Heavy parsing, crypto, file IO, network IO, compression, and large data transforms must not run on `@MainActor`.
  - Hot paths such as input routing, rendering, display refresh, stream processing, and FFI callback conversion should avoid unnecessary actor hops.
  - Resource owners may be actors while pure conversion and routing helpers remain synchronous and `nonisolated`.

- Avoid unnecessary SwiftUI invalidation.
  - Keep observable state scoped.
  - Avoid large global observable objects that cause unrelated views to redraw.

- Prefer lazy and incremental work.
  - Do not eagerly create expensive resources in SwiftUI view initialization.

## 12. Code Style

- Prefer clarity over cleverness.
  - Small explicit functions are better than dense chained logic for lifecycle code.

- Keep comments focused on invariants.
  - Comment why ordering, isolation, or ownership matters.
  - Do not comment obvious assignments.

- Keep formatting consistent with the surrounding codebase.
  - Follow Swift API Design Guidelines and the repo's existing style.
  - Use SwiftFormat/SwiftLint only if already adopted by the project.

## 13. Review Checklist for Agents

Before finishing Swift changes, verify:

- Is there exactly one owner for each long-lived resource?
- Can every close/disconnect path be awaited or tracked?
- Are there any untracked `Task` / `Task.detached` calls doing critical work?
- Can every escaping callback that touches lifecycle-critical work still run safely if delivered late?
- Are `[weak self]`, `Unmanaged.passUnretained`, and temporary C string/buffer pointers backed by an explicit ownership or invalidation contract?
- Does SwiftUI lifecycle only manage UI surfaces, not business resources?
- Is mutable shared state actor-isolated or `@MainActor`?
- Are pure values, parsers, validators, formatters, and policy helpers free of accidental global-actor isolation?
- Do actor methods re-check state or cancellation after `await` before completing lifecycle transitions?
- Do hot paths avoid unnecessary actor or `@MainActor` hops?
- Are external C/FFI calls protected by explicit lifetime and concurrency rules?
- Are errors internally distinguishable?
- Are tests or build verification run and reported honestly?
