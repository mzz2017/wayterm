
## Design

### Part 1 — zmx as a multiplexer backend

**Domain: replace boolean tmux toggle with a multiplexer kind.**

New `Features/TerminalSessions/Domain/TerminalMultiplexer.swift`:

```swift
enum TerminalMultiplexer: String, Codable, CaseIterable, Identifiable {
    case none, tmux, zmx
    var id: String { rawValue }
    var displayName: String { ... }   // "Off" / "tmux" / "zmx"
    var isEnabled: Bool { self != .none }
}
```

`Server` changes (direct cutover with decode migration):
- Replace `tmuxEnabledOverride: Bool?` with `multiplexerOverride: TerminalMultiplexer?` (nil = use global default).
- `init(from:)`: decode `multiplexerOverride` if present; else migrate legacy `tmuxEnabledOverride` (`true → .tmux`, `false → .none`). Keep `tmuxStartupBehaviorOverride` as-is (applies to both tmux and zmx; for zmx, `watermManaged`/`askEveryTime`/`skipTmux` map to managed-attach / pick-from-`zmx ls` / plain shell).
- `Server+CloudKit.swift`: read `multiplexerOverride` string, with the same legacy fallback from `tmuxEnabledOverride`; write the new field; stop writing the old one.

Global default: new UserDefaults key `terminalMultiplexerDefault` (String raw of `TerminalMultiplexer`), default `.tmux`. Migration helper reads legacy `terminalTmuxEnabledDefault` once if the new key is absent.

**Runtime backend: add zmx, delegate to an isolated builder.**

`RemoteTmuxBackend` gains `case zmx(commandName: String)` (the resolved `zmx`/path). Rationale: keep the existing enum as the single backend type so `TmuxAttachResolver`/`TerminalTabManager` keep passing `backend` through untouched.

New `Core/SSH/RemoteZmxCommandBuilder.swift` (~80 lines) owns zmx's command set, so zmx logic is NOT smeared across the 1000-line tmux/Windows builder:
- `availabilityProbeCommand(okMarker:)` → `sh -c '... command -v zmx ... zmx version ...'`
- `attachCommand(sessionName:context:)` → `exec zmx attach <name>` (startup-exec) or `sh -lc 'exec zmx attach <name>'` (interactive). No `-c workdir` (zmx has no cwd flag; rely on login shell + optional `cd`).
- `listSessionsCommand()` → `sh -lc 'zmx ls --short'`; parse = one name per line.
- `killSessionCommand(named:)` → `sh -lc 'zmx kill <name> --force'`.
- No config write, no install script.

`RemoteTmuxManager` routes the `.zmx` case of each public method (`tmuxBackend`, `attachCommand`, `attachExecCommand`, `listSessions`, `killSession`, `prepareConfig` no-op, `installAndAttachScript` → plain attach) to `RemoteZmxCommandBuilder`. Detection order in `tmuxBackend(using:)`: respect the server's selected multiplexer — if `.zmx`, probe zmx; if `.tmux`, probe tmux; choosing happens above in the resolver via the multiplexer kind, so `tmuxBackend` gains a `preferred: TerminalMultiplexer` parameter (default `.tmux` to preserve existing call sites until updated).

**Resolver / lifecycle wiring.**
- `TmuxAttachResolver`: rename `isTmuxEnabled(for:)` → `multiplexer(for:)` returning `TerminalMultiplexer` (reads `Server.multiplexerOverride` ?? global default). `managedSessionName` unchanged (works for both). `listSessions` for zmx filters internal `waterm_*` names same as tmux.
- `TerminalTabManager.tmuxStartupPlan` / `handleTmuxLifecycle` and `ConnectionSessionManager` equivalents: resolve the multiplexer kind, fetch the matching backend, and otherwise reuse the existing flow (selection → attach command → send).

**UI.**
- `ServerFormSheet.sessionSection`: replace the tmux `Toggle` with a `Picker` over `TerminalMultiplexer` (Off / tmux / zmx); show the startup-behavior picker when not `.none`.
- `TerminalSettingsView`: global default becomes a `TerminalMultiplexer` picker; copy generalized from "tmux" to "session persistence".
- `TmuxStatus` strings stay; labels generalized where they say "tmux" to "session".

### Part 2 — bind connection ↔ session id (auto-reattach)

New `Features/TerminalSessions/Application/TmuxSessionBindingStore.swift`:

```swift
struct TmuxSessionBinding: Codable {
    var sessionName: String
    var ownership: String      // "managed" | "external"
    var multiplexer: String    // TerminalMultiplexer.rawValue
}
final class TmuxSessionBindingStore {
    // UserDefaults key "tmuxSessionBindings.v1": [String /*entityId*/ : TmuxSessionBinding]
    func binding(for entityId: UUID) -> TmuxSessionBinding?
    func set(_ binding: TmuxSessionBinding, for entityId: UUID)
    func remove(for entityId: UUID)
}
```

`TmuxAttachResolver`:
- Owns a `TmuxSessionBindingStore`. On init, hydrate `sessionNames`/`sessionOwnership` from the store.
- `updateAttachmentState` also writes the binding (name + ownership + the active multiplexer kind).
- `clearAttachmentState` also removes the binding.
- `resolveSelection` already reuses `sessionNames[entityId]`; with hydration this now survives app kill → external (`askEveryTime`-chosen) sessions auto-reattach, never re-prompting a bound pane. Managed sessions already deterministic; binding makes ownership explicit post-restart.

This is keyed by the stable pane/session UUID (already persisted in both managers' snapshots), so no snapshot-struct changes are required — the store is the single source of truth for bindings, shared by both `TmuxAttachResolver` instances.

### Part 3 — SSH key auth fix

**3a. Stop the retry storm (primary cause of the penalty).**
`SSHError` gains:
```swift
var isRetryable: Bool {
    switch self {
    case .authenticationFailed, .hostKeyVerificationFailed,
         .tailscaleAuthenticationNotAccepted: return false
    default: return true
    }
}
```
`SSHConnectionRunner.run()`: in the `catch`, if `error as? SSHError` is non-retryable, `break` out of the attempt loop (go straight to `onFailure`) instead of `continue`. Transient errors (timeout, socket, channel) still retry with backoff.

**3b. Always have a correct public key (correctness cause).**
New `Core/SSH/SSHPublicKeyDeriver.swift`:
- `publicKey(fromPrivateKeyPEM:passphrase:) -> String?`
- OpenSSH `-----BEGIN OPENSSH PRIVATE KEY-----`: base64-decode the blob, parse the embedded public key section (works for ed25519 and rsa) → emit `ssh-ed25519 …` / `ssh-rsa …`.
- PKCS#1 `-----BEGIN RSA PRIVATE KEY-----`: import via `SecKeyCreateWithData` (RSA private), `SecKeyCopyPublicKey`, reuse `SSHKeyGenerator`'s `ssh-rsa` formatter (extract that formatter into a shared helper).
- Returns nil on unknown/encrypted-unsupported formats (caller then falls back to libssh2 deriving it).

Wire-in (compute pubkey at every save point; never store nil when derivable):
- `KeychainSettingsView.saveKey()` (import): derive pubkey from `keyContent` before `storeSSHKeyEntry`, pass `publicKey:`.
- `ServerFormSheet.saveServer()` / `buildCredentials`: if `sshPublicKey` empty, derive from `sshKey` before storing.
- `GenerateSSHKeySheet`: already has the pubkey — ensure it's passed through (verify).

**3c. Reduce auth failures per connection (hardening).**
`SSHClient.authenticate()` password branch: only attempt keyboard-interactive fallback if `authList` (from `libssh2_userauth_list`) contains `"keyboard-interactive"`. Avoids a guaranteed second failure per connection when the server doesn't offer it.

## Testing / verification

No Swift toolchain locally → verification is build-and-run in Xcode by the user:
- zmx: server set to zmx connects, attaches, survives reconnect, lists via `zmx ls`.
- Binding: choose an external session under "ask every time", kill app, reopen → auto-reattaches without prompt.
- SSH: a wrong key fails once (no 3× penalty); imported key (no pubkey) now authenticates; check sshd no longer logs the penalty.
Where pure-logic units exist (pubkey derivation, session-list parsing, isRetryable), add Swift unit tests so they run in CI/Xcode even though they can't run here.

## Out of scope

- zmx windows/splits (zmx has none; Waterm's own split UI is unaffected).
- Auto-installing zmx remotely (assume present; absent → plain shell).
- Reworking the 1060-line tmux builder into a protocol (deferred; delegation keeps blast radius small).

## File-level change summary

New:
- `Features/TerminalSessions/Domain/TerminalMultiplexer.swift`
- `Core/SSH/RemoteZmxCommandBuilder.swift`
- `Features/TerminalSessions/Application/TmuxSessionBindingStore.swift`
- `Core/SSH/SSHPublicKeyDeriver.swift`

Edited:
- `Features/Servers/Domain/Server.swift` (+ `Server+CloudKit.swift`)
- `Core/SSH/RemoteTmuxManager.swift` (route `.zmx`, add `preferred` param)
- `Features/TerminalSessions/Application/TmuxAttachResolver.swift` (multiplexer kind + binding store)
- `Features/TerminalSessions/Application/TerminalTabManager.swift` + `ConnectionSessionManager.swift` (resolve kind)
- `Features/Servers/UI/ServerDetail/ServerFormSheet.swift`, `Features/Settings/UI/TerminalSettingsView.swift` (pickers)
- `Core/SSH/SSHClient.swift` (`isRetryable`, kbd-interactive guard)
- `Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift` (break on non-retryable)
- `Features/Settings/UI/KeychainSettingsView.swift` (derive pubkey on import)
