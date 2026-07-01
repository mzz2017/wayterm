# iOS Shell Linux Testing Boundary

Waterm's iOS shell still requires Xcode, Apple SDKs, and an iOS simulator or device for platform validation. The Linux SwiftPM package is intentionally limited to Foundation-only decision logic extracted from `Waterm/App/iOS`.

## Linux-Covered Logic

Run:

```bash
swift test
```

This covers:

- root terminal navigation context and dismissal decisions
- preferred connection view selection and hidden-tab fallback
- server list filtering, active connection grouping, and environment counts
- remote file tab base titles and duplicate title numbering
- terminal selected-session fallback, prepare/refresh decisions, foreground reconnect decisions, and recovered-state decisions
- workspace deletion warning text from the iOS workspace picker

The SwiftPM target uses lightweight snapshots at the iOS shell boundary. It does not depend on SwiftUI, UIKit, StoreKit, CloudKit, Keychain, ActivityKit, Ghostty, Metal, or SSH transport code.

## Still Requires macOS/Xcode

Validate these with Xcode on macOS:

- iOS and macOS app target compilation
- SwiftUI navigation stacks, sheets, toolbars, menus, swipe actions, and layout
- UIKit bridges such as `UISegmentedControl`, keyboard focus, haptics, and device idiom checks
- StoreKit review/pro upgrade presentation
- CloudKit, Keychain, entitlements, Live Activity, local network permissions, and app lifecycle behavior
- Ghostty/Metal terminal rendering, SSH reconnect side effects, and simulator/device UI tests
