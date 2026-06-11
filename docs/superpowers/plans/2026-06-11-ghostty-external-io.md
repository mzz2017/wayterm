# Switch VVTerm to ghostty External I/O backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace VVTerm's `wiedymi/ghostty custom-io` bridge (`use_custom_io` + `ghostty_surface_feed_data` + `ghostty_surface_set_write_callback`) with `ghostty-zmx`'s first-class `External` termio backend (`backend_type=EXTERNAL` + `ghostty_surface_write_output` + config-level `write_callback`/`resize_callback` + `ghostty_surface_external_exited`).

**Architecture:** The new write/resize callbacks are C function pointers set at surface-creation time; they recover the `GhosttyTerminalView` via `ghostty_surface_userdata` (which VVTerm already sets) and forward to the existing `writeCallback`/`onResize` Swift closures. SSH-side wiring is untouched. SSH disconnect now also calls `external_exited` for ghostty's real session-ended UI.

**Tech Stack:** Swift (iOS/macOS), libghostty (Zig/C via xcframework), Bash build script, Xcode.

**Environment note:** This Linux box has NO Swift/Xcode/xcodebuild. Layer C (Swift + build.sh) is edited here; it does NOT compile here and won't compile anywhere until Layer B rebuilds the xcframework from the new fork. Build/test steps are marked `[Mac]`/`[Xcode]` for the user.

**Branch (VVTerm):** `feat/ghostty-external-io` (off `main`; spec already committed).

---

## Prerequisites (Layers A & B — NOT done in this repo/box)

These are external and block compilation. Documented so the executor knows the order.

### Layer A — publish the fork `[user]`

`~/projects/ghostty-zmx` branch `ios-external-io` must be pushed to `mzz2017/ghostty`:

```bash
cd ~/projects/ghostty-zmx
gh repo create mzz2017/ghostty --public --source=. --remote=mzz2017 2>/dev/null || \
  git remote add mzz2017 https://github.com/mzz2017/ghostty.git
git push mzz2017 ios-external-io
```

(Local `gh` auth here is `miles-byted`, and `mzz2017/ghostty` does not exist — the user runs this with their own credentials.)

### Layer B — rebuild xcframework `[Mac]`

After Layer A and Task 1 (build.sh repoint), on a macOS machine with Xcode + zig:

```bash
cd <vvterm-on-mac>
./scripts/build.sh ghostty
```

This regenerates `Vendor/libghostty/GhosttyKit.xcframework`, the per-platform `libghostty.a`, and the vendored `include/ghostty.h` (now carrying `ghostty_surface_write_output`, `ghostty_surface_external_exited`, `backend_type`, `write_callback`, `resize_callback`, `GHOSTTY_BACKEND_EXTERNAL`). Commit the regenerated Vendor artifacts.

---

## Layer C — Swift cutover (done in this repo)

### Task 1: Repoint the build script at the new fork

**Files:**
- Modify: `scripts/build.sh` (lines 18-19)

- [ ] **Step 1: Change repo + default ref**

In `scripts/build.sh`, replace:

```bash
GHOSTTY_REPO="https://github.com/wiedymi/ghostty.git"
GHOSTTY_REF="${GHOSTTY_REF:-custom-io}"
```

with:

```bash
GHOSTTY_REPO="${GHOSTTY_REPO:-https://github.com/mzz2017/ghostty.git}"
GHOSTTY_REF="${GHOSTTY_REF:-ios-external-io}"
```

(Making `GHOSTTY_REPO` overridable too, so a fork-of-fork can be tested without editing the script.)

- [ ] **Step 2: Commit**

```bash
git add scripts/build.sh
git commit -m "build: point GhosttyKit at mzz2017/ghostty ios-external-io (External backend)"
```

---

### Task 2: Surface config — backend_type + write/resize callbacks

**Files:**
- Modify: `VVTerm/GhosttyTerminal/GhosttyRenderingSetup.swift` (macOS `setupSurface` ~L98-119; iOS `setupSurface` ~L188-211)

The two C callbacks are `@convention(c)` (no captures); they recover the view from the surface's userdata (already set to the view on the line above) and forward to the view's existing closures. Define them once as file-private statics and reference from both macOS and iOS setup.

- [ ] **Step 1: Add the two C trampolines (file-private, shared by both platforms)**

At the top of `GhosttyRenderingSetup.swift` (after imports, before the type), add:

```swift
/// External-backend write callback (terminal → embedder). Invoked by libghostty
/// on the IO thread when the user produces input. Recovers the view via the
/// surface userdata VVTerm sets at creation and forwards to `writeCallback`.
private let ghosttyExternalWriteCallback: ghostty_write_callback_fn = { surface, data, len in
    guard let surface, let data, len > 0 else { return }
    guard let ud = ghostty_surface_userdata(surface) else { return }
    let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
    let swiftData = Data(bytes: data, count: Int(len))
    view.writeCallback?(swiftData)
}

/// External-backend resize callback (terminal grid changed → embedder should send
/// an SSH window-change). Invoked on the IO thread. Forwards cols/rows to the
/// view's `onResize`; pixel dims are available but SSH only needs cols/rows.
private let ghosttyExternalResizeCallback: ghostty_resize_callback_fn = { surface, cols, rows, _, _ in
    guard let surface else { return }
    guard let ud = ghostty_surface_userdata(surface) else { return }
    let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
    view.onResize?(Int(cols), Int(rows))
}
```

- [ ] **Step 2: Set backend_type + callbacks in macOS setupSurface**

In the macOS `setupSurface` (where it currently does `surfaceConfig.use_custom_io = useCustomIO`, ~L107), replace that line with:

```swift
        // Select the External termio backend for SSH (embedder-driven I/O).
        if useCustomIO {
            surfaceConfig.backend_type = GHOSTTY_BACKEND_EXTERNAL
            surfaceConfig.write_callback = ghosttyExternalWriteCallback
            surfaceConfig.resize_callback = ghosttyExternalResizeCallback
        } else {
            surfaceConfig.backend_type = GHOSTTY_BACKEND_EXEC
        }
```

The existing `if !useCustomIO, let command = command, !command.isEmpty { ... }` gate stays as-is (command only applies to the exec backend).

- [ ] **Step 3: Same for iOS setupSurface**

In the iOS `setupSurface` (where it does `surfaceConfig.use_custom_io = useCustomIO`, ~L199), apply the identical replacement as Step 2.

- [ ] **Step 4: Build check** `[Xcode, after Layer B]`

Deferred — won't compile until the xcframework carries the new symbols.

- [ ] **Step 5: Commit**

```bash
git add VVTerm/GhosttyTerminal/GhosttyRenderingSetup.swift
git commit -m "feat(ghostty): select External backend + set write/resize callbacks at surface creation"
```

---

### Task 3: macOS view — write_output + external_exited, drop runtime write-callback

**Files:**
- Modify: `VVTerm/GhosttyTerminal/GhosttyTerminalView+macOS.swift` (custom-IO section ~L788-822; cleanup ~L139)

The view keeps its `writeCallback`/`onResize` Swift closures (set by the wrappers). What changes: `feedData` → `writeOutput` (calls `ghostty_surface_write_output`), `setupWriteCallback()` is deleted (callbacks now set at surface creation in Task 2), and a new `externalExited()` is added.

- [ ] **Step 1: Replace feedData with writeOutput**

In `GhosttyTerminalView+macOS.swift`, replace the `feedData(_:)` method (~L793-805) with:

```swift
    /// Feed data from the SSH channel into the terminal (External backend).
    /// Mirrors the exec backend's read thread; callers serialize per surface.
    func writeOutput(_ data: Data) {
        guard let surface = surface?.unsafeCValue else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_output(surface, ptr, buffer.count)
        }
        // Request render via display link (event-driven, auto-stops when idle)
        requestRender()
    }

    /// Notify the terminal that the SSH session ended (External backend), so it
    /// shows ghostty's real "session ended" UI instead of going silent.
    func externalExited(_ exitCode: UInt32 = 0) {
        guard let surface = surface?.unsafeCValue else { return }
        ghostty_surface_external_exited(surface, exitCode)
        requestRender()
    }
```

- [ ] **Step 2: Delete setupWriteCallback()**

Remove the entire `setupWriteCallback()` method (~L807-822). The write callback is now set at surface creation (Task 2). Keep the `var writeCallback: ((Data) -> Void)?` property — the trampoline forwards to it.

- [ ] **Step 3: Fix cleanup (no more set_write_callback)**

In `cleanup()` (~L139) remove the line:

```swift
        ghostty_surface_set_write_callback(cSurface, nil, nil)
```

(The External backend owns its callbacks via config; there's no runtime clearer. Surface teardown drops them.)

- [ ] **Step 4: Commit**

```bash
git add VVTerm/GhosttyTerminal/GhosttyTerminalView+macOS.swift
git commit -m "feat(ghostty/macOS): writeOutput + externalExited; drop runtime write-callback"
```

---

### Task 4: iOS view — mirror Task 3

**Files:**
- Modify: `VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift` (custom-IO section ~L4102-4134; cleanup ~L1247)

- [ ] **Step 1: Replace feedData with writeOutput**

In `GhosttyTerminalView+iOS.swift`, replace `feedData(_:)` (~L4107-4119) with:

```swift
    /// Feed data from the SSH channel into the terminal (External backend).
    func writeOutput(_ data: Data) {
        guard let surface = surface?.unsafeCValue else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_output(surface, ptr, buffer.count)
        }
        scheduleCustomIORedraw()
        requestRender()
    }

    /// Notify the terminal that the SSH session ended (External backend).
    func externalExited(_ exitCode: UInt32 = 0) {
        guard let surface = surface?.unsafeCValue else { return }
        ghostty_surface_external_exited(surface, exitCode)
        scheduleCustomIORedraw()
        requestRender()
    }
```

- [ ] **Step 2: Delete setupWriteCallback()**

Remove the `setupWriteCallback()` method (~L4121-4134). Keep `var writeCallback: ((Data) -> Void)?`.

- [ ] **Step 3: Fix cleanup**

In the iOS `cleanup()` (~L1247) remove:

```swift
        ghostty_surface_set_write_callback(cSurface, nil, nil)
```

- [ ] **Step 4: Check the IME/toolbar direct-write path still compiles**

`GhosttyTerminalView+iOS.swift` ~L3753 `sendRawTerminalInputText` calls `if let writeCallback { writeCallback(data) }` directly — this still works (the closure is unchanged). No edit needed; just confirm it's not calling the removed `setupWriteCallback`.

- [ ] **Step 5: Commit**

```bash
git add VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift
git commit -m "feat(ghostty/iOS): writeOutput + externalExited; drop runtime write-callback"
```

---

### Task 5: Ghostty.Surface.swift wrapper — align dead wrappers

**Files:**
- Modify: `VVTerm/GhosttyTerminal/Ghostty.Surface.swift` (~L204-254)

These wrappers (`feedData`/`feedText`/`setWriteCallback`/`WriteCallback`) are currently unused (call sites go through the view directly), but they reference symbols being removed (`ghostty_surface_feed_data`, `ghostty_surface_set_write_callback`) and would break compilation. Replace them with the External equivalents for API hygiene.

- [ ] **Step 1: Replace the Custom I/O API block**

Replace the block from `// MARK: - Custom I/O API (for SSH clients)` through the end of `setWriteCallback` (~L204-253) with:

```swift
        // MARK: - External backend I/O (for SSH clients)

        /// Feed remote bytes (e.g. SSH output) into the terminal for display.
        /// Used with the External termio backend. Caller serializes per surface.
        @MainActor
        func writeOutput(_ data: Data) {
            guard let surface = unsafeCValue else { return }
            guard !data.isEmpty else { return }
            data.withUnsafeBytes { buffer in
                if let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) {
                    ghostty_surface_write_output(surface, ptr, buffer.count)
                }
            }
        }

        /// Convenience: feed a UTF-8 string into the terminal.
        @MainActor
        func writeOutputText(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            writeOutput(data)
        }

        /// Notify the terminal that the external session ended (SSH disconnect).
        @MainActor
        func externalExited(_ exitCode: UInt32 = 0) {
            guard let surface = unsafeCValue else { return }
            ghostty_surface_external_exited(surface, exitCode)
        }
```

- [ ] **Step 2: Fix any internal callers of feedText**

`Ghostty.Surface.sendText` is separate (uses `ghostty_surface_text`) — not affected. Grep to confirm nothing else calls `feedData`/`feedText`/`setWriteCallback` on `Ghostty.Surface`:

```bash
grep -rn "\.feedData(\|\.feedText(\|\.setWriteCallback(" VVTerm/ | grep -iv "GhosttyTerminalView"
```

Expected: no hits (the view-level methods are renamed in Tasks 3-4; the Surface-level ones were dead).

- [ ] **Step 3: Commit**

```bash
git add VVTerm/GhosttyTerminal/Ghostty.Surface.swift
git commit -m "refactor(ghostty): replace dead custom-io Surface wrappers with External equivalents"
```

---

### Task 6: SSHTerminalWrapper call sites (macOS + iOS)

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`

Three kinds of edit: (a) `terminal.feedData(...)` → `terminal.writeOutput(...)` in the read loop + failure path; (b) delete `setupWriteCallback()` calls (callbacks now set at surface creation); (c) call `externalExited` at the `onProcessExit` site so disconnect shows the session-ended UI. `useCustomIO: true` STAYS (it's the flag `setupSurface` keys the External backend on — Task 2 kept that param). `writeCallback`/`onResize` closures STAY.

- [ ] **Step 1: feedData → writeOutput (read loop + failure)**

In `shouldContinueStreaming` (~L274) change `terminal.feedData(data)` → `terminal.writeOutput(data)`.
In `onFailure` (~L297) change `terminal.feedData(data)` → `terminal.writeOutput(data)`.
(There are macOS and iOS coordinator copies of these closures; both call through the shared `SSHConnectionRunner`. Update every `terminal.feedData(` in this file — confirm with `grep -n "feedData" SSHTerminalWrapper.swift`.)

- [ ] **Step 2: Call externalExited on process exit**

In the `onProcessExit:` closure (~L291-293), add the terminal notification before the existing callback. The closure has the terminal in scope via the coordinator; use the coordinator's `terminalView`:

```swift
                onProcessExit: {
                    coordinator.terminalView?.externalExited(0)
                    onProcessExit()
                },
```

(Match the coordinator handle name actually in scope — `coordinator` for macOS `Coordinator`, the iOS representable's coordinator equivalently. If the closure already captures `terminal`, call `terminal.externalExited(0)`.)

- [ ] **Step 3: Remove setupWriteCallback() calls**

Delete the `terminalView.setupWriteCallback()` / `existingTerminal.setupWriteCallback()` calls (macOS ~L474, iOS ~L793). Grep: `grep -n "setupWriteCallback" SSHTerminalWrapper.swift` → expect zero after.

- [ ] **Step 4: Build** `[Xcode, after Layer B]` — deferred.

- [ ] **Step 5: Commit**

```bash
git add VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift
git commit -m "feat(ssh-terminal): use writeOutput + externalExited; drop setupWriteCallback"
```

---

### Task 7: Split-pane call site (macOS)

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`

- [ ] **Step 1: feedData → writeOutput**

Change `terminal.feedData(data)` in `shouldContinueStreaming` (~L1253) and `onFailure` (~L1276) to `terminal.writeOutput(data)`.

- [ ] **Step 2: externalExited at process exit**

In the `onProcessExit:` closure (~L1270-1271), add `coordinator.terminalView?.externalExited(0)` (match the in-scope coordinator/terminal handle) before the existing `onProcessExit()`.

- [ ] **Step 3: Remove setupWriteCallback() call**

Delete `terminalView.setupWriteCallback()` (~L1057). Grep to confirm zero remain in this file.

- [ ] **Step 4: Commit**

```bash
git add VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift
git commit -m "feat(splits): use writeOutput + externalExited; drop setupWriteCallback"
```

---

### Task 8: Final cutover sweep

**Files:** repo-wide grep verification.

- [ ] **Step 1: No old symbols remain**

```bash
grep -rn "ghostty_surface_feed_data\|ghostty_surface_set_write_callback\|use_custom_io\|\.feedData(\|setupWriteCallback" VVTerm/
```

Expected: ZERO hits. (`useCustomIO` the Swift bool flag MAY remain — it now selects the External backend in `setupSurface`. If you prefer, rename it to `externalBackend` for clarity, updating the property + init param in both view files and the 3 call sites; optional, mechanical.)

- [ ] **Step 2: New symbols present where expected**

```bash
grep -rn "ghostty_surface_write_output\|ghostty_surface_external_exited\|GHOSTTY_BACKEND_EXTERNAL\|backend_type\|write_callback\|resize_callback" VVTerm/
```

Expected: `GhosttyRenderingSetup.swift` (config + trampolines), both view files (writeOutput/externalExited), `Ghostty.Surface.swift` (wrappers).

- [ ] **Step 3: Commit any rename cleanup (if done)**

```bash
git add -A && git commit -m "refactor(ghostty): rename useCustomIO flag to externalBackend"
```

(Skip if you left the flag name as-is.)

---

## Verification (Mac/Xcode, after Layers A+B+C)

1. `./scripts/build.sh ghostty` regenerates the xcframework from `mzz2017/ghostty ios-external-io`; commit Vendor artifacts.
2. Xcode build (⌘B) — compiles against the new header.
3. Runtime (device/sim):
   - [ ] SSH output renders (write_output path).
   - [ ] Keystrokes reach the remote (write_callback trampoline, IO-thread).
   - [ ] Window/pane resize sends an SSH window-change (resize_callback).
   - [ ] SSH disconnect shows ghostty's "session ended" UI (external_exited).
   - [ ] tmux AND zmx attach still work; the session-binding auto-reattach still works (regression — that feature is on a separate branch; test after both land).
   - [ ] Voice-input / IME / toolbar text still reaches the shell (the direct `writeCallback` path).

## Done criteria

- Layer C committed on `feat/ghostty-external-io`, codex-reviewed to ready-to-merge.
- After Layers A+B on Mac: app compiles, all runtime checks above pass.
- No `feed_data`/`set_write_callback`/`use_custom_io` references remain in Swift.

## Threading note (carry into review)

Old `set_write_callback` fired on the **main thread**; the new External
`write_callback`/`resize_callback` fire on the **IO thread** (per ghostty.h).
The trampolines forward to `writeCallback`/`onResize`, which call
`sshClient.write`/`sshClient.resize` (actor-isolated, safe to call cross-thread)
and SwiftUI state updates. Verify the `onResize`/`writeCallback` closures don't
touch UIKit/AppKit directly on the calling thread; if they do, hop to main.
Flag this explicitly for codex review.
