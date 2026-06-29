import Testing
import Foundation
@testable import VVTerm

// Test Context:
// These tests protect public-key derivation from stored private key material for
// SSH key authentication. Fixtures contain test keys only and no secrets; update only
// when supported key formats or derivation behavior intentionally changes.

@MainActor
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

    @Test func derivesRSAPublicKeyFromPKCS1Fixture() throws {
        let derived = SSHPublicKeyDeriver.publicKey(fromPrivateKeyPEM: Self.rsaPrivateKeyFixture)
        #expect(derived == Self.rsaPublicKeyFixture)
    }

    @Test func returnsNilForGarbage() {
        #expect(SSHPublicKeyDeriver.publicKey(fromPrivateKeyPEM: "not a key") == nil)
    }

    private static let rsaPrivateKeyFixture = """
    -----BEGIN RSA PRIVATE KEY-----
    MIICWwIBAAKBgQDF7fCivzAa98HSwS83L817EKPOgv19TkY6i2F1tTYZqRgQ4UxA
    odOg1yDUc+3G/p+5wrmtaf9iYyT9mASWIuK9e8rdnFSalt9wJ9utcKbnyn4Trggy
    IoaJaHSpE5lYpCNXJWL1e9UwsEXACfZvOa/fdzWjE23jP7+Itgcp76hSZwIDAQAB
    AoGAD6ENSlyceNStim3Uw5/Tsu8KcEkpqRZgN0lAReIsRnRywQp5UfU1V9ME9aG9
    2ePLSwjUTpw7HVLE3f1+Bzjz/GzYRsv4IWkhUCqEDqO1g8rLuvZHPXPnM3+o2AEU
    HlJI72chSgyZS2NcoBfbTpK4Q0hLQa41CrSqzoHONDeTYrECQQDhpaFtIAghVU/K
    HXpgfBfK/ZKP90TmufAjG1Z2jiP4ZG3GtrrYGfmH2W+a6wMTzdThonHRfKxEFnqJ
    xrtQ0k6ZAkEA4I3UVnADurXXjo6zsW1fV7plBNO/UdRxwJuT6nTAf6gSku1Feo5y
    cDONG57qo0tCzXKkscFItQsX7/a5CDlI/wJAffei+HKLV2By3Jg8OyTLe4y3hxs5
    IbznbBHU4PZU6lPWXLqh8AYAIXCnN0q/Ow0LLLMs6w+4c4JBAi0pYOMm8QJAOxya
    3PY3xRrBV8GxA+/qvUlP9mlXX88w8qcB1SJO2kwAN7VGKPD+pxKq/q5izgGt4C9h
    s3lSDnaRIpYsN0H9OQJAFnoPcKnSlxfh/SUr7AsH4xtsJJAgDON/8OPtej8j7/oB
    GoBn0QmyghSoB1z2AHirmlJKktg8ZxrnNbmLVSFY2w==
    -----END RSA PRIVATE KEY-----
    """

    private static let rsaPublicKeyFixture = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDF7fCivzAa98HSwS83L817EKPOgv19TkY6i2F1tTYZqRgQ4UxAodOg1yDUc+3G/p+5wrmtaf9iYyT9mASWIuK9e8rdnFSalt9wJ9utcKbnyn4TrggyIoaJaHSpE5lYpCNXJWL1e9UwsEXACfZvOa/fdzWjE23jP7+Itgcp76hSZw=="
}
