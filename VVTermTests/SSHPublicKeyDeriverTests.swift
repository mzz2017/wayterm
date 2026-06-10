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
