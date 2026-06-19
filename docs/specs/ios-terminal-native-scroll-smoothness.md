# iOS Terminal Native Scroll Smoothness

Draft date: 2026-06-20
Status: Proposed

## Summary

VVTerm can make iOS terminal scrolling substantially smoother, and the clean path is technically feasible with the APIs already present in the app and the vendored Ghostty bridge.

The fix should not be a larger multiplier, a different friction constant, or more `requestRender()` calls. The current iOS path is not native scrolling: a `UIPanGestureRecognizer` converts touch movement into Ghostty mouse wheel events, applies custom momentum, and forces layer display. That makes plain terminal scrollback feel less like Termius because UIKit is not owning the scroll gesture, deceleration, rubber-banding, or frame pacing.

The proposed V1 is:

- Use a native `UIScrollView` only when VVTerm/Ghostty owns the host scrollback.
- Keep the existing terminal mouse event path when a remote program owns the scroll, such as tmux mouse mode, vim, less, full-screen TUIs, or a future Mosh/tmux flow.
- Mirror the existing macOS `NSScrollView` design: build a virtual scroll document from Ghostty scrollbar state, map native `contentOffset` back to Ghostty `scroll_to_row`, and avoid custom iOS momentum for host scrollback.
- Treat tmux/Mosh smooth remote history as a separate V2 overlay problem, not as a V1 native scroll wrapper problem.

This gives us an elegant design because scroll ownership is explicit. It avoids pretending that local scrollback, remote mouse input, and tmux server-side history are the same UX problem.

## Feasibility Conclusion

V1 is feasible.

The current code already has the hard primitives:

- Ghostty reports scrollbar state as `total`, `offset`, and `len` in `Ghostty.Action.Scrollbar`.
- Ghostty posts `.ghosttyDidUpdateScrollbar` through `Ghostty.App`.
- Ghostty accepts `surface.perform(action: "scroll_to_row:\(row)")`.
- macOS already proves the same model in `TerminalScrollView`.
- iOS already stores `scrollbar` and `cellSize` on `GhosttyTerminalView`.
- UIKit provides the native scroll physics through `UIScrollView`, including `contentOffset`, `panGestureRecognizer`, and `decelerationRate`.

The main engineering work is app-side gesture ownership and view containment. It does not require a new terminal renderer, a new SSH layer, or a new Ghostty C API for the host-scrollback V1.

## Research Findings

### Current iOS Path

`VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift` currently installs a `UIPanGestureRecognizer` and handles scrolling in `handlePanGesture(_:)`.

Observed behavior:

- Pan translation is multiplied by `scrollMultiplier = 1.5`.
- Movement is sent to Ghostty as `Ghostty.Input.MouseScrollEvent` with precision scroll enabled.
- Momentum is custom `CADisplayLink` logic.
- Momentum velocity is normalized by a fixed `60.0`, which is not native UIKit physics and is not display-rate independent on 120 Hz devices.
- Deceleration is a fixed per-frame `0.92`.
- Each scroll tick calls `requestRender()`.
- `requestRender()` eventually marks IOSurface layers as needing display.

This is the core reason the gesture cannot feel like Termius-style native iOS scrolling. UIKit is only providing raw touches; VVTerm is reimplementing scroll physics and then asking the terminal to redraw row-based scroll state.

### Current macOS Path

`VVTerm/GhosttyTerminal/TerminalScrollView.swift` wraps the terminal view in an `NSScrollView`.

Important properties:

- It maintains a virtual `documentView` whose height represents Ghostty scrollback.
- It listens for `.ghosttyDidUpdateScrollbar`.
- It converts native scroll position into a Ghostty row.
- It calls `surface.perform(action: "scroll_to_row:\(row)")`.

This is the model iOS should copy conceptually, using `UIScrollView` instead of `NSScrollView`.

### Ghostty Core Behavior

In `/home/mzz/projects/ghostty-zmx/src/Surface.zig`, Ghostty's scroll callback does two distinct things:

- When mouse reporting is active, wheel input is app input and is forwarded as terminal mouse events.
- Otherwise, Ghostty updates viewport scrollback and queues a render.

High-precision scroll input still eventually becomes row movement. That means a native iOS scroll wrapper should not spam wheel events for host scrollback. It should let `UIScrollView` own pixel-level gesture physics and only synchronize Ghostty at row boundaries.

Ghostty also already handles `scroll_to_row` by updating viewport state and queueing a render. That makes repeated app-side `requestRender()` during host scrolling suspicious: it may add extra layer work without improving scroll physics.

### tmux and Mosh Are Different

Mosh does not have the same local byte-stream scrollback model as SSH. Moshi's own article explains that Mosh synchronizes current screen state, while tmux provides server-side history and mouse scrolling. Source: https://getmoshi.app/articles/fix-mosh-scrollback

VVTerm's generated tmux config currently enables:

- `set -g history-limit 10000`
- `set -g mouse on`
- `WheelUpPane` and `WheelDownPane` bindings that forward mouse events or enter copy mode

The tmux manual describes mouse mode as tmux capturing mouse events and binding wheel actions. Source: https://man7.org/linux/man-pages/man1/tmux.1.html

Therefore, tmux/Mosh smooth scrolling is not the same as host scrollback smoothing. When tmux mouse mode owns wheel input, VVTerm is sending input to a remote application. A `UIScrollView` cannot directly scroll the remote tmux history unless VVTerm also owns a local representation of that history.

### Apple Platform Basis

UIKit's intended native scroll primitive is `UIScrollView`: content size, content offset, pan gesture ownership, delegate scroll callbacks, and deceleration rate. Sources:

- https://developer.apple.com/documentation/uikit/uiscrollview
- https://developer.apple.com/documentation/uikit/uiscrollview/pangesturerecognizer
- https://developer.apple.com/documentation/uikit/uiscrollviewdelegate/scrollviewdidscroll%28_%3A%29
- https://developer.apple.com/documentation/uikit/uiscrollview/decelerationrate-swift.struct

Using `UIScrollView` for host-owned scrollback aligns iOS with the platform instead of tuning a custom terminal pan loop.

## Product Goals

1. Make plain SSH terminal scrollback on iPhone and iPad feel native and inertial.
2. Preserve remote mouse behavior for tmux, vim, less, TUIs, and alternate screen apps.
3. Keep macOS behavior unchanged.
4. Keep Ghostty as the terminal engine and Metal renderer.
5. Avoid adding user-visible scroll mode settings in V1.
6. Keep the implementation measurable with instrumentation before and after the change.

## Non-Goals

- Do not rewrite Ghostty rendering.
- Do not replace the terminal with a `UITextView`.
- Do not make tmux/Mosh server-side history fully native in V1.
- Do not change generated tmux behavior in this change.
- Do not change SSH transport, terminal themes, keyboard toolbar behavior, or remote file features.
- Do not add a visible settings toggle; keep a hidden internal opt-out flag during rollout.

## Scroll Ownership Model

The important design decision is to route scroll by owner.

Proposed owner states:

```swift
enum TerminalScrollOwner: Equatable {
    case hostScrollback
    case remoteMouseApplication
    case selection
    case pinchZoom
}
```

Host scrollback means VVTerm/Ghostty owns the scrollback buffer. In this mode, native iOS scrolling should be active.

Remote mouse application means the remote terminal program owns the gesture. In this mode, the existing Ghostty mouse scroll path should remain active.

Selection and pinch zoom are temporary gesture states that should suppress host scrolling while active.

Initial routing policy:

```swift
struct TerminalScrollContext {
    var remoteScrollOwnerActive: Bool
    var hasHostScrollableRows: Bool
    var isSelecting: Bool
    var isPinching: Bool
}

func scrollOwner(for context: TerminalScrollContext) -> TerminalScrollOwner {
    if context.isSelecting { return .selection }
    if context.isPinching { return .pinchZoom }
    if context.remoteScrollOwnerActive { return .remoteMouseApplication }
    if !context.hasHostScrollableRows { return .remoteMouseApplication }
    return .hostScrollback
}
```

This first version intentionally keeps the routing input broader than just
`mouseCaptured`. The current app-side implementation can set
`remoteScrollOwnerActive` from Ghostty mouse capture today; a future Ghostty
state bridge can add alternate-screen ownership without changing the policy
surface.

Also require actual host-scrollable rows before claiming native scrolling. This
keeps alternate-screen programs that do not enable mouse reporting, but rely on
Ghostty's alternate-scroll cursor-key behavior, on the old terminal scroll path.
Without this guard, a `UIScrollView` with no useful host scrollback could steal
the gesture from `vim`, `less`, or similar TUIs.

## V1 Technical Design

### New iOS Native Scroll Container

Add an iOS-only wrapper in `VVTerm/GhosttyTerminal`, for example:

```text
VVTerm/GhosttyTerminal/TerminalNativeScrollContainerView+iOS.swift
```

Responsibility:

- Own a `UIScrollView`.
- Own the existing `GhosttyTerminalView`.
- Maintain virtual scroll content height from Ghostty scrollbar state.
- Translate native `contentOffset` changes into `scroll_to_row` actions.
- Route gestures according to `TerminalScrollOwner`.

The terminal view should stay viewport-sized. The scroll view should provide gesture physics and scroll indicators, not a giant rendered terminal surface.

Recommended hierarchy:

```text
TerminalNativeScrollContainerView
+-- UIScrollView
    +-- virtualContentView
    +-- GhosttyTerminalView
```

Because `GhosttyTerminalView` is inside the scroll view, the scroll view's pan recognizer can see touches. Because the terminal view should remain visually fixed, update the terminal view frame origin to match `contentOffset` during scroll:

```swift
terminalView.frame = CGRect(
    x: 0,
    y: scrollView.contentOffset.y,
    width: scrollView.bounds.width,
    height: scrollView.bounds.height
)
```

This keeps Metal rendering viewport-sized while allowing UIKit to own pan recognition and inertial deceleration.

### Scrollbar Synchronization

Listen for `.ghosttyDidUpdateScrollbar` where `object === terminalView`.
Also listen for terminal cell-size changes and refresh the virtual content
height, because font zoom and resize can change the row-to-pixel mapping even
when the scrollbar row counts stay the same.

Store the latest scrollbar:

```swift
var scrollbar: Ghostty.Action.Scrollbar?
```

Compute virtual height:

```swift
let gridHeight = CGFloat(scrollbar.total) * terminalView.cellSize.height
let visibleGridHeight = CGFloat(scrollbar.len) * terminalView.cellSize.height
let bottomPadding = max(scrollView.bounds.height - visibleGridHeight, 0)
let contentHeight = gridHeight + bottomPadding
scrollView.contentSize = CGSize(
    width: scrollView.bounds.width,
    height: max(scrollView.bounds.height, contentHeight)
)
```

The bottom padding matters when the viewport height is not an exact multiple of
the cell height. Without it, the native scroll view cannot map its bottom
offset back to Ghostty's last scrollable row.

When Ghostty scroll state changes while the user is not actively scrolling, synchronize UIKit:

```swift
let offsetY = CGFloat(scrollbar.offset) * terminalView.cellSize.height
scrollView.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
```

This is simpler than macOS because UIKit and terminal row coordinates are both top-origin for this purpose: row `0` means top of history.

### Native Scroll to Ghostty Row

In `scrollViewDidScroll(_:)`, route only when owner is `hostScrollback`.

```swift
let cellHeight = terminalView.cellSize.height
guard cellHeight > 0 else { return }

let row = Int(scrollView.contentOffset.y / cellHeight)
guard row != lastSentRow else { return }
lastSentRow = row

_ = terminalView.surface?.perform(action: "scroll_to_row:\(row)")
```

Clamp `row` to `0...(scrollbar.total - scrollbar.len)` when scrollbar state is available.

Do not call `terminalView.requestRender()` from the native scroll container after `scroll_to_row`. Ghostty already queues render for `scroll_to_row`. If profiling proves a missing frame, fix that at the Ghostty render scheduling boundary rather than forcing every scroll tick to mark layers manually.

### Fractional Pixel Follow

The first version should work without custom momentum. However, row-boundary redraw alone can still feel slightly stepped with large cell heights.

Add an optional fractional visual follow layer if testing shows visible stepping:

```swift
let exactRows = scrollView.contentOffset.y / cellHeight
let wholeRows = floor(exactRows)
let fractionalY = (exactRows - wholeRows) * cellHeight
```

Use `fractionalY` only as a temporary visual offset while UIKit is between terminal rows. Ghostty remains authoritative at whole rows.

Recommended rollout:

1. Implement row-boundary native scroll first.
2. Measure and screen-record.
3. Add fractional follow only if row stepping remains visible.

The fractional layer path is feasible but higher risk because `GhosttyTerminalView` is backed by IOSurface/Metal layers. It should be optional and isolated, not required for the first working version.

### Gesture Routing

The native container should be the gesture coordinator.

Rules:

- Host scrollback: `UIScrollView.panGestureRecognizer` owns vertical pan.
- Remote mouse app: existing `GhosttyTerminalView` pan-to-`MouseScrollEvent` path owns vertical pan.
- Selection: selection gestures win.
- Pinch zoom: pinch wins and suppresses scroll until it ends.
- Horizontal or multi-touch gestures should keep existing terminal behavior unless explicitly claimed by the scroll container.

This likely requires moving the current iOS pan scroll handling out of unconditional ownership. Keep the existing recognizer, but enable it only when the current owner is `remoteMouseApplication`.

### SwiftUI Integration

`SSHTerminalRepresentable` currently expects to create and update a `GhosttyTerminalView`.

For iOS, change the representable to return the native scroll container while still exposing the inner terminal view to existing coordinator logic.

Recommended shape:

```swift
final class TerminalNativeScrollContainerView: UIView {
    let terminalView: GhosttyTerminalView
}
```

Then update representable helpers to resolve the terminal view from either:

- the raw `GhosttyTerminalView`, or
- the `TerminalNativeScrollContainerView.terminalView`.

This avoids spreading wrapper awareness through unrelated session code.

### Feature Flag

Keep an internal opt-out flag:

```swift
UserDefaults.standard.object(forKey: "iosNativeTerminalScroll") as? Bool ?? true
```

Default: on for iOS, unavailable on macOS.

Remove the flag after one release if crash logs and manual QA are clean.

## V2: Remote History Overlay for tmux and Mosh

Do not solve tmux/Mosh smoothness by pretending wheel events are native local scroll.

For Mosh and tmux-integrated sessions, a future native-feeling history mode should be a local overlay:

1. Detect remote-history capable session.
2. When the user scrolls away from bottom, freeze live terminal presentation.
3. Populate a local scrollable history model from tmux, for example `capture-pane` or a control-mode stream.
4. Render history through a native scroll surface or a lightweight terminal text grid.
5. Exit overlay when the user returns to bottom or starts typing.

This is a larger feature because it needs history synchronization, invalidation, text selection semantics, and live-output reconciliation. It is feasible, but it is not the same task as making host Ghostty scrollback use `UIScrollView`.

## Verification Plan

### Unit Tests

Add pure tests for scroll geometry and routing. These should not require UIKit rendering.

Candidate pure type:

```swift
struct TerminalScrollGeometry {
    var totalRows: Int
    var visibleRows: Int
    var cellHeight: CGFloat

    func contentHeight(viewportHeight: CGFloat) -> CGFloat
    func row(forContentOffsetY offsetY: CGFloat) -> Int
    func contentOffsetY(forRow row: Int) -> CGFloat
}
```

Test cases:

- Empty or zero-height cell returns stable values.
- `offsetY = 0` maps to row `0`.
- Bottom offset clamps to `totalRows - visibleRows`.
- Fractional offset maps to expected whole row.
- Row-to-offset and offset-to-row round trip.
- `remoteScrollOwnerActive = true` routes to remote app even when host scrollback exists.
- no host-scrollable rows routes to remote app, preserving alternate-scroll cursor-key behavior.
- selection and pinch suppress host scrolling.

### Manual QA Matrix

Plain SSH:

- Run `seq 1 20000`.
- Scroll slowly, flick hard, reverse direction, and return to bottom.
- Expected: native iOS deceleration, stable scroll indicator, no lost frames that are worse than baseline.

tmux:

- Start VVTerm-managed tmux with mouse enabled.
- Scroll in shell history and inside copy mode.
- Expected: tmux behavior remains controlled by remote mouse/copy-mode bindings; no accidental host scroll hijack.

Alternate screen:

- Test `vim`, `less`, `top`, and a mouse-aware TUI.
- Expected: wheel/touch scroll goes to the remote app when mouse capture or alternate-scroll ownership is active; no accidental host scroll hijack.

Selection and pinch:

- Long-press select while keyboard is hidden.
- Pinch zoom if pane zoom is enabled.
- Expected: no scroll stealing during selection or pinch.

Keyboard:

- Show and hide the software keyboard.
- Scroll with keyboard visible and hidden.
- Expected: scroll does not unexpectedly force keyboard focus.

Performance:

- Capture before/after screen recordings on a 60 Hz device and a 120 Hz device.
- Add temporary signposts for scroll owner changes, `scrollViewDidScroll`, `scroll_to_row`, and render queue.
- Check that native host scroll no longer calls app-side `requestRender()` per scroll tick.

### Build Verification

Preferred command:

```sh
xcodebuild -scheme VVTerm -destination 'generic/platform=iOS' build
```

If signing or local Xcode setup blocks generic iOS builds, run the closest available simulator build and document the limitation in the implementation notes.

## Risks and Mitigations

### Risk: Remote Scroll Ownership Is Too Coarse

Mouse capture alone may not perfectly represent every alternate-screen or remote-owner case.

Mitigation:

- Use a broader `remoteScrollOwnerActive` policy input so the app can add a
  narrow Ghostty state bridge without changing scroll policy.
- Keep the hidden opt-out flag while the iOS build gate and manual TUI matrix
  are being exercised.
- Start conservative: if remote ownership is known, or if host scrollback
  cannot actually scroll, remote owns the gesture.

### Risk: `UIScrollView` and Terminal Gestures Conflict

The terminal view already owns taps, selection, keyboard focus, arrows, and pinch-related work.

Mitigation:

- Put all scroll arbitration in the container.
- Keep policy pure and tested.
- Disable only the old scroll pan path for host scrollback; do not disturb tap/key/selection code unnecessarily.

### Risk: Row-Boundary Updates Still Feel Stepped

Ghostty viewport scroll is row-based, while UIKit scroll is pixel-based.

Mitigation:

- Ship native physics and row-boundary sync first.
- Add fractional visual follow only if row stepping is visible in recordings.
- Keep fractional follow isolated and removable.

### Risk: Extra Rendering Work

The current path calls `requestRender()` from scroll gesture ticks. `scroll_to_row` already queues render.

Mitigation:

- Remove per-scroll forced layer invalidation from the host native path.
- Instrument render calls before changing broader renderer scheduling.

### Risk: tmux/Mosh Expectations

Users may expect Termius-like smoothness in tmux or Mosh sessions too.

Mitigation:

- Keep V1 scoped to host scrollback.
- Preserve tmux behavior exactly.
- Document V2 remote history overlay as the correct path for tmux/Mosh native-feeling scroll.

## Implementation Phases

### Phase 0: Instrument Baseline

Add temporary debug signposts or counters around:

- iOS scroll owner decision
- current `handlePanGesture(_:)`
- momentum start/end
- `scroll_to_row`
- `requestRender()`
- Ghostty scrollbar update handling

Outcome:

- Before/after evidence for scroll event volume and render scheduling.

### Phase 1: Pure Geometry and Policy

Add pure scroll geometry and owner-routing tests.

Outcome:

- The risky UIKit work has a tested mapping layer.

### Phase 2: Native Container With Opt-Out Flag

Add `TerminalNativeScrollContainerView+iOS.swift`.

Wire it into `SSHTerminalRepresentable` with the internal opt-out flag.

Outcome:

- Native host scroll can be tested without removing the old path.

### Phase 3: Host Scroll Ownership Cutover

Disable the old iOS pan-to-mouse-scroll path when owner is `hostScrollback`.

Keep it enabled when owner is `remoteMouseApplication`.

Outcome:

- Plain SSH uses native iOS scroll physics.
- tmux/TUI/mouse-captured sessions preserve remote input semantics.

### Phase 4: Measure Fractional Follow

Compare row-only sync against optional fractional visual follow.

Outcome:

- Decide whether fractional follow is worth shipping.

### Phase 5: Remove Opt-Out Flag

After manual QA:

- Remove the opt-out flag if crash logs and manual QA are clean, or
- keep the opt-out flag while tightening the scroll ownership bridge.

## Open Decisions

1. Should V1 ship row-boundary native scroll only, or include fractional visual follow?
2. When should the internal opt-out flag be removed for TestFlight or release?
3. Which Ghostty state bridge should populate `remoteScrollOwnerActive` beyond mouse capture?
4. Should V2 remote history overlay target tmux first, Mosh first, or only VVTerm-managed tmux sessions first?

## Recommended Decision

Proceed with V1 native host scrollback.

The implementation is practical and contained because it reuses Ghostty scrollbar state, `scroll_to_row`, and the macOS scroll architecture. It should be designed as an iOS `UIScrollView` wrapper with explicit scroll ownership, not as a tweak to current custom momentum constants.

Defer tmux/Mosh smooth remote history to a separate V2 overlay design. That path is feasible too, but it needs a synchronized local history model and should not block the V1 host-scrollback improvement.
