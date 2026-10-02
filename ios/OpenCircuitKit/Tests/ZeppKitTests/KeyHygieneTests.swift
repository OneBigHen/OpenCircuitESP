// No key material through reflection: what `print`, string interpolation, `String(reflecting:)` and
// `dump` of a live link would log. The #219 review's probe found the EPHEMERAL ECDH private scalar
// visible in `print(link)` between `startAuthentication()` and the strap's `10 04` reply (N6); the
// auth key and session key were already redacted.

import XCTest
@testable import ZeppKit
import ZeppKitTesting

final class KeyHygieneTests: XCTestCase {

    private let authKeyBytes = hex("00112233445566778899aabbccddeeff")

    /// Every secret whose bytes must never be reflected.
    private var secrets: [(name: String, bytes: [UInt8])] {
        [("ephemeral private key (effective)", SpecC.phoneEffectivePrivate),
         ("ephemeral private key (as drawn)", SpecC.phoneDrawnPrivate),
         ("auth key", authKeyBytes),
         ("session key", SpecC.sessionKey)]
    }

    /// Fails if any secret shows up in the value's description, debug description, interpolation or
    /// dump, or anywhere in its reflection tree as a byte array.
    private func assertNoSecrets(in value: Any, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        var dumped = ""
        dump(value, to: &dumped)
        let texts = [String(describing: value), String(reflecting: value), "\(value)"]
        // dump prints one "- <byte>" line per array element; flatten it so a run of lines can match.
        let dumpTokens = dumped.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "|")
        for secret in secrets {
            let decimal = secret.bytes.map(String.init).joined(separator: ", ")
            let hexText = ZeppHex.string(secret.bytes)
            for text in texts {
                XCTAssertFalse(text.contains(decimal) || text.contains(hexText),
                               "\(label): \(secret.name) visible in a description", file: file, line: line)
            }
            let dumpedBytes = secret.bytes.map { "- \($0)" }.joined(separator: "|")
            XCTAssertFalse(dumpTokens.contains(dumpedBytes) || dumped.contains(hexText),
                           "\(label): \(secret.name) visible in dump", file: file, line: line)
            XCTAssertFalse(reflectionTree(value).contains(secret.bytes),
                           "\(label): \(secret.name) reachable through Mirror", file: file, line: line)
        }
    }

    /// Every [UInt8] reachable through Mirror (what dump walks).
    private func reflectionTree(_ value: Any, depth: Int = 0) -> [[UInt8]] {
        guard depth < 20 else { return [] }
        var found = [[UInt8]]()
        if let bytes = value as? [UInt8] { found.append(bytes) }
        for child in Mirror(reflecting: value).children {
            found += reflectionTree(child.value, depth: depth + 1)
        }
        return found
    }

    func testALinkMidHandshakeAndAfterAuthReflectsNoKeyBytes() throws {
        let device = FakeZeppDevice(authKey: authKeyBytes, privateKey: SpecC.strapDrawnPrivate, random: SpecC.strapRandom)
        var link = ZeppLink(authKey: SpecC.authKey, random: .fixed(SpecC.phoneDrawnPrivate))
        let start = link.startAuthentication()
        // Mid-handshake: the public-key message is out, the strap's reply is not in, and the
        // authenticator holds the ephemeral private key.
        XCTAssertEqual(link.authenticator.state, .awaitingPublicKeyReply)
        assertNoSecrets(in: link, "link mid-handshake")
        assertNoSecrets(in: link.authenticator, "authenticator mid-handshake")
        _ = pump(&link, device, start.writes)
        XCTAssertTrue(link.isAuthenticated)
        assertNoSecrets(in: link, "link after auth")
    }

    func testAuthenticatorShowsOnlyItsState() {
        var authenticator = ZeppAuthenticator(authKey: SpecC.authKey, random: .fixed(SpecC.phoneDrawnPrivate))
        _ = authenticator.start()
        XCTAssertEqual("\(authenticator)", "ZeppAuthenticator(state: awaitingPublicKeyReply)")
        XCTAssertEqual(Mirror(reflecting: authenticator).children.map(\.label), ["state"])
    }

    func testKeyPairRedactsItsPrivateScalar() throws {
        let pair = try B163.generateKeyPair(using: .fixed(SpecC.phoneDrawnPrivate))
        XCTAssertEqual(pair.privateKey, SpecC.phoneEffectivePrivate)     // still usable by ZeppKit
        assertNoSecrets(in: pair, "key pair")
        XCTAssertTrue("\(pair)".contains("<redacted>"))
        XCTAssertTrue("\(pair)".contains(ZeppHex.string(SpecC.phonePubX + SpecC.phonePubY)))
    }
}
