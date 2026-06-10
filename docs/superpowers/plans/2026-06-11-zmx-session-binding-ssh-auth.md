# zmx Support, Session Binding, and SSH Key Auth Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add zmx as a session-persistence backend alongside tmux, persist connection↔session bindings for auto-reattach, and fix the SSH key auth failure that triggers sshd penalties.

**Architecture:** Introduce a `TerminalMultiplexer` domain kind (none/tmux/zmx) threaded from `Server` through the attach resolver to an isolated zmx command builder, so zmx logic never smears across the 1060-line tmux builder. Persist session bindings in a dedicated store hydrated into the resolver. Fix SSH auth by not retrying non-retryable errors and by always storing a derived public key.

**Tech Stack:** Swift, SwiftUI, libssh2 1.11.0, CryptoKit/Security, CloudKit, UserDefaults, Swift `Testing` framework (`VVTermTests` target).

**Environment note:** The dev box has NO Swift/Xcode toolchain. "Run the test" steps are executed by the user in Xcode (⌘U) — the plan marks them `[Xcode]`. Implementer must keep edits surgical and review-ready. Commits are atomic per `CLAUDE.md`.

**Branch:** `feat/zmx-session-binding-ssh-auth` (already created; spec committed).

---

## Phase ordering

1. **SSH auth fix** (Tasks 1–4) — highest-value bug, lowest risk, independent of the rest.
2. **zmx backend** (Tasks 5–10) — domain kind, command builder, routing, UI.
3. **Session binding persistence** (Tasks 11–13) — depends on the multiplexer kind from Phase 2.

Each phase produces working, testable software on its own.

---

## Phase 1 — SSH Key Auth Fix

### Task 1: `SSHError.isRetryable`

**Files:**
- Modify: `VVTerm/Core/SSH/SSHClient.swift` (the `enum SSHError` near line 2814)
- Test: `VVTermTests/SSHErrorRetryableTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `VVTermTests/SSHErrorRetryableTests.swift`:

```swift
import Testing
@testable import VVTerm

struct SSHErrorRetryableTests {
    @Test func authenticationFailedIsNotRetryable() {
        #expect(SSHError.authenticationFailed.isRetryable == false)
    }

    @Test func hostKeyVerificationFailedIsNotRetryable() {
        #expect(SSHError.hostKeyVerificationFailed.isRetryable == false)
    }

    @Test func tailscaleAuthNotAcceptedIsNotRetryable() {
        #expect(SSHError.tailscaleAuthenticationNotAccepted.isRetryable == false)
    }

    @Test func timeoutIsRetryable() {
        #expect(SSHError.timeout.isRetryable == true)
    }

    @Test func socketErrorIsRetryable() {
        #expect(SSHError.socketError("boom").isRetryable == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** `[Xcode]`

Run in Xcode (⌘U) or `xcodebuild test ... -only-testing:VVTermTests/SSHErrorRetryableTests`.
Expected: FAIL — `value of type 'SSHError' has no member 'isRetryable'`.

- [ ] **Step 3: Add `isRetryable` to `SSHError`**

In `SSHClient.swift`, inside `enum SSHError`, after `errorDescription`'s closing brace (before the enum's closing `}` near line 2860), add:

```swift
    /// Whether a connection attempt that failed with this error should be retried.
    /// Auth/host-key/tailscale failures are deterministic — retrying only piles up
    /// failed-auth events and triggers sshd penalty boxing.
    var isRetryable: Bool {
        switch self {
        case .authenticationFailed,
             .hostKeyVerificationFailed,
             .tailscaleAuthenticationNotAccepted:
            return false
        default:
            return true
        }
    }
```

- [ ] **Step 4: Run test to verify it passes** `[Xcode]`

Expected: PASS (all 5 cases).

- [ ] **Step 5: Commit**

```bash
git add VVTerm/Core/SSH/SSHClient.swift VVTermTests/SSHErrorRetryableTests.swift
git commit -m "feat(ssh): add SSHError.isRetryable to classify non-retryable failures"
```

---

### Task 2: Stop retrying non-retryable errors in the connection runner

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift:77-95`

- [ ] **Step 1: Make the retry loop honor `isRetryable`**

In `SSHConnectionRunner.run()`, the `catch` block currently always `continue`s when `attempt < maxAttempts`. Replace the existing `catch` body (lines ~77-95) with:

```swift
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error
                logger.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                // Do not retry deterministic failures (bad auth, host-key mismatch):
                // repeated failed auths trip sshd's penalty system.
                if let sshError = error as? SSHError, !sshError.isRetryable {
                    logger.warning("Non-retryable SSH error; aborting retries")
                    break
                }

                if attempt < maxAttempts, let sshError = error as? SSHError {
                    let shouldReset = await shouldResetClient(sshError)
                    if shouldReset {
                        logger.warning("Resetting SSH client before retrying connection")
                        await sshClient.disconnect()
                    }
                }

                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
```

- [ ] **Step 2: Verify behavior by reading** `[Xcode build]`

Build the app (⌘B). Expected: compiles. Manual check deferred to Task 4 verification. A wrong-key connection should now produce exactly ONE auth attempt instead of three.

- [ ] **Step 3: Commit**

```bash
git add VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift
git commit -m "fix(ssh): stop retrying non-retryable auth failures to avoid sshd penalty"
```

---

### Task 3: Public-key derivation from a private key

**Files:**
- Create: `VVTerm/Core/SSH/SSHPublicKeyDeriver.swift`
- Modify: `VVTerm/Core/SSH/SSHKeyGenerator.swift` (expose an RSA pubkey formatter)
- Test: `VVTermTests/SSHPublicKeyDeriverTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `VVTermTests/SSHPublicKeyDeriverTests.swift`:

```swift
import Testing
import Foundation
@testable import VVTerm

struct SSHPublicKeyDeriverTests {
    @Test func derivesEd25519PublicKeyMatchingGenerator() throws {
        let key = try SSHKeyGenerator.generate(type: .ed25519, comment: "test@vvterm")
        let pem = String(data: key.privateKey, encoding: .utf8)!
        let derived = SSHPublicKeyDeriver.publicKey(fromPrivateKeyPEM: pem)
        let gen = key.publicKey.split(separator: " ")
        let der = (derived ?? "").split(separator: " ")
        #expect(der.count >= 2)
        #expect(der.first == gen.first)          // "ssh-ed25519"
        #expect(der.dropFirst().first == gen.dropFirst().first)  // same base64 body
    }

    @Test func derivesRSAPublicKeyMatchingGenerator() throws {
        let key = try SSHKeyGenerator.generate(type: .rsa4096, comment: "")
        let pem = String(data: key.privateKey, encoding: .utf8)!
        let derived = SSHPublicKeyDeriver.publicKey(fromPrivateKeyPEM: pem)
        let gen = key.publicKey.split(separator: " ")
        let der = (derived ?? "").split(separator: " ")
        #expect(der.count >= 2)
        #expect(der.first == gen.first)          // "ssh-rsa"
        #expect(der.dropFirst().first == gen.dropFirst().first)
    }

    @Test func returnsNilForGarbage() {
        #expect(SSHPublicKeyDeriver.publicKey(fromPrivateKeyPEM: "not a key") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** `[Xcode]`

Expected: FAIL — `cannot find 'SSHPublicKeyDeriver' in scope`.

- [ ] **Step 3: Expose an RSA pubkey formatter on `SSHKeyGenerator`**

In `SSHKeyGenerator.swift`, just before the final closing `}` of `enum SSHKeyGenerator` (after `wrapBase64`), add:

```swift
    /// Public: format an `ssh-rsa ...` one-line public key from a SecKey (RSA public key).
    static func sshRSAPublicKeyString(from publicKey: SecKey) -> String? {
        try? formatRSAPublicKey(publicKey, comment: "")
    }
```

- [ ] **Step 4: Create the deriver**

Create `VVTerm/Core/SSH/SSHPublicKeyDeriver.swift`:

```swift
import Foundation
import Security

/// Derives the OpenSSH one-line public key ("ssh-ed25519 AAAA..." / "ssh-rsa AAAA...")
/// from a PEM private key, so we can persist a correct public key alongside imported
/// keys (libssh2's nil-public-key derivation is unreliable across key formats).
enum SSHPublicKeyDeriver {
    static func publicKey(fromPrivateKeyPEM pem: String, passphrase: String? = nil) -> String? {
        if pem.contains("BEGIN OPENSSH PRIVATE KEY") {
            return publicKeyFromOpenSSH(pem)
        }
        if pem.contains("BEGIN RSA PRIVATE KEY") {
            return publicKeyFromPKCS1RSA(pem)
        }
        return nil
    }

    // MARK: - OpenSSH format

    /// openssh-key-v1 layout: magic "\0", cipher, kdfname, kdfoptions, uint32 numkeys,
    /// string publickey-blob, string private-section. The publickey-blob is exactly the
    /// wire encoding we base64 after the algorithm name.
    private static func publicKeyFromOpenSSH(_ pem: String) -> String? {
        guard let blob = base64Body(of: pem) else { return nil }
        let bytes = [UInt8](blob)
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard bytes.count > magic.count, Array(bytes.prefix(magic.count)) == magic else { return nil }
        var offset = magic.count
        guard skipString(bytes, &offset),          // cipher
              skipString(bytes, &offset),          // kdfname
              skipString(bytes, &offset),          // kdfoptions
              readUInt32(bytes, &offset) != nil,   // numkeys
              let pubBlob = readString(bytes, &offset) else { return nil }

        let pub = [UInt8](pubBlob)
        var pubOffset = 0
        guard let typeData = readString(pub, &pubOffset),
              let type = String(data: typeData, encoding: .utf8) else { return nil }
        return "\(type) \(pubBlob.base64EncodedString())"
    }

    // MARK: - PKCS#1 RSA PEM

    private static func publicKeyFromPKCS1RSA(_ pem: String) -> String? {
        guard let der = base64Body(of: pem) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error),
              let pubKey = SecKeyCopyPublicKey(privKey) else { return nil }
        return SSHKeyGenerator.sshRSAPublicKeyString(from: pubKey)
    }

    // MARK: - Helpers

    private static func base64Body(of pem: String) -> Data? {
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: body)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: inout Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        let v = UInt32(bytes[offset]) << 24
              | UInt32(bytes[offset + 1]) << 16
              | UInt32(bytes[offset + 2]) << 8
              | UInt32(bytes[offset + 3])
        offset += 4
        return v
    }

    private static func readString(_ bytes: [UInt8], _ offset: inout Int) -> Data? {
        guard let len = readUInt32(bytes, &offset) else { return nil }
        let n = Int(len)
        guard offset + n <= bytes.count else { return nil }
        let d = Data(bytes[offset..<(offset + n)])
        offset += n
        return d
    }

    private static func skipString(_ bytes: [UInt8], _ offset: inout Int) -> Bool {
        guard let len = readUInt32(bytes, &offset) else { return false }
        let n = Int(len)
        guard offset + n <= bytes.count else { return false }
        offset += n
        return true
    }
}
```

- [ ] **Step 5: Add both new files to the Xcode project** `[Xcode]`

`SSHPublicKeyDeriver.swift` must be added to the `VVTerm` target and `SSHPublicKeyDeriverTests.swift` to the `VVTermTests` target (Xcode: drag into the matching group, or it auto-detects with the file-system-synchronized group if the project uses one — verify target membership).

- [ ] **Step 6: Run tests to verify they pass** `[Xcode]`

Expected: PASS (ed25519 round-trip, rsa round-trip, garbage→nil).

- [ ] **Step 7: Commit**

```bash
git add VVTerm/Core/SSH/SSHPublicKeyDeriver.swift VVTerm/Core/SSH/SSHKeyGenerator.swift VVTermTests/SSHPublicKeyDeriverTests.swift
git commit -m "feat(ssh): derive OpenSSH public key from private key (ed25519, rsa)"
```

---

### Task 4: Store derived public key on import + guard keyboard-interactive

**Files:**
- Modify: `VVTerm/Features/Settings/UI/KeychainSettingsView.swift:414-436` (`saveKey`)
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift:1175-1190` (`saveServer` store paths) and `:1045-1060` (`buildCredentials`)
- Modify: `VVTerm/Core/SSH/SSHClient.swift:1105-1118` (password fallback)

- [ ] **Step 1: Derive + store public key when importing a key**

In `KeychainSettingsView.saveKey()`, replace the `storeSSHKeyEntry` call (around line 425) with one that derives and passes the public key:

```swift
        do {
            let derivedPublicKey = SSHPublicKeyDeriver.publicKey(
                fromPrivateKeyPEM: keyContent,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            let entry = try KeychainManager.shared.storeSSHKeyEntry(
                name: name,
                privateKey: keyData,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                publicKey: derivedPublicKey
            )
            onSave(entry)
            dismiss()
        } catch {
            self.error = String(format: String(localized: "Failed to save key: %@"), error.localizedDescription)
            isSaving = false
        }
```

- [ ] **Step 2: Derive public key when saving a server if not already present**

In `ServerFormSheet.saveServer()`, replace the single `let publicKeyData = sshPublicKey.isEmpty ? nil : sshPublicKey.data(using: .utf8)` line (≈1175) with:

```swift
                    let resolvedPublicKey: String? = {
                        if !sshPublicKey.isEmpty { return sshPublicKey }
                        guard !sshKey.isEmpty else { return nil }
                        return SSHPublicKeyDeriver.publicKey(
                            fromPrivateKeyPEM: sshKey,
                            passphrase: sshPassphrase.isEmpty ? nil : sshPassphrase
                        )
                    }()
                    let publicKeyData = resolvedPublicKey?.data(using: .utf8)
```

In `buildCredentials(for:)` (≈1045-1060), apply the same fallback before assigning `credentials.publicKey` so the very first (`addServer`) connection also has it:

```swift
        if !sshPublicKey.isEmpty {
            credentials.publicKey = sshPublicKey.data(using: .utf8)
        } else if !sshKey.isEmpty,
                  let derived = SSHPublicKeyDeriver.publicKey(
                      fromPrivateKeyPEM: sshKey,
                      passphrase: sshPassphrase.isEmpty ? nil : sshPassphrase) {
            credentials.publicKey = derived.data(using: .utf8)
        }
```

(Place inside the `.sshKey` / `.sshKeyWithPassphrase` branches where `credentials.publicKey` is currently set from `sshPublicKey`.)

- [ ] **Step 3: Only try keyboard-interactive when advertised**

In `SSHClient.authenticate()`, the password branch falls back to keyboard-interactive unconditionally. Capture the advertised methods and gate the fallback. Replace the fallback block (lines ≈1105-1118) with:

```swift
            // If password auth fails, try keyboard-interactive ONLY if the server lists it.
            if authResult != 0 {
                let advertisesKbdInteractive = authList
                    .map { String(cString: $0).contains("keyboard-interactive") } ?? true
                if advertisesKbdInteractive {
                    logger.info("Password auth failed, trying keyboard-interactive...")
                    keyboardInteractiveContext.setPassword(password)
                    defer { keyboardInteractiveContext.setPassword(nil) }
                    authResult = libssh2_userauth_keyboard_interactive_ex(
                        session,
                        username,
                        UInt32(username.utf8.count),
                        kbdintCallback
                    )
                }
            }
```

(`authList` is the `let authList = libssh2_userauth_list(...)` already computed at the top of `authenticate()`.)

- [ ] **Step 4: Build** `[Xcode]`

Build the app (⌘B). Expected: compiles.

- [ ] **Step 5: Commit**

```bash
git add VVTerm/Features/Settings/UI/KeychainSettingsView.swift VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift VVTerm/Core/SSH/SSHClient.swift
git commit -m "fix(ssh): store derived public key for imported keys; gate keyboard-interactive"
```

- [ ] **Step 6: Manual verification** `[Xcode + device/sim]`

1. Import a private key (no public key) → add a server using it → connect. Expected: authenticates; sshd shows no `penalty: failed authentication`.
2. Configure a server with a deliberately wrong key → connect. Expected: exactly one failed auth, single error, no 3× retry storm.

---

## Phase 2 — zmx Backend

### Task 5: `TerminalMultiplexer` domain type + migration helper

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Domain/TerminalMultiplexer.swift`
- Test: `VVTermTests/TerminalMultiplexerTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `VVTermTests/TerminalMultiplexerTests.swift`:

```swift
import Testing
@testable import VVTerm

struct TerminalMultiplexerTests {
    @Test func legacyTrueMapsToTmux() {
        #expect(TerminalMultiplexer.fromLegacyTmuxEnabled(true) == .tmux)
    }

    @Test func legacyFalseMapsToNone() {
        #expect(TerminalMultiplexer.fromLegacyTmuxEnabled(false) == .none)
    }

    @Test func isEnabledReflectsKind() {
        #expect(TerminalMultiplexer.none.isEnabled == false)
        #expect(TerminalMultiplexer.tmux.isEnabled == true)
        #expect(TerminalMultiplexer.zmx.isEnabled == true)
    }

    @Test func roundTripsRawValue() {
        for m in TerminalMultiplexer.allCases {
            #expect(TerminalMultiplexer(rawValue: m.rawValue) == m)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails** `[Xcode]`

Expected: FAIL — `cannot find 'TerminalMultiplexer' in scope`.

- [ ] **Step 3: Create the type**

Create `VVTerm/Features/TerminalSessions/Domain/TerminalMultiplexer.swift`:

```swift
import Foundation

/// Which terminal multiplexer a connection uses for session persistence.
enum TerminalMultiplexer: String, Codable, CaseIterable, Identifiable {
    case none
    case tmux
    case zmx

    var id: String { rawValue }

    var isEnabled: Bool { self != .none }

    var displayName: String {
        switch self {
        case .none: return String(localized: "Off")
        case .tmux: return String(localized: "tmux")
        case .zmx:  return String(localized: "zmx")
        }
    }

    var descriptionText: String {
        switch self {
        case .none: return String(localized: "Start a normal shell without session persistence.")
        case .tmux: return String(localized: "Use tmux to keep sessions alive across disconnects.")
        case .zmx:  return String(localized: "Use zmx (lightweight) to keep sessions alive across disconnects.")
        }
    }

    /// Migration from the old boolean `tmuxEnabledOverride` / `terminalTmuxEnabledDefault`.
    static func fromLegacyTmuxEnabled(_ enabled: Bool) -> TerminalMultiplexer {
        enabled ? .tmux : .none
    }
}
```

- [ ] **Step 4: Run test to verify it passes** `[Xcode]`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Domain/TerminalMultiplexer.swift VVTermTests/TerminalMultiplexerTests.swift
git commit -m "feat(sessions): add TerminalMultiplexer domain kind (none/tmux/zmx)"
```

---

### Task 6: Migrate `Server.tmuxEnabledOverride` → `multiplexerOverride`

**Files:**
- Modify: `VVTerm/Features/Servers/Domain/Server.swift`
- Modify: `VVTerm/Features/Servers/Domain/Server+CloudKit.swift`
- Test: `VVTermTests/ServerMultiplexerMigrationTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `VVTermTests/ServerMultiplexerMigrationTests.swift`:

```swift
import Testing
import Foundation
@testable import VVTerm

struct ServerMultiplexerMigrationTests {
    private func decode(_ json: String) throws -> Server {
        try JSONDecoder().decode(Server.self, from: Data(json.utf8))
    }

    private let base = """
    "id":"\(UUID().uuidString)","workspaceId":"\(UUID().uuidString)",
    "name":"s","host":"h","port":22,"username":"u","authMethod":"password",
    "tags":[],"isFavorite":false,"requiresBiometricUnlock":false,
    "createdAt":0,"updatedAt":0
    """

    @Test func decodesNewMultiplexerField() throws {
        let s = try decode("{\(base),\"multiplexerOverride\":\"zmx\"}")
        #expect(s.multiplexerOverride == .zmx)
    }

    @Test func migratesLegacyTmuxEnabledTrue() throws {
        let s = try decode("{\(base),\"tmuxEnabledOverride\":true}")
        #expect(s.multiplexerOverride == .tmux)
    }

    @Test func migratesLegacyTmuxEnabledFalse() throws {
        let s = try decode("{\(base),\"tmuxEnabledOverride\":false}")
        #expect(s.multiplexerOverride == TerminalMultiplexer.none)
    }

    @Test func nilWhenNeitherPresent() throws {
        let s = try decode("{\(base)}")
        #expect(s.multiplexerOverride == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** `[Xcode]`

Expected: FAIL — `value of type 'Server' has no member 'multiplexerOverride'`.

- [ ] **Step 3: Replace the field in `Server`**

In `Server.swift`:

1. Replace the stored property (line 24):
```swift
    /// Override for session multiplexer (nil = use global default)
    var multiplexerOverride: TerminalMultiplexer?
```
(delete `var tmuxEnabledOverride: Bool?`)

2. In `init(...)` replace the `tmuxEnabledOverride: Bool? = nil` parameter and its assignment with `multiplexerOverride: TerminalMultiplexer? = nil` / `self.multiplexerOverride = multiplexerOverride`.

3. In `CodingKeys`, replace `case tmuxEnabledOverride` with:
```swift
        case multiplexerOverride
        case tmuxEnabledOverride   // legacy, decode-only
```

4. In `init(from:)` replace the `tmuxEnabledOverride` decode (line 130) with:
```swift
        if let mux = try container.decodeIfPresent(String.self, forKey: .multiplexerOverride) {
            multiplexerOverride = TerminalMultiplexer(rawValue: mux)
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .tmuxEnabledOverride) {
            multiplexerOverride = .fromLegacyTmuxEnabled(legacy)
        } else {
            multiplexerOverride = nil
        }
```

5. In `encode(to:)` replace the `tmuxEnabledOverride` encode (line 159) with:
```swift
        try container.encodeIfPresent(multiplexerOverride?.rawValue, forKey: .multiplexerOverride)
```

- [ ] **Step 4: Update CloudKit mapping**

In `Server+CloudKit.swift`:

1. In `init?(from record:)` replace the `tmuxEnabledOverride` read (line 86) with:
```swift
        if let mux = record["multiplexerOverride"] as? String {
            self.multiplexerOverride = TerminalMultiplexer(rawValue: mux)
        } else if let legacy = record["tmuxEnabledOverride"] as? Bool {
            self.multiplexerOverride = .fromLegacyTmuxEnabled(legacy)
        } else {
            self.multiplexerOverride = nil
        }
```

2. In `toRecord(...)` replace the `record["tmuxEnabledOverride"] = tmuxEnabledOverride` line (line 142) with:
```swift
        record["multiplexerOverride"] = multiplexerOverride?.rawValue
```

- [ ] **Step 5: Fix remaining compile references** `[Xcode]`

Build (⌘B). Fix any other references to `tmuxEnabledOverride` the compiler flags (notably `ServerFormSheet` state load/save, handled fully in Task 9). For now, in any non-UI reference, read the kind via `server.multiplexerOverride?.isEnabled`.

- [ ] **Step 6: Run migration tests** `[Xcode]`

Expected: PASS (4 cases).

- [ ] **Step 7: Commit**

```bash
git add VVTerm/Features/Servers/Domain/Server.swift VVTerm/Features/Servers/Domain/Server+CloudKit.swift VVTermTests/ServerMultiplexerMigrationTests.swift
git commit -m "feat(servers): migrate tmuxEnabledOverride to multiplexerOverride"
```

---

### Task 7: `RemoteZmxCommandBuilder` (isolated zmx command set)

**Files:**
- Create: `VVTerm/Core/SSH/RemoteZmxCommandBuilder.swift`
- Test: `VVTermTests/RemoteZmxCommandBuilderTests.swift` (create)

zmx is POSIX-only and far simpler than tmux: `zmx attach <name>` create-or-attaches a login shell, no config file, no `has-session`, no windows. Keep all of that here so the 1060-line tmux builder stays tmux-only.

- [ ] **Step 1: Write the failing test**

Create `VVTermTests/RemoteZmxCommandBuilderTests.swift`:

```swift
import Testing
@testable import VVTerm

struct RemoteZmxCommandBuilderTests {
    let b = RemoteZmxCommandBuilder()

    @Test func attachStartupExecsZmx() {
        let cmd = b.attachCommand(sessionName: "vvterm_dev", context: .startupExec)
        #expect(cmd.contains("exec"))
        #expect(cmd.contains("zmx"))
        #expect(cmd.contains("attach"))
        #expect(cmd.contains("vvterm_dev"))
    }

    @Test func attachInteractiveWrapsInShell() {
        let cmd = b.attachCommand(sessionName: "dev", context: .interactiveShell)
        #expect(cmd.hasPrefix("sh -lc"))
    }

    @Test func parsesShortListOneNamePerLine() {
        let sessions = b.parseSessionList("alpha\nbravo\n\ncharlie\n")
        #expect(sessions.map(\.name) == ["alpha", "bravo", "charlie"])
    }

    @Test func killUsesForce() {
        #expect(b.killSessionCommand(named: "dev").contains("kill"))
        #expect(b.killSessionCommand(named: "dev").contains("dev"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails** `[Xcode]`

Expected: FAIL — `cannot find 'RemoteZmxCommandBuilder' in scope`.

- [ ] **Step 3: Create the builder**

Create `VVTerm/Core/SSH/RemoteZmxCommandBuilder.swift`:

```swift
import Foundation

/// Builds the (small) set of shell commands for the zmx multiplexer.
/// zmx contract (v0.6.0): `zmx attach <name>` create-or-attaches a login $SHELL;
/// no config file, no has-session, no windows/splits; `zmx ls --short` lists bare
/// names; `zmx kill <name> --force` removes a session. Detach happens by closing
/// the connection, so no detach command is needed here.
struct RemoteZmxCommandBuilder {
    enum CommandContext {
        case startupExec
        case interactiveShell
    }

    private let zmx = "zmx"

    /// Probe whether zmx is installed. Emits `okMarker` when present.
    func availabilityProbeCommand(okMarker: String) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v zmx >/dev/null 2>&1 && zmx version >/dev/null 2>&1; then
          printf '\(okMarker)';
        else
          printf '__VVTERM_ZMX_NO__';
        fi
        """
        return "sh -c \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    /// Create-or-attach a zmx session.
    func attachCommand(sessionName: String, context: CommandContext) -> String {
        let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); exec \(zmx) attach \(quoted)"
        switch context {
        case .startupExec:
            return body
        case .interactiveShell:
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        }
    }

    func listSessionsCommand() -> String {
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(zmx) ls --short 2>/dev/null"
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    func killSessionCommand(named sessionName: String) -> String {
        let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(zmx) kill \(quoted) --force 2>/dev/null || true"
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    /// Parse `zmx ls --short` output (one session name per line).
    func parseSessionList(_ output: String) -> [RemoteTmuxSession] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { RemoteTmuxSession(name: $0, attachedClients: 0, windowCount: 1) }
    }
}
```

- [ ] **Step 4: Add files to targets** `[Xcode]`

Add `RemoteZmxCommandBuilder.swift` to `VVTerm`, `RemoteZmxCommandBuilderTests.swift` to `VVTermTests`.

- [ ] **Step 5: Run tests** `[Xcode]`

Expected: PASS (4 cases).

- [ ] **Step 6: Commit**

```bash
git add VVTerm/Core/SSH/RemoteZmxCommandBuilder.swift VVTermTests/RemoteZmxCommandBuilderTests.swift
git commit -m "feat(ssh): add isolated RemoteZmxCommandBuilder for zmx multiplexer"
```

---

### Task 8: Route the zmx backend through `RemoteTmuxManager`

**Files:**
- Modify: `VVTerm/Core/SSH/RemoteTmuxManager.swift`

Add `.zmx` to `RemoteTmuxBackend` and delegate its cases to `RemoteZmxCommandBuilder`. The resolver passes a preferred multiplexer; `tmuxBackend` probes accordingly.

- [ ] **Step 1: Extend the backend enum**

In `RemoteTmuxManager.swift`, add a case to `RemoteTmuxBackend` (after `windowsPsmux`):

```swift
    case zmx(commandName: String)
```

`isWindows` stays as-is (zmx is not Windows). Add a convenience:

```swift
    nonisolated var isZmx: Bool {
        if case .zmx = self { return true }
        return false
    }
```

- [ ] **Step 2: Make `tmuxBackend` honor a preferred multiplexer**

Change the signature and body of `tmuxBackend(using:)`:

```swift
    func tmuxBackend(
        using client: SSHClient,
        preferred: TerminalMultiplexer = .tmux
    ) async -> RemoteTmuxBackend? {
        let environment = await client.remoteEnvironment()
        guard environment.supportsTmuxRuntime else { return nil }

        if environment.platform == .windows {
            // zmx is POSIX-only; Windows always uses psmux.
            return await windowsPsmuxBackend(for: environment, using: client)
        }

        if preferred == .zmx {
            let okMarker = "__VVTERM_ZMX_OK__"
            let command = zmxBuilder.availabilityProbeCommand(okMarker: okMarker)
            let output = try? await client.execute(command, timeout: availabilityTimeout)
            return output?.contains(okMarker) == true ? .zmx(commandName: "zmx") : nil
        }

        let okMarker = "__VVTERM_TMUX_OK__"
        let command = tmuxAvailabilityProbeCommand(okMarker: okMarker)
        let output = try? await client.execute(command, timeout: availabilityTimeout)
        return output?.contains(okMarker) == true ? .unixTmux : nil
    }
```

Add the builder instance near the top of the actor (after `static let shared`):

```swift
    private let zmxBuilder = RemoteZmxCommandBuilder()
```

- [ ] **Step 3: Delegate `listSessions` for zmx**

In `listSessions(using:)`, after `guard let backend = await tmuxBackend(using: client) else { return [] }`, special-case zmx. Since callers in the resolver already pass a backend in some paths, add an overload that takes a known backend and have `listSessions(using:)` delegate. Replace the body of `listSessions(using:)` with:

```swift
    func listSessions(using client: SSHClient) async -> [RemoteTmuxSession] {
        guard let backend = await tmuxBackend(using: client) else { return [] }
        return await listSessions(using: client, backend: backend)
    }

    func listSessions(using client: SSHClient, backend: RemoteTmuxBackend) async -> [RemoteTmuxSession] {
        if case .zmx = backend {
            guard let output = try? await client.execute(zmxBuilder.listSessionsCommand(), timeout: listTimeout) else { return [] }
            return zmxBuilder.parseSessionList(output)
        }
        let candidates = listSessionCommands(backend: backend)
        for (index, command) in candidates.enumerated() {
            guard let output = try? await client.execute(command, timeout: listTimeout) else { continue }
            let sessions = parseSessionListOutput(output, allowLegacy: index == candidates.count - 1)
            if !sessions.isEmpty { return sessions }
        }
        return []
    }
```

- [ ] **Step 4: Delegate attach + kill for zmx**

In `attachCommand(sessionName:workingDirectory:context:backend:)`, at the top add:

```swift
        if case .zmx = backend {
            let zmxContext: RemoteZmxCommandBuilder.CommandContext =
                (context == .startupExec) ? .startupExec : .interactiveShell
            return zmxBuilder.attachCommand(sessionName: sessionName, context: zmxContext)
        }
```

In `attachExistingCommand(sessionName:context:backend:)` add the same zmx shortcut (attach == attach-existing for zmx since `attach` create-or-attaches):

```swift
        if case .zmx = backend {
            let zmxContext: RemoteZmxCommandBuilder.CommandContext =
                (context == .startupExec) ? .startupExec : .interactiveShell
            return zmxBuilder.attachCommand(sessionName: sessionName, context: zmxContext)
        }
```

In `killSessionCommand(named:backend:)` add a `.zmx` case to the switch:

```swift
        case .zmx:
            return zmxBuilder.killSessionCommand(named: sessionName)
```

- [ ] **Step 5: Make zmx no-op the config + install paths**

In `prepareConfig(using:terminalType:backend:)`, after resolving `backend`, add `if backend.isZmx { return }` (zmx has no config file).

In `installAndAttachScript(sessionName:workingDirectory:terminalType:backend:)`, at the top add:

```swift
        if case .zmx = backend {
            // No remote installer for zmx; just attach (assumes zmx present).
            return zmxBuilder.attachCommand(sessionName: sessionName, context: .startupExec)
        }
```

In `cleanupLegacySessions(using:)` the `guard backend == .unixTmux else { return }` already skips zmx — leave as-is. `cleanupDetachedSessions` uses `listSessions` + `killSession`; it will operate on zmx names correctly via the delegated paths.

Also add zmx handling to `currentPath(sessionName:using:)`: zmx has no `list-panes`, so add near its top `if case .zmx = backend { return nil }`.

- [ ] **Step 6: Build** `[Xcode]`

Build (⌘B). Fix any exhaustive-switch errors the compiler flags by adding `.zmx` cases that delegate to `zmxBuilder` or return a sensible default (e.g. `currentPathCommand`/`listSessionCommands` won't be hit for zmx but must still compile — add `case .zmx: return ""` / `return []` where the switch requires it, since zmx paths are intercepted earlier).

- [ ] **Step 7: Commit**

```bash
git add VVTerm/Core/SSH/RemoteTmuxManager.swift
git commit -m "feat(ssh): route zmx backend through RemoteTmuxManager via RemoteZmxCommandBuilder"
```

---

### Task 9: Resolver + lifecycle use the multiplexer kind

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- Modify: `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`

- [ ] **Step 1: Add a multiplexer accessor to the resolver**

In `TmuxAttachResolver.swift`, add a global default and a per-server resolver (alongside the existing `tmuxEnabledDefault`/`isTmuxEnabled`):

```swift
    var multiplexerDefault: TerminalMultiplexer {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "terminalMultiplexerDefault"),
           let mux = TerminalMultiplexer(rawValue: raw) {
            return mux
        }
        // Migrate the legacy boolean default once.
        if defaults.object(forKey: "terminalTmuxEnabledDefault") != nil {
            return .fromLegacyTmuxEnabled(defaults.bool(forKey: "terminalTmuxEnabledDefault"))
        }
        return .tmux
    }

    func multiplexer(for serverId: UUID) -> TerminalMultiplexer {
        if let server = ServerManager.shared.servers.first(where: { $0.id == serverId }),
           let override = server.multiplexerOverride {
            return override
        }
        return multiplexerDefault
    }
```

Keep `isTmuxEnabled(for:)` working by reimplementing it in terms of the new kind:

```swift
    func isTmuxEnabled(for serverId: UUID) -> Bool {
        multiplexer(for: serverId).isEnabled
    }
```

- [ ] **Step 2: Pass the preferred multiplexer when fetching the backend**

In `TerminalTabManager.swift`, both `tmuxStartupPlan(for:serverId:client:)` and `handleTmuxLifecycle(...)` call `RemoteTmuxManager.shared.tmuxBackend(using: client)`. Change each to:

```swift
        let preferred = tmuxResolver.multiplexer(for: serverId)
        guard let backend = await RemoteTmuxManager.shared.tmuxBackend(using: client, preferred: preferred) else {
```

Do the same for the equivalent call(s) in `ConnectionSessionManager.swift` (search for `tmuxBackend(using:`). Use the session's `serverId` for `preferred`.

- [ ] **Step 3: Use backend-aware listSessions in the resolver**

In `TmuxAttachResolver.resolveSelection(...)`, the two `RemoteTmuxManager.shared.listSessions(using: client)` calls don't know the backend. Resolve it first so zmx lists via zmx:

At the top of the `.external` reuse branch and the `.askEveryTime` branch, replace `await RemoteTmuxManager.shared.listSessions(using: client)` with:

```swift
            let backend = await RemoteTmuxManager.shared.tmuxBackend(using: client, preferred: multiplexer(for: serverId))
            let sessions = backend == nil ? [] : await RemoteTmuxManager.shared.listSessions(using: client, backend: backend!)
```

(For the `.external` branch, `serverId` is a parameter of `resolveSelection`; reuse it.)

- [ ] **Step 4: Build** `[Xcode]`

Build (⌘B). Expected: compiles; all `tmuxBackend` call sites pass `preferred:`.

- [ ] **Step 5: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift
git commit -m "feat(sessions): resolve multiplexer kind and probe the matching backend"
```

---

### Task 10: UI — multiplexer picker (server form + global settings)

**Files:**
- Modify: `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`
- Modify: `VVTerm/Features/Settings/UI/TerminalSettingsView.swift`

- [ ] **Step 1: Server form — replace the tmux toggle with a multiplexer picker**

In `ServerFormSheet.swift`:

1. Replace the `@State private var tmuxEnabled: Bool` (line 145) with:
```swift
    @State private var multiplexer: TerminalMultiplexer = .tmux
```

2. In `sessionSection` (line ≈772), replace the `Toggle("Use tmux to preserve sessions", isOn: $tmuxEnabled)` and its `if tmuxEnabled` wrapper with:
```swift
            Picker("Session persistence", selection: $multiplexer) {
                ForEach(TerminalMultiplexer.allCases) { mux in
                    Text(mux.displayName).tag(mux)
                }
            }
            if multiplexer.isEnabled {
                Picker("On connect", selection: $tmuxStartupBehavior) {
                    ForEach(TmuxStartupBehavior.configCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }
```

3. Where the form loads existing server state (search `tmuxEnabled =` / `tmuxEnabledOverride`), set:
```swift
        multiplexer = server.multiplexerOverride ?? globalMultiplexerDefault()
```
where `globalMultiplexerDefault()` reads the same UserDefaults key as the resolver:
```swift
    private func globalMultiplexerDefault() -> TerminalMultiplexer {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "terminalMultiplexerDefault"),
           let mux = TerminalMultiplexer(rawValue: raw) { return mux }
        if defaults.object(forKey: "terminalTmuxEnabledDefault") != nil {
            return .fromLegacyTmuxEnabled(defaults.bool(forKey: "terminalTmuxEnabledDefault"))
        }
        return .tmux
    }
```

4. Where `buildServer(...)` sets overrides (search `tmuxEnabledOverride:`), set:
```swift
            multiplexerOverride: multiplexer == globalMultiplexerDefault() ? nil : multiplexer,
```
(stores `nil` when it equals the global default, matching prior semantics.)

- [ ] **Step 2: Global settings — multiplexer default picker**

In `TerminalSettingsView.swift`:

1. Replace the `@AppStorage("terminalTmuxEnabledDefault") private var tmuxEnabledDefault = true` (line 155) with:
```swift
    @AppStorage("terminalMultiplexerDefault") private var multiplexerDefaultRaw = TerminalMultiplexer.tmux.rawValue
```

2. In `sessionPersistenceSection` (line ≈420), replace the tmux on/off toggle with:
```swift
            Picker("Session persistence", selection: Binding(
                get: { TerminalMultiplexer(rawValue: multiplexerDefaultRaw) ?? .tmux },
                set: { multiplexerDefaultRaw = $0.rawValue }
            )) {
                ForEach(TerminalMultiplexer.allCases) { mux in
                    Text(mux.displayName).tag(mux)
                }
            }
```
Keep the existing startup-behavior picker, but show it when the selected multiplexer `.isEnabled`.

- [ ] **Step 3: Build + visual check** `[Xcode]`

Build (⌘B), open the server form and Terminal settings. Expected: a 3-way Off/tmux/zmx picker; startup behavior shows when not Off.

- [ ] **Step 4: Commit**

```bash
git add VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift VVTerm/Features/Settings/UI/TerminalSettingsView.swift
git commit -m "feat(ui): multiplexer picker (off/tmux/zmx) in server form and settings"
```

---

## Phase 3 — Session Binding Persistence (auto-reattach)

### Task 11: `TmuxSessionBindingStore`

**Files:**
- Create: `VVTerm/Features/TerminalSessions/Application/TmuxSessionBindingStore.swift`
- Test: `VVTermTests/TmuxSessionBindingStoreTests.swift` (create)

Persists per-entity (pane/session UUID) bindings so a chosen session survives app kill.

- [ ] **Step 1: Write the failing test**

Create `VVTermTests/TmuxSessionBindingStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import VVTerm

struct TmuxSessionBindingStoreTests {
    private func makeStore() -> (TmuxSessionBindingStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return (TmuxSessionBindingStore(defaults: suite), suite)
    }

    @Test func setThenGetRoundTrips() {
        let (store, _) = makeStore()
        let id = UUID()
        store.set(TmuxSessionBinding(sessionName: "dev", ownership: "external", multiplexer: "zmx"), for: id)
        let got = store.binding(for: id)
        #expect(got?.sessionName == "dev")
        #expect(got?.ownership == "external")
        #expect(got?.multiplexer == "zmx")
    }

    @Test func removeDeletes() {
        let (store, _) = makeStore()
        let id = UUID()
        store.set(TmuxSessionBinding(sessionName: "x", ownership: "managed", multiplexer: "tmux"), for: id)
        store.remove(for: id)
        #expect(store.binding(for: id) == nil)
    }

    @Test func persistsAcrossInstances() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let id = UUID()
        TmuxSessionBindingStore(defaults: suite).set(
            TmuxSessionBinding(sessionName: "keep", ownership: "external", multiplexer: "tmux"), for: id)
        let reloaded = TmuxSessionBindingStore(defaults: suite)
        #expect(reloaded.binding(for: id)?.sessionName == "keep")
    }
}
```

- [ ] **Step 2: Run test to verify it fails** `[Xcode]`

Expected: FAIL — `cannot find 'TmuxSessionBindingStore' in scope`.

- [ ] **Step 3: Create the store**

Create `VVTerm/Features/TerminalSessions/Application/TmuxSessionBindingStore.swift`:

```swift
import Foundation

/// A persisted binding between a pane/session (entity UUID) and the multiplexer
/// session it attached to, so reconnecting after an app restart auto-reattaches
/// instead of re-prompting.
struct TmuxSessionBinding: Codable, Equatable {
    var sessionName: String
    var ownership: String    // "managed" | "external"
    var multiplexer: String  // TerminalMultiplexer.rawValue
}

final class TmuxSessionBindingStore {
    private let defaults: UserDefaults
    private let key = "tmuxSessionBindings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allBindings() -> [String: TmuxSessionBinding] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: TmuxSessionBinding].self, from: data) else {
            return [:]
        }
        return map
    }

    func binding(for entityId: UUID) -> TmuxSessionBinding? {
        allBindings()[entityId.uuidString]
    }

    func set(_ binding: TmuxSessionBinding, for entityId: UUID) {
        var map = allBindings()
        map[entityId.uuidString] = binding
        save(map)
    }

    func remove(for entityId: UUID) {
        var map = allBindings()
        map.removeValue(forKey: entityId.uuidString)
        save(map)
    }

    private func save(_ map: [String: TmuxSessionBinding]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Add files to targets** `[Xcode]`

Add `TmuxSessionBindingStore.swift` to `VVTerm`, test to `VVTermTests`.

- [ ] **Step 5: Run tests** `[Xcode]`

Expected: PASS (3 cases).

- [ ] **Step 6: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TmuxSessionBindingStore.swift VVTermTests/TmuxSessionBindingStoreTests.swift
git commit -m "feat(sessions): add TmuxSessionBindingStore for persisted session bindings"
```

---

### Task 12: Hydrate + persist bindings in `TmuxAttachResolver`

**Files:**
- Modify: `VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift`

- [ ] **Step 1: Own the store and hydrate on init**

In `TmuxAttachResolver`, add the store and hydrate the in-memory maps. After the `sessionOwnership` property declaration (line 12), add:

```swift
    private let bindingStore = TmuxSessionBindingStore()

    init() {
        for (idString, binding) in bindingStore.allBindings() {
            guard let id = UUID(uuidString: idString) else { continue }
            sessionNames[id] = binding.sessionName
            sessionOwnership[id] = (binding.ownership == "managed") ? .managed : .external
        }
    }
```

- [ ] **Step 2: Persist on update**

In `updateAttachmentState(for:selection:setPrompt:)`, after each in-memory write, persist via a helper. Replace the method body with:

```swift
    func updateAttachmentState(for entityId: UUID, selection: TmuxAttachSelection, setPrompt: (TmuxAttachPrompt?) -> Void) {
        switch selection {
        case .createManaged:
            let name = managedSessionName(for: entityId)
            sessionNames[entityId] = name
            sessionOwnership[entityId] = .managed
            persistBinding(for: entityId, name: name, ownership: .managed)
        case .attachExisting(let name):
            sessionNames[entityId] = name
            let own = ownership(for: name)
            sessionOwnership[entityId] = own
            persistBinding(for: entityId, name: name, ownership: own)
        case .skipTmux:
            clearRuntimeState(for: entityId, setPrompt: setPrompt)
        }
    }

    private func persistBinding(for entityId: UUID, name: String, ownership: SessionOwnership) {
        // `multiplexer` is informational; reattach uses sessionName + ownership, and the
        // backend kind is resolved live from the server via multiplexer(for:).
        let mux = isCurrentDeviceManagedSessionName(name) ? "tmux" : "external"
        bindingStore.set(
            TmuxSessionBinding(
                sessionName: name,
                ownership: ownership == .managed ? "managed" : "external",
                multiplexer: mux
            ),
            for: entityId
        )
    }
```

- [ ] **Step 3: Remove the binding on clear**

In `clearAttachmentState(for:)`, add the store removal:

```swift
    func clearAttachmentState(for entityId: UUID) {
        sessionNames.removeValue(forKey: entityId)
        sessionOwnership.removeValue(forKey: entityId)
        bindingStore.remove(for: entityId)
    }
```

- [ ] **Step 4: Build + run binding tests** `[Xcode]`

Build (⌘B). Run `TmuxSessionBindingStoreTests` + existing resolver tests. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift
git commit -m "feat(sessions): hydrate and persist session bindings across app restarts"
```

---

### Task 13: Verify auto-reattach end to end

**Files:** none (manual verification) `[Xcode + device/sim + a real host with tmux and zmx]`

- [ ] **Step 1: tmux external reattach**

Server with tmux + "Ask every time". Connect, pick/create a named session `work`, run `vim`. Kill the app fully. Reopen → the pane reconnects and reattaches to `work` (vim still there) with NO picker prompt.

- [ ] **Step 2: zmx reattach**

Server with multiplexer = zmx. Connect (creates `vvterm_<device>_<paneUUID>` via `zmx attach`). Run a process, kill the app, reopen → auto-reattaches to the same zmx session. Confirm on the host with `zmx ls`.

- [ ] **Step 3: zmx "ask every time" picker**

Server with zmx + "Ask every time", with ≥1 pre-existing zmx session on the host (`zmx attach manual` in another terminal). Connect → picker lists `manual` (from `zmx ls --short`). Pick it → attaches. Kill app, reopen → reattaches to `manual` without prompting.

- [ ] **Step 4: Off**

Server with multiplexer = Off → plain shell, no attach, no prompt.

---

## Done criteria

- All `VVTermTests` unit tests pass in Xcode (⌘U).
- SSH: wrong key → one failed auth, no sshd penalty storm; imported key (no stored pubkey) authenticates.
- zmx selectable per-server and globally; connects, lists, kills, reattaches.
- A bound pane (tmux or zmx, managed or external) auto-reattaches after app kill with no picker.
