// The auth handshake (§4): key parsing, the spec's worked example C through the state machine
// and the link, then a full simulated phone ⇄ strap run including a wrong-key failure.

import XCTest
@testable import ZeppKit

final class AuthKeyTests: XCTestCase {

    func testAcceptsExactlyThirtyTwoHexDigitsWithOptionalPrefix() {
        let expected = hex("00112233445566778899aabbccddeeff")
        for text in ["00112233445566778899aabbccddeeff", "0x00112233445566778899AABBCCDDEEFF",
                     "0X00112233445566778899aabbccddeeff", "  00112233445566778899aabbccddeeff\n"] {
            XCTAssertEqual(ZeppAuthKey(hex: text)?.bytes, expected, text)
        }
    }

    func testRejectsEverythingElse() {
        for text in ["", "0x", "00112233445566778899aabbccddeef",          // 31 digits
                     "00112233445566778899aabbccddeeff00",                  // 34 digits
                     "00112233445566778899aabbccddeefg",                    // non-hex
                     "0011 2233445566778899aabbccddeeff",                   // inner space
                     "00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff",     // separators
                     "+0112233445566778899aabbccddeeff", "0x0x112233445566778899aabbccddeeff",
                     "００112233445566778899aabbccddeeff"] {                 // full-width digits
            XCTAssertNil(ZeppAuthKey(hex: text), text)
        }
        XCTAssertNil(ZeppAuthKey(bytes: [UInt8](repeating: 0, count: 15)))
    }

    func testKeyNeverAppearsInDescriptions() {
        let key = ZeppAuthKey(hex: "00112233445566778899aabbccddeeff")!
        var dumped = ""
        dump(key, to: &dumped)
        for text in ["\(key)", String(describing: key), String(reflecting: key), dumped] {
            XCTAssertFalse(text.lowercased().contains("aabb"), text)
            XCTAssertFalse(text.contains("170"), text)        // 0xaa as a decimal byte
        }
        let session = try! ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: 1)
        var dumpedSession = ""
        dump(session, to: &dumpedSession)
        XCTAssertFalse("\(session)\(dumpedSession)".contains("140"))   // 0x8c
    }

    func testSessionDerivationMatchesWorkedExampleC() throws {
        let session = try ZeppSessionKeys.derive(sharedSecret: SpecC.sharedX + SpecC.sharedY, authKey: SpecC.authKey)
        XCTAssertEqual(session.sessionKey, SpecC.sessionKey)
        XCTAssertEqual(session.nextSequence, SpecC.sequenceSeed)
        XCTAssertThrowsError(try ZeppSessionKeys.derive(sharedSecret: [1, 2, 3], authKey: SpecC.authKey))
    }
}

final class AuthenticatorTests: XCTestCase {

    private func specAuthenticator() -> ZeppAuthenticator {
        ZeppAuthenticator(authKey: SpecC.authKey, random: .fixed(SpecC.phoneDrawnPrivate))
    }

    func testWorkedExampleCThroughTheStateMachine() {
        var auth = specAuthenticator()
        let first = auth.start()
        XCTAssertEqual(first.send, [0x04, 0x02, 0x00, 0x02] + SpecC.phonePubX + SpecC.phonePubY)
        XCTAssertEqual(first.state, .awaitingPublicKeyReply)

        let second = auth.handle(SpecC.strapReply)
        XCTAssertEqual(second.send, [0x05] + SpecC.proofAuth + SpecC.proofSession)
        XCTAssertEqual(second.session?.sessionKey, SpecC.sessionKey)
        XCTAssertEqual(second.session?.nextSequence, SpecC.sequenceSeed)
        XCTAssertEqual(second.state, .awaitingSessionReply)

        XCTAssertEqual(auth.handle([0x10, 0x05, 0x01]).state, .authenticated)
    }

    func testWrongKeyStatus() {
        var auth = specAuthenticator()
        _ = auth.start()
        _ = auth.handle(SpecC.strapReply)
        let step = auth.handle([0x10, 0x05, 0x25])
        XCTAssertEqual(step.state, .failed(.wrongAuthKey))
        XCTAssertNil(step.send)
    }

    func testOtherFailures() {
        var a = specAuthenticator(); _ = a.start()
        XCTAssertEqual(a.handle([0x10, 0x04, 0x02]).state, .failed(.publicKeyRejected(status: 0x02)))

        var b = specAuthenticator(); _ = b.start()
        XCTAssertEqual(b.handle(Array(SpecC.strapReply.prefix(66))).state, .failed(.malformedReply))

        var c = specAuthenticator(); _ = c.start()
        var badKey = SpecC.strapReply
        badKey[19 + 24] ^= 0x01                        // corrupt the strap's Y
        XCTAssertEqual(c.handle(badKey).state, .failed(.invalidDevicePublicKey))

        var d = specAuthenticator(); _ = d.start(); _ = d.handle(SpecC.strapReply)
        XCTAssertEqual(d.handle([0x10, 0x05, 0x07]).state, .failed(.sessionRejected(status: 0x07)))

        var e = ZeppAuthenticator(authKey: SpecC.authKey, random: .fixed([]))
        XCTAssertEqual(e.start().state, .failed(.localCryptoFailure))
    }

    func testUnrelatedPayloadsAreIgnored() {
        var auth = specAuthenticator()
        _ = auth.start()
        for payload in [[], [0x10], [0x11, 0x04, 0x01], [0x10, 0x05, 0x01], [0x10, 0x99, 0x01]] as [[UInt8]] {
            let step = auth.handle(payload)
            XCTAssertEqual(step.state, .awaitingPublicKeyReply)
            XCTAssertNil(step.send)
        }
        // A late second 04 reply after the 05 went out is ignored too.
        _ = auth.handle(SpecC.strapReply)
        XCTAssertNil(auth.handle(SpecC.strapReply).send)
        XCTAssertEqual(auth.state, .awaitingSessionReply)
    }
}

final class SimulatedHandshakeTests: XCTestCase {

    private func makeDevice(authKey: [UInt8] = hex("00112233445566778899aabbccddeeff"), writeLength: Int = 20) -> FakeZeppDevice {
        FakeZeppDevice(authKey: authKey, privateKey: SpecC.strapDrawnPrivate, random: SpecC.strapRandom,
                       writeLength: writeLength)
    }

    /// The spec's worked examples A and C on the wire: the public-key message chunks exactly as
    /// §3.6, and the 05 message at MTU 247 exactly as §4.6.
    func testLinkEmitsTheSpecBytes() {
        var link = ZeppLink(authKey: SpecC.authKey, random: .fixed(SpecC.phoneDrawnPrivate), maxWriteLength: 20)
        let start = link.startAuthentication()
        XCTAssertEqual(start.writes.map(\.characteristic), [.chunkedWrite, .chunkedWrite, .chunkedWrite, .chunkedWrite])
        XCTAssertEqual(start.writes.map(\.bytes), [
            hex("03 01 00 01 00 34 00 00 00 82 00 04 02 00 02 a1 e4 ad 02 c2"),
            hex("03 00 00 01 01 a4 4e a2 41 52 96 2c 14 0e a0 63 c6 9b 2e 5c"),
            hex("03 00 00 01 02 07 00 00 00 cd 50 73 a0 6d 67 b7 8a 3b c5 f5"),
            hex("03 06 00 01 03 19 ab 85 fb 9c f5 85 5d c8 01 00 00 00"),
        ])

        link.setMaxWriteLength(244)
        let reply = try! ZeppChunkCodec.chunks(body: SpecC.strapReply, declaredLength: 67, endpoint: 0x0082,
                                               handle: 0x01, encrypted: false, maxWriteLength: 244)
        let out = link.receive(reply[0])
        XCTAssertEqual(out.writes, [
            ZeppWrite(.chunkedRead, hex("04 00 01 01 00")),
            ZeppWrite(.chunkedWrite, hex("03 07 00 02 00 21 00 00 00 82 00 05 e8 55 41 bb 23 2f 07 09 90 89 75 3d 86 c0 dd f0 e0 f4 c3 cc 1c 86 76 7b dd 16 70 a2 1d 60 d5 4f")),
        ])
        XCTAssertEqual(link.transport.session?.sessionKey, SpecC.sessionKey)
        XCTAssertFalse(link.isAuthenticated)
    }

    func testFullHandshakeThenEncryptedTrafficWithTheSimulatedStrap() throws {
        for writeLength in [20, 244] {
            let device = makeDevice(writeLength: writeLength)
            var link = ZeppLink(authKey: SpecC.authKey, random: .system, maxWriteLength: writeLength)
            let events = pump(&link, device, link.startAuthentication().writes)
            XCTAssertEqual(events, [.authenticated], "MTU \(writeLength)")
            XCTAssertTrue(link.isAuthenticated)
            XCTAssertTrue(device.authenticated)
            XCTAssertEqual(link.transport.session?.sessionKey, device.sessionKey)

            // Services list (plaintext) → apply → battery (encrypted both ways) → config (encrypted).
            var got = pump(&link, device, try link.send(endpoint: ZeppEndpoint.servicesList, payload: ZeppServicesList.request))
            guard case .message(let servicesMessage)? = got.first,
                  let list = ZeppServicesList.parse(servicesMessage.payload) else { return XCTFail("\(got)") }
            XCTAssertEqual(list.entries.count, 7)
            link.apply(servicesList: list)

            got = pump(&link, device, try link.send(endpoint: ZeppEndpoint.battery, payload: ZeppBatteryStatus.request))
            guard case .message(let battery)? = got.first else { return XCTFail("\(got)") }
            XCTAssertTrue(battery.wasEncrypted)
            XCTAssertEqual(battery.trailerCRCMatches, true)
            XCTAssertEqual(ZeppBatteryStatus.parse(battery.payload)?.level, 87)

            got = pump(&link, device, try link.send(endpoint: ZeppEndpoint.config,
                                                    payload: ZeppConfig.readRequest(group: ZeppConfig.healthGroup,
                                                                                    arguments: ZeppConfig.recordingArguments)))
            guard case .message(let config)? = got.first,
                  let reply = ZeppConfig.parseReadReply(config.payload) else { return XCTFail("\(got)") }
            XCTAssertEqual(ZeppHealthSettings(reply).stressMonitoring, false)

            XCTAssertEqual(device.failures, [], "MTU \(writeLength)")
            // Every device message requested an ack and got exactly one.
            XCTAssertEqual(device.receivedAcks.count, 5)
            XCTAssertEqual(device.receivedEndpoints, [0x0082, 0x0082, 0x0000, 0x0029, 0x000A])
        }
    }

    func testWrongKeyFailsVisiblyAndSendsNothingFurther() {
        let device = makeDevice(authKey: hex("ffeeddccbbaa99887766554433221100"))
        var link = ZeppLink(authKey: SpecC.authKey, random: .system, maxWriteLength: 20)
        let events = pump(&link, device, link.startAuthentication().writes)
        XCTAssertEqual(events, [.authenticationFailed(.wrongAuthKey)])
        XCTAssertFalse(link.isAuthenticated)
        XCTAssertFalse(device.authenticated)
        XCTAssertEqual(device.failures, [])
        XCTAssertEqual(link.authenticator.state, .failed(.wrongAuthKey))
        // A retry resets the transport: no session, handle counter back to 1.
        let retry = link.startAuthentication()
        XCTAssertNil(link.transport.session)
        XCTAssertEqual(retry.writes.first?.bytes[3], 0x01)
    }

    func testReauthenticationStartsFromHandleOneWithAFreshKey() {
        let device = makeDevice()
        var link = ZeppLink(authKey: SpecC.authKey, random: .system, maxWriteLength: 244)
        _ = pump(&link, device, link.startAuthentication().writes)
        let firstKey = link.transport.session?.sessionKey
        let device2 = makeDevice()
        var link2 = link
        let restart = link2.startAuthentication()
        XCTAssertEqual(restart.writes.first?.bytes[3], 0x01)
        XCTAssertEqual(pump(&link2, device2, restart.writes), [.authenticated])
        XCTAssertNotEqual(link2.transport.session?.sessionKey, firstKey)
    }
}
