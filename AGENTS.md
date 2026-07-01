# VVTerm

Cross-platform (iOS/macOS) SSH terminal app with iCloud sync and Keychain credential storage.

## Target Versions

- **macOS**: 13.3+ (Ventura), arm64 and x86_64
- **iOS**: 16.1+, arm64 devices and arm64/x86_64 simulator
- **Xcode**: 16.0+

## Architecture

```
.
├── VVTerm/                       # Main app target source
│   ├── App/                      # App entry, composition roots, app shell
│   │   ├── Application/
│   │   ├── Localization/
│   │   └── iOS/
│   │       └── Application/
│   ├── Core/                     # Shared cross-feature infrastructure
│   │   ├── Analytics/
│   │   ├── Engagement/
│   │   ├── Logging/
│   │   ├── Network/
│   │   │   └── Cloudflare/
│   │   ├── Security/
│   │   ├── SSH/
│   │   ├── Sync/
│   │   ├── Terminal/
│   │   │   └── Logic/
│   │   └── UI/
│   │       ├── iOS/
│   │       └── Notices/
│   ├── Features/                 # Feature-first product code
│   │   ├── ConnectionViews/      # Domain, Application
│   │   ├── LocalDiscovery/       # Domain, Application, Infrastructure, UI
│   │   ├── RemoteFiles/          # Domain, Application, Infrastructure, UI
│   │   ├── Security/             # Domain, Application, Infrastructure, UI
│   │   ├── Servers/              # Domain, Application, Infrastructure, UI
│   │   ├── Settings/             # Application, Infrastructure, UI
│   │   ├── Stats/                # Domain, Application, Infrastructure, UI
│   │   ├── Store/                # Domain, Application, UI
│   │   ├── Support/              # UI
│   │   ├── TerminalAccessories/  # Domain, Application, UI
│   │   ├── TerminalPresets/      # Domain, Application, UI
│   │   ├── TerminalSessions/     # Domain, Application, Infrastructure, UI
│   │   ├── TerminalThemes/       # Domain, Application, Infrastructure
│   │   ├── VoiceInput/           # Application, Infrastructure, UI
│   │   └── Welcome/              # Domain, UI
│   ├── GhosttyTerminal/          # libghostty bridge and terminal runtime integration
│   │   ├── Bridge/               # Ghostty C/Swift wrapper types
│   │   ├── Shared/               # Cross-platform terminal models and policies
│   │   ├── Surface/              # Surface registration and rendering setup
│   │   ├── iOS/
│   │   │   ├── Find/
│   │   │   ├── Input/
│   │   │   ├── Presentation/
│   │   │   ├── Scroll/
│   │   │   ├── Selection/
│   │   │   ├── Surface/
│   │   │   ├── View/
│   │   │   └── Zoom/
│   │   └── macOS/
│   ├── Compatibility/            # Version/platform compatibility helpers
│   ├── Generated/                # Build-time generated sources
│   ├── Resources/                # Bundled assets, themes, terminfo, l10n
│   └── Assets.xcassets/          # App asset catalog
├── VVTermLiveActivity/           # Live Activity extension target
├── VVTermShared/                 # Shared target folder
├── VVTermTests/                  # Unit and architecture/boundary tests
├── VVTermUITests/                # UI tests
├── VVTermLinuxTests/             # Linux-compatible test coverage
├── Vendor/                       # Prebuilt third-party native dependencies
├── scripts/                      # Build/test/packaging automation
├── docs/                         # Engineering docs and specs
└── web/                          # Web/supporting frontend assets
```

## Architecture Direction

VVTerm uses a **feature-first architecture** for app-owned source code.

Current architecture:
- `App` owns app entry, composition roots, shared root containers, localization preferences, and iOS app-shell navigation.
- `Core/Sync` owns CloudKit sync infrastructure.
- `Core/Security` owns keychain, device identity, and privacy-mode infrastructure.
- `Core/Network` owns shared connectivity monitoring and Cloudflare transport support.
- `Core/UI` owns shared view primitives and presentation helpers reused across features.
- `Core/Terminal` owns shared clipboard, paste, and terminal text/default helpers.
- `Core/Logging` owns shared logging utilities.
- `Core/Analytics` owns shared analytics event tracking primitives.
- `Core/Engagement` owns shared engagement/review prompt tracking primitives.
- `Core/SSH` owns shared SSH bootstrap, known-hosts, key generation, environment detection, rich-paste support, tmux/mosh runtime helpers, and `SSHClient`.
- `Features/ConnectionViews` owns connection view tab configuration types and state.
- `Features/RemoteFiles` owns remote file browsing, preview, transfer, and SFTP integration.
- `Features/LocalDiscovery` owns discovery-specific code and UI.
- `Features/Servers` owns server/workspace domain models, server management, credential/known-host persistence adapters, connection testing, and server/workspace UI flows.
- `Features/Stats` owns server metrics collection and presentation.
- `Features/Security` owns app lock and biometric authentication flows.
- `Features/Settings` owns settings persistence, settings window presentation, and settings screens.
- `Features/Store` owns Pro entitlements, purchases, and upgrade surfaces.
- `Features/Support` owns support/contact UI surfaces.
- `Features/TerminalThemes` owns theme models, validation, storage paths, parsing, and theme management.
- `Features/TerminalAccessories` owns keyboard accessory models, preferences, settings UI, and accessory validation flows.
- `Features/TerminalPresets` owns terminal preset models, persistence, and preset form UI.
- `Features/TerminalSessions` owns terminal session/tab domain models, session/tab managers, runtime preference persistence, snapshot stores, tmux binding/prompt coordination, live activity support, and terminal session UI.
- `Features/VoiceInput` owns transcription settings/model download state, transcription/audio capture infrastructure, MLX model management, and transcription settings UI.
- `Features/Welcome` owns welcome/onboarding copy and presentation.
- New app code should land in `Features`, `Core`, or `App` based on ownership.
- New work inside a feature should stay inside its `Features/<FeatureName>` subtree and should not reintroduce app-wide bucket folders.

Feature-first shape:
- `Domain`: pure feature types and rules
- `Application`: feature state, orchestration, coordinators, use-case style logic
- `Infrastructure`: transport, persistence, adapters, external integrations
- `UI`: SwiftUI/AppKit/UIKit presentation only

For Files/SFTP specifically:
- no non-view logic under `UI`
- no feature policy inside `SSHClient` beyond low-level transport/session behavior
- use explicit dependency injection at the feature boundary
- do direct cutovers, not compatibility shims

For every feature:
- keep `Domain`, `Application`, `Infrastructure`, and `UI` boundaries intact
- prefer view-owned dependencies to be injected from the app/screen boundary instead of created inside leaf views
- if shared cross-feature primitives are needed, extract them into `Core` instead of creating new app-wide bucket folders

## Directory Structure Rules

Use real filesystem directories as ownership boundaries; do not rely on Xcode-only virtual groups.

Top-level app-owned code belongs in:
- `App`: app entry, composition roots, app shell, localization, root navigation
- `Features`: feature-first product code
- `Core`: shared cross-feature infrastructure and primitives
- `GhosttyTerminal`: libghostty bridge and terminal runtime integration
- `Compatibility`, `Generated`, `Resources`: narrow purpose-specific buckets

Feature folders should use the relevant subset of `Domain`, `Application`, `Infrastructure`, and `UI`; do not create empty layers just to satisfy the shape.

When a folder becomes module-like, add internal owner folders instead of growing flat files. For `GhosttyTerminal`, prefer `Bridge`, `Surface`, `Shared`, `iOS/<Owner>`, and `macOS/<Owner>`.

Move files only when clarifying a real owner or extracting one coherent responsibility. Avoid cosmetic reshuffles, catch-all folders like `Helpers`/`Utils`/`Common`, and broad access-control widening just to make a move compile.

Verify new or moved Swift files with a build or focused tests so Xcode file-system-synchronized groups include them in the intended target.

## Refactoring Rules

When doing architectural refactors:
- prioritize structural splits and ownership cleanup over behavior changes
- preserve existing UI, UX, and visual behavior unless the user explicitly asks for a change
- do not bundle redesigns or new features into a refactor
- keep platform parity intact unless a platform-specific bug is being fixed
- if a behavior change is necessary for correctness or safety, keep it minimal and isolated

Safe refactor expectation:
- same screens
- same entry points
- same interactions
- same user-facing flows
- smaller files, clearer boundaries, better ownership

### Superfile Control

- Do not add new superfiles.
- A Swift source file is a superfile when it is over roughly 1200 lines, or when it is over roughly 800 lines and also has multiple responsibilities, non-trivial lifecycle ownership, cross-layer dependencies, or tests that are hard to localize.
- Treat files over roughly 800 lines as design debt signals, not as an automatic mandate for low-value splits. Use line count to trigger ownership review.
- Prioritize splits by risk and responsibility: extract stable owners for lifecycle, persistence, FFI, input routing, state machines, protocol adapters, and parsing before cosmetic line-count reductions.
- Root/composition views should stay small, ideally 200-300 lines, and only wire dependencies, navigation, and top-level presentation state.
- Move feature UI, policy, parsing, lifecycle intent, and state orchestration into the owning `Features/<FeatureName>` or `Core` layer instead of expanding app-shell files.
- Prefer direct structural splits with focused tests over compatibility shims or partial duplicate paths.
- If touching an existing superfile, either reduce it, extract a coherent owned piece with focused behavior or boundary tests, or document why the change cannot reasonably shrink it in the same atomic commit.
- Avoid extracting code that only saves a few lines while creating unclear ownership, broadening access control, or locking implementation details into brittle structure-only tests.

## Commits

- Use **atomic commits**.
- Each commit must represent one coherent change that can be reviewed and reverted independently.
- Do not mix architecture docs, code moves, behavioral fixes, and unrelated cleanup in one commit unless they are inseparable.
- Prefer a sequence such as:
  - architecture/spec update
  - domain extraction
  - application/store extraction
  - infrastructure extraction
  - UI split
  - targeted safety fix
- Before committing, verify the diff matches a single intent.

## Key Components

### Terminal
- Uses **libghostty** (Ghostty terminal emulator) via xcframework
- Metal GPU rendering
- iOS keyboard toolbar with special keys (Esc, Tab, Ctrl, arrows)

### SSH
- **libssh2** + **OpenSSL** for SSH connections
- Auth methods: Password, SSH Key, Key+Passphrase
- Credentials stored in Keychain

### Data Sync
- **CloudKit** for server/workspace sync across devices
- Container: `iCloud.app.vivy.VivyTerm`
- Local fallback via UserDefaults

### Pro Tier (StoreKit 2)
- Free: 1 workspace, 3 servers, 1 tab
- Pro: Unlimited everything
- Products: Monthly ($6.49), Yearly ($24.99), Lifetime ($49.99)

## Build Dependencies

### libghostty
Pre-built xcframework at `Vendor/libghostty/GhosttyKit.xcframework`
Build with: `./scripts/build.sh ghostty`

### libssh2 + OpenSSL
Build with: `./scripts/build.sh ssh`
Output: `Vendor/libssh2/{macos,ios,ios-simulator}/`

## Testing Notes

### Test Quality

- Treat tests as the behavior harness, not as after-the-fact reassurance. A
  good regression test should fail on the broken implementation, pass after the
  fix, and protect a user-visible workflow, lifecycle ordering rule, resource
  ownership invariant, or explicit architecture rule.
- For bug fixes, prefer TDD: write the smallest meaningful failing test first,
  run it, verify it fails for the expected product/architecture reason, then
  implement the minimal fix and rerun the same focused test to GREEN.
- Do not call a test good just because it compiles or increases coverage. If it
  would still pass with the original bug restored, rewrite it or remove it.
- Prefer behavior tests over mocks that only prove the fake was called. Use
  fake clients, fake transports, fake clocks, small actors, gates, and injected
  closures to prove observable ordering such as awaited teardown, cancellation,
  retry, duplicate intent coalescing, late callback suppression, source/destination
  ownership, and error preservation.
- Source/string/boundary tests are secondary harnesses. Use them only to guard
  explicit rules from this file, keep them narrow, name them as boundary tests,
  and do not use them as proof that runtime behavior works.
- Keep every new test tied to a single intent. Avoid broad "coverage" tests that
  mix unrelated lifecycle, UI, persistence, sync, authentication, or transfer
  behavior.
- A focused test is enough for an atomic commit only when it covers the changed
  owner and failure mode. Run broader focused suites after several related owner
  fixes, and run full iOS unit tests at phase gates.
- Be precise about evidence: `build-for-testing` proves compilation, not XCTest
  execution; a focused class proves that class, not the whole app; a hung or
  bootstrap-failed run is not a pass.
- Prefer behavior and boundary tests that protect real invariants over tests that only assert file shape, line count, symbol names, or incidental implementation layout.
- Structure-only tests are allowed only when they guard an explicit architecture rule from this file. Keep them narrow, documented, cheap to update, and named as boundary tests.
- Do not add tests whose only value is making a refactor appear covered. Each new test should make clear what behavior, lifecycle ordering, ownership boundary, or architectural invariant it protects.
- When refactoring, update or remove brittle tests if they no longer protect a meaningful invariant; do not preserve them as compatibility debt.
- Async and lifecycle tests should assert ordering, awaited cleanup, cancellation, retry, or resource ownership behavior instead of merely checking that a method or callback exists.
- If a test primarily enforces architecture, keep assertions close to the rule being protected and avoid coupling to unrelated source layout.

### iOS CLI tests
- For full iOS CLI verification, prefer the repo wrapper. It serializes testing, uses isolated DerivedData with a shared Swift package clone cache, disables Xcode's debug dylib layout, preboots the target simulator, and retries only simulator preflight launch failures:

```bash
IOS_TEST_RAMDISK_MB=8192 ./scripts/test-ios.sh
```

- Pass normal `xcodebuild test` filters after the script name for focused runs:

```bash
IOS_TEST_RAMDISK_MB=8192 ./scripts/test-ios.sh \
  -only-testing:VVTermTests/<TestClass>
```

- For long test runs, inspect/report results through `rg` filters so build
  noise does not flood context. Use patterns broad enough to retain warning/error
  lines, test names, suite summaries, executed counts, and failure markers:

```bash
IOS_TEST_RAMDISK_MB=8192 rtk ./scripts/test-ios.sh \
  -only-testing:VVTermTests/<TestClass> 2>&1 \
  | rtk rg -n "warning:|error:|Testing failed|BUILD FAILED|TEST FAILED|Test Suite|Test run with|Executed test count|Issue|<TestClass>"
```

- When filtered output is not enough for diagnosis, preserve the wrapper's raw
  xcodebuild logs with `IOS_TEST_LOG_DIR`, then run `rg` against the printed log
  path after the test finishes. If using a shared log directory, remove only the
  specific log/metadata files printed by this run; other agents may be writing
  to the same directory:

```bash
IOS_TEST_LOG_DIR=/tmp/vvterm-ios-logs IOS_TEST_RAMDISK_MB=8192 \
  rtk ./scripts/test-ios.sh -only-testing:VVTermTests/<TestClass>

rtk rg -n "warning:|error:|Testing failed|BUILD FAILED|TEST FAILED|Test run with|Executed test count|<TestClass>" \
  /tmp/vvterm-ios-logs/xcodebuild-test-attempt-*-*.log
rtk rm -f /tmp/vvterm-ios-logs/xcodebuild-test-attempt-1-passed.log \
  /tmp/vvterm-ios-logs/xcodebuild-test-attempt-1-metadata.txt
```

- For local agent-run iOS wrapper invocations, default to `IOS_TEST_RAMDISK_MB=8192` so auto-managed DerivedData lives on a RAM disk while the default Swift package checkout cache stays in the ignored repo-local `.build/vvterm-ios-source-packages` cache for warm focused runs. The wrapper also favors lower simulator churn by reusing an already booted simulator and disabling extra XCTest diagnostics by default; use `IOS_TEST_REUSE_BOOTED_SIMULATOR=0` or `IOS_TEST_COLLECT_DIAGNOSTICS=on-failure` when debugging simulator boot/install state or failure diagnostics, and avoid RAM disk mode when memory pressure is high.
- The wrapper defaults to the shared `VVTermUnitTests` scheme, which contains `VVTermTests` but not `VVTermUITests`. Set `IOS_TEST_SCHEME=VVTerm` when intentionally exercising the full shared scheme or UI test target.
- The default destination is `iPhone 17`. Override with `IOS_TEST_DEVICE_NAME` or `IOS_TEST_DESTINATION_ID` when needed. Override the package clone cache with `IOS_TEST_CLONED_SOURCE_PACKAGES_DIR` when isolation from the shared package cache is required. The default no-output watchdog is 900 seconds; use `IOS_TEST_NO_OUTPUT_TIMEOUT` for shorter focused diagnostics.
- Do not leave fixed DerivedData directories under `/private/tmp`. The wrapper auto-cleans its default DerivedData path, and explicit `IOS_TEST_DERIVED_DATA_PATH` values are auto-cleaned only when they are safe `vvterm-*` temp directories. Set `IOS_TEST_KEEP_DERIVED_DATA=1` only for intentional diagnostics, then delete the directory when finished. Use `dust -d 1 /private/tmp` when investigating local disk pressure.

### iOS simulator tests
- On macOS 26.5.1 / Xcode 26.5, app-hosted iOS unit tests can hang before XCTest output when Xcode's debug dylib layout is enabled (`ENABLE_DEBUG_DYLIB=YES`, the default app-debug layout). The app launches, but the host process has no `XCTestConfigurationFilePath` and no `DYLD_INSERT_LIBRARIES=...libXCTestBundleInject...`, so XCTest never injects the test bundle.
- For focused CLI iOS unit tests, use `ENABLE_DEBUG_DYLIB=NO`, disable parallel testing, and skip UI tests:

```bash
xcodebuild test \
  -project VVTerm.xcodeproj \
  -scheme VVTermUnitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:VVTermTests/<TestClass> \
  ENABLE_DEBUG_DYLIB=NO
```

- The shared `VVTerm` scheme includes both `VVTermTests` and `VVTermUITests`; `-skip-testing:VVTermUITests` prevents running UI tests but Xcode may still prepare/build the UI test target. Use `VVTermUnitTests` for unit gates unless the UI test runner is intentionally part of the run.

## Swift Lifecycle Rules

- For Swift, SwiftUI, iOS, macOS, SSH/resource lifecycle, concurrency, teardown, reconnect, or Apple platform bugfix/review work, use the repo skill `$swift-apple-lifecycle`.
- Before editing Swift or Swift test files, read `docs/engineering/swift-best-practices.md` in the current session and say so in the first work update. The Codex `PostToolUse` hook records the read automatically; if the marker is missing after a valid read, run `python3 .codex/hooks/swift_lifecycle_guard.py --mark-best-practices-read` as a fallback. The Codex hook resets this marker at session start and blocks Swift diffs without it.
- SwiftUI `View`, `UIViewRepresentable`, `NSViewRepresentable`, and Coordinator must not be the sole owner of critical long-lived resources.
- UI sends intent; the application layer owns lifecycle, teardown, reconnect, and retry orchestration.
- Lifecycle-critical work such as disconnect, close, save, delete, sync, authentication, and cleanup must be awaited or tracked.
- Avoid untracked `Task {}` and `Task.detached {}` for lifecycle-critical work. If a call site cannot await, store or return a `Task` and make later operations wait on it.
- Non-trivial lifecycles should use explicit states such as `idle`, `connecting`, `connected`, `closing`, `disconnected`, and `failed`; do not infer business lifecycle from SwiftUI view existence.
- Mutable shared state should be actor-isolated or `@MainActor`; keep heavy parsing, crypto, file IO, and network IO off the main actor.
- VVTerm enables default MainActor isolation for app code. Before fixing Swift concurrency warnings, classify the type first:
  - resource owners, UI state, observable stores, and lifecycle coordinators should stay actor-isolated or `@MainActor`
  - pure domain values, policy structs/enums, parsers, formatters, validators, and synchronous conversion helpers should usually be explicit `nonisolated`
  - do not add `@MainActor` to production or test code merely to silence a warning
- Avoid unnecessary actor or `@MainActor` hops on terminal hot paths: keyboard/input routing, display link/rendering, stream processing, FFI callbacks, and synchronous clipboard/text conversion.
- Actor methods are reentrant across `await`; close/reconnect/sync/auth/surface attach-detach paths must re-check request identity, state, and cancellation after suspension before publishing lifecycle results.
- C/FFI calls must keep pointer lifetimes local, preserve raw error codes in logs, and serialize sensitive paths when thread-safety is uncertain.
- Bug fixes need regression tests when feasible, especially async ordering tests for close/open/reconnect behavior.
- Strict concurrency build warnings can be used as RED/GREEN evidence, but the fix must improve the actor/resource boundary. Prefer behavior lifecycle tests for close/reconnect/cleanup/auth/download/upload over source-shape tests when feasible.
- Unit test files must include enough context for future triage: protected behavior, test target/invariant, fake assumptions, and when the test should be updated instead of treated as a regression. Individual tests should have descriptive names plus Given/When/Then comments or equivalent assertion messages.
- Do not claim tests pass unless they ran and completed. If only `build-for-testing` passed or XCTest hung, state that explicitly.

## Data Models

### Server
```swift
struct Server: Identifiable, Codable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
}
```

Credential material may live in local Keychain or, when sync is enabled, sync
through iCloud Keychain. `SyncSettings` / CloudKit sync is the app-wide
cross-device sync control: when it is disabled, server credentials, Cloudflare
OAuth tokens, and Cloudflare service tokens must stay device-local. Credential
secrets must never be serialized into CloudKit `Server` records. CloudKit may
carry only non-secret server metadata.

### Workspace
```swift
struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorHex: String
    var environments: [ServerEnvironment]
    var order: Int
}
```

### ConnectionSession (local only, not synced)
```swift
struct ConnectionSession: Identifiable {
    let id: UUID
    let serverId: UUID
    var title: String
    var connectionState: ConnectionState
}
```

## UI Patterns

### macOS Layout
- NavigationSplitView with sidebar (workspaces/servers) and detail (terminal)
- Toolbar tabs for multiple connections
- `.windowToolbarStyle(.unified)`

### iOS Layout
- NavigationStack with server list
- Full-screen terminal with keyboard toolbar
- Sheet-based forms

### Liquid Glass (iOS 26+ / macOS 26+)
```swift
// Use adaptive helpers for backwards compatibility
.adaptiveGlass()           // Falls back to .ultraThinMaterial
.adaptiveGlassTint(.green) // For semantic tinting
```

## Important Notes

1. **Current product work targets the iOS app**. Do not use macOS UI behavior,
   macOS gating, or macOS-only flows as the primary reason for a product fix
   unless the user explicitly asks for macOS support.
2. **Never apply glass to terminal content** - only navigation/toolbars
3. **Deduplicate by ID** when syncing from CloudKit
4. **Pro limits enforced in**: `ServerManager.canAddServer`, `canAddWorkspace`, `ConnectionSessionManager.canOpenNewTab`
5. **Keychain credentials** are governed by `SyncSettings`: when CloudKit sync
   is disabled, credentials and Cloudflare tokens must remain device-local.
   When moving a Keychain item between synced and device-local storage, do not
   update with `kSecAttrSynchronizableAny`; write the target synchronizable
   class and remove the opposite class.
6. **Terminal tab snapshots** must not persist or restore empty server buckets
   as open servers; iOS open-server state must come from real tabs/sessions.
7. **iOS keyboard toolbar** provides Esc, Tab, Ctrl, arrows, function keys
8. **Voice-to-command** uses MLX Whisper/Parakeet on-device or Apple Speech fallback
