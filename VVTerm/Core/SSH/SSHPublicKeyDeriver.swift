import Foundation
import Security

/// Derives the OpenSSH one-line public key ("ssh-ed25519 AAAA..." / "ssh-rsa AAAA...")
/// from a PEM private key, so we can persist a correct public key alongside imported
/// keys (libssh2's nil-public-key derivation is unreliable across key formats).
///
/// Supports the formats VVTerm itself generates and the common imported ones:
/// OpenSSH (`BEGIN OPENSSH PRIVATE KEY`, ed25519 + rsa) and PKCS#1 (`BEGIN RSA
/// PRIVATE KEY`). PKCS#8 (`BEGIN PRIVATE KEY` / `BEGIN ENCRYPTED PRIVATE KEY`) is
/// intentionally not parsed here: it returns nil so the caller falls back to letting
/// libssh2 derive the public key itself. The sshd penalty fix does not depend on this
/// derivation — it comes from not retrying failed auth — so the fall-through is safe.
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
