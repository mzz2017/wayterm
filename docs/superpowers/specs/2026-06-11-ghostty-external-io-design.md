# Switch Waterm to ghostty-zmx External I/O backend

Date: 2026-06-11
Branch (Waterm): `feat/ghostty-external-io`
Fork target: `mzz2017/ghostty` branch `ios-external-io`

## Goal

Migrate Waterm's SSH↔terminal bridge from the `wiedymi/ghostty` `custom-io`
fork API (`use_custom_io` + `ghostty_surface_feed_data` +
`ghostty_surface_set_write_callback`) to the cleaner `External` termio backend
in `ghostty-zmx` (`backend_type = EXTERNAL` + `ghostty_surface_write_output` +
config-level `write_callback`/`resize_callback` + `ghostty_surface_external_exited`).

Rationale (decided earlier): the External backend is a first-class termio union
arm rather than an `if use_custom_io` special-case; its resize callback carries
pixel dims (RFC 4254 window-change without app-side recompute); and
`external_exited` routes SSH disconnect through ghostty's real "session ended"
UI (same `child_exited` path as a local process exit).

## Constraints (verified)

- This Linux dev box has **no `xcodebuild`/`xcrun`/`lipo`** → the
  GhosttyKit.xcframework rebuild (layer B) is impossible here; it MUST run on a
  Mac. `zig`, `perl`, `rsync` are present but insufficient (`-Demit-xcframework`
  needs Apple tooling; `build.sh` also uses BSD `sed -i ''`).
- `ghostty-zmx`'s `ios-external-io` branch is **not pushed** to any remote;
  `~/projects/ghostty-zmx` `origin` still points at `ghostty-org/ghostty`.
  `mzz2017/ghostty` **does not exist yet**; local `gh` auth is `miles-byted`.
- Therefore the work splits into three layers; only layer C is doable here.

## Three layers

**A. Publish the fork** (user / mzz2017 creds): push `ios-external-io` to
`mzz2017/ghostty`.

**B. Rebuild xcframework** (Mac): point `scripts/build.sh` at the new fork+ref
and run `./scripts/build.sh ghostty` on macOS to regenerate
`Vendor/libghostty/GhosttyKit.xcframework` + per-platform `.a` + headers.

**C. Swift API cutover** (this box): repoint build.sh, swap the Swift bridge
from custom-io to External. Committed + codex-reviewed here. Does not compile
until B lands a matching xcframework — inherent to the split.

## Layer C — the cutover

The new API reuses Waterm's EXISTING `surfaceConfig.userdata`
(`Unmanaged.passUnretained(view)`, already recovered via
`ghostty_surface_userdata` in `Ghostty.App.swift:662`). The External
`write_callback`/`resize_callback` receive `(surface, ...)` and recover the
`GhosttyTerminalView` from that same userdata — so we REMOVE the separate
`set_write_callback(userdata)` plumbing rather than add parallel state.

### API mapping

| Concern | Old (custom-io) | New (External) |
|---|---|---|
| Enable backend | `surfaceConfig.use_custom_io = true` | `surfaceConfig.backend_type = GHOSTTY_BACKEND_EXTERNAL` |
| SSH→terminal | `ghostty_surface_feed_data(s, ptr, len)` | `ghostty_surface_write_output(s, ptr, len)` |
| terminal→SSH | runtime `ghostty_surface_set_write_callback(s, cb, ud)` | config field `write_callback`; recover view via `ghostty_surface_userdata(s)` |
| resize→SSH | app polls grid in `layout()` → `onResize(cols,rows)` | config field `resize_callback(s, cols, rows, w_px, h_px)` → `onResize` |
| disconnect | shell-stream-ends → `onProcessExit` only | also `ghostty_surface_external_exited(s, code)` → real child-exited UI |

### Design decisions

1. **Keep the Swift closures (`writeCallback`, `onResize`) intact.** New C
   callbacks are thin trampolines that recover the view via
   `ghostty_surface_userdata` and forward to the existing closures. All SSH-side
   wiring (`coordinator.sendToSSH`, `sshClient.resize`) is untouched → minimal
   blast radius.
2. **`write_callback` signature change**: old `(void* userdata, const uint8_t*,
   size_t)` → new `(ghostty_surface_t surface, const char*, uintptr_t)`. The
   trampoline casts `data` and recovers the view from the surface's userdata.
3. **`resize_callback` replaces the `layout()` grid-poll → onResize path** for
   the SSH window-change. Keep the existing `onResize` closure as the sink; the
   callback now feeds it (with pixel dims available, though SSH only needs
   cols/rows today). The app-side grid poll can stay as a fallback or be removed
   if redundant — prefer removing to avoid double-sending.
4. **`external_exited` upgrade**: at the existing `onProcessExit` site (SSH
   shell stream ends / disconnect), also call `ghostty_surface_external_exited`
   so the terminal shows ghostty's real session-ended UI + honors
   `wait-after-command`. This is the main robustness win and is in scope.
5. **Direct cutover, no compat shim** (per CLAUDE.md + goal-mode): delete the
   custom-io code paths rather than keeping both.

### Files to change (layer C)

- `scripts/build.sh`: `GHOSTTY_REPO` → `https://github.com/mzz2017/ghostty.git`,
  default `GHOSTTY_REF` → `ios-external-io`.
- `Waterm/GhosttyTerminal/GhosttyRenderingSetup.swift`: replace
  `surfaceConfig.use_custom_io = useCustomIO` (×2: macOS L107, iOS L199) with
  `surfaceConfig.backend_type` + assign `write_callback`/`resize_callback`
  config fields; keep the `!useCustomIO` command gate logic keyed on the new
  backend choice.
- `Waterm/GhosttyTerminal/Ghostty.Surface.swift`: replace `feedData` body to
  call `ghostty_surface_write_output`; drop `setWriteCallback`/`WriteCallback`
  (now config-time); add `externalExited(code:)` wrapper.
- `Waterm/GhosttyTerminal/GhosttyTerminalView+macOS.swift` &
  `+iOS.swift`: `feedData`→`writeOutput` (call write_output); replace
  `setupWriteCallback()` runtime registration with config-time callbacks +
  C trampolines that recover the view via userdata and forward to
  `writeCallback`/`onResize`; remove `useCustomIO` property/init param (replace
  with a backend-type flag); add `externalExited()`; update cleanup (no
  `set_write_callback(nil,nil)` — the surface owns the config callbacks).
- `Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
  (macOS + iOS) & `Waterm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
  (macOS): swap `useCustomIO: true` for the External backend selector; remove
  `setupWriteCallback()` calls (callbacks now set at surface creation); wire
  `external_exited` at the `onProcessExit` site. `writeCallback`/`onResize`
  closures stay as-is.

### Header note

Waterm's vendored `ghostty.h` is regenerated by layer B (build.sh rsyncs the
fork's `include/`). Layer C's Swift must match the NEW header's symbols
(`ghostty_surface_write_output`, `ghostty_surface_external_exited`,
`backend_type`, `write_callback`, `resize_callback`,
`GHOSTTY_BACKEND_EXTERNAL`). Until B runs, the Swift references those symbols
against the old vendored header → won't compile here, expected.

## Testing / verification

- Layer C: codex review of the diff on this box (no compile possible).
- Layer B+full: on Mac — `./scripts/build.sh ghostty`, then Xcode build (⌘B),
  then device/sim runtime checks:
  - SSH output renders (write_output path).
  - Keystrokes reach the remote (write_callback trampoline).
  - Resizing the window sends an SSH window-change (resize_callback).
  - SSH disconnect shows ghostty's "session ended" UI (external_exited).
  - tmux/zmx attach + the session-binding feature still work end-to-end.

## Out of scope

- The zmx/session-binding/ssh-auth feature branch (separate, app-side only).
- Any ghostty rendering/input behavior changes beyond the I/O backend swap.
- Auto-installing the Mac toolchain.

## Open items (require user / Mac)

1. Push `ios-external-io` to `mzz2017/ghostty` (repo doesn't exist; auth is
   miles-byted here).
2. Run layer B on a Mac after layer C lands.
