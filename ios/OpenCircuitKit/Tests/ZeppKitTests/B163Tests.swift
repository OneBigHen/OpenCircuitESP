// B-163 ECDH against an INDEPENDENT oracle: OpenSSL 3's sect163r2 (B163OpenSSLVectors.swift,
// regenerate with make_b163_vectors.sh), plus the spec's worked example C, plus point validation.

import XCTest
@testable import ZeppKit

final class B163Tests: XCTestCase {

    // MARK: Curve constants vs OpenSSL's explicit parameters

    /// `openssl ecparam -name sect163r2 -param_enc explicit -text` (OpenSSL 3.6.4), big-endian.
    func testCurveConstantsMatchOpenSSLExplicitParameters() {
        XCTAssertEqual(B163.coefficientB.littleEndianBytes,
                       le24(fromBigEndian: "020a601907b8c953ca1481eb10512f78744a3205fd"))
        XCTAssertEqual(B163.generator.x.littleEndianBytes,
                       le24(fromBigEndian: "03f0eba16286a2d57ea0991168d4994637e8343e36"))
        XCTAssertEqual(B163.generator.y.littleEndianBytes,
                       le24(fromBigEndian: "00d51fbc6c71a0094fa2cdd545b11c5c0c797324f1"))
        XCTAssertEqual(B163.order.littleEndianBytes,
                       le24(fromBigEndian: "040000000000000000000292fe77e70c12a4234c33"))
        // x^163 + x^7 + x^6 + x^3 + 1
        XCTAssertEqual(B163.polynomial.littleEndianBytes,
                       le24(fromBigEndian: "0800000000000000000000000000000000000000c9"))
    }

    func testGeneratorIsOnTheCurveAndHasOrderN() {
        XCTAssertTrue(B163.isOnCurve(B163.generator))
        XCTAssertTrue(B163.multiply(B163.generator, by: B163.order).isInfinity)
        XCTAssertFalse(B163.multiply(B163.generator, by: B163.order ^ .one).isInfinity)
    }

    // MARK: OpenSSL oracle

    func testPublicKeysAgreeWithOpenSSL() throws {
        XCTAssertGreaterThanOrEqual(b163OpenSSLVectors.count, 9)
        for v in b163OpenSSLVectors {
            let pubA = try B163.publicKey(forPrivateKey: le24(fromBigEndian: v.privateA))
            XCTAssertEqual(pubA, le24(fromBigEndian: v.publicAX) + le24(fromBigEndian: v.publicAY), v.name)
            let pubB = try B163.publicKey(forPrivateKey: le24(fromBigEndian: v.privateB))
            XCTAssertEqual(pubB, le24(fromBigEndian: v.publicBX) + le24(fromBigEndian: v.publicBY), v.name)
        }
    }

    func testSharedSecretsAgreeWithOpenSSL() throws {
        for v in b163OpenSSLVectors {
            let privA = le24(fromBigEndian: v.privateA)
            let privB = le24(fromBigEndian: v.privateB)
            let pubA = le24(fromBigEndian: v.publicAX) + le24(fromBigEndian: v.publicAY)
            let pubB = le24(fromBigEndian: v.publicBX) + le24(fromBigEndian: v.publicBY)
            let ab = try B163.sharedSecret(privateKey: privA, peerPublicKey: pubB)
            let ba = try B163.sharedSecret(privateKey: privB, peerPublicKey: pubA)
            XCTAssertEqual(ab.count, 48, v.name)
            // OpenSSL's ECDH output is the shared X only.
            XCTAssertEqual(Array(ab[0..<24]), le24(fromBigEndian: v.sharedX), v.name)
            // Y: both sides agree, the point is on the curve, and the top 29 bits are clear.
            XCTAssertEqual(ab, ba, v.name)
            let point = B163Point(x: B163Element(littleEndian: ab[0..<24])!, y: B163Element(littleEndian: ab[24..<48])!)
            XCTAssertTrue(B163.isOnCurve(point), v.name)
            XCTAssertEqual(ab[21], 0, v.name); XCTAssertEqual(ab[45], 0, v.name)
            XCTAssertLessThan(ab[20], 0x08, v.name); XCTAssertLessThan(ab[44], 0x08, v.name)
        }
    }

    // MARK: Spec worked example C (§4.6)

    func testSpecWorkedExampleC() throws {
        XCTAssertEqual(try B163.effectivePrivateKey(SpecC.phoneDrawnPrivate), SpecC.phoneEffectivePrivate)
        XCTAssertEqual(try B163.effectivePrivateKey(SpecC.strapDrawnPrivate),
                       hex("81 82 83 84 85 86 87 88 89 8a 8b 8c 8d 8e 8f 90 91 92 93 94 01 00 00 00"))
        let phonePub = try B163.publicKey(forPrivateKey: SpecC.phoneDrawnPrivate)
        XCTAssertEqual(phonePub, SpecC.phonePubX + SpecC.phonePubY)
        let strapPub = try B163.publicKey(forPrivateKey: SpecC.strapDrawnPrivate)
        XCTAssertEqual(strapPub, SpecC.strapPubX + SpecC.strapPubY)
        let shared = try B163.sharedSecret(privateKey: SpecC.phoneDrawnPrivate, peerPublicKey: strapPub)
        XCTAssertEqual(shared, SpecC.sharedX + SpecC.sharedY)
        XCTAssertEqual(try B163.sharedSecret(privateKey: SpecC.strapDrawnPrivate, peerPublicKey: phonePub), shared)
    }

    // MARK: Key generation from an injected RNG

    func testKeyGenerationRedrawsTooSmallScalarsAndClearsHighBits() throws {
        var tooSmall = [UInt8](repeating: 0, count: 24)
        tooSmall[9] = 0x80                                  // bit 79 → degree 80 < 81
        var onlyHighBits = [UInt8](repeating: 0, count: 24)
        onlyHighBits[23] = 0xFF                             // passes the raw check, clears to 0
        let random = ZeppRandom.fixed(tooSmall + onlyHighBits + SpecC.phoneDrawnPrivate)
        let pair = try B163.generateKeyPair(using: random)
        XCTAssertEqual(pair.privateKey, SpecC.phoneEffectivePrivate)
        XCTAssertEqual(pair.publicKey, SpecC.phonePubX + SpecC.phonePubY)
    }

    func testKeyGenerationBoundaryDegree81IsAccepted() throws {
        var justEnough = [UInt8](repeating: 0, count: 24)
        justEnough[10] = 0x01                               // bit 80 → degree 81
        XCTAssertEqual(try B163.effectivePrivateKey(justEnough), justEnough)
        var tooSmall = [UInt8](repeating: 0, count: 24)
        tooSmall[9] = 0xFF
        XCTAssertThrowsError(try B163.effectivePrivateKey(tooSmall)) {
            XCTAssertEqual($0 as? B163.Error, .privateKeyTooSmall)
        }
    }

    func testKeyGenerationGivesUpOnABrokenRandomSource() {
        let zeros = ZeppRandom.fixed([UInt8](repeating: 0, count: 24 * 40))
        XCTAssertThrowsError(try B163.generateKeyPair(using: zeros)) {
            XCTAssertEqual($0 as? B163.Error, .randomSourceExhausted)
        }
        XCTAssertThrowsError(try B163.generateKeyPair(using: .fixed([1, 2, 3])))
    }

    func testSystemRandomProducesDistinctValidKeyPairs() throws {
        let a = try B163.generateKeyPair(using: .system)
        let b = try B163.generateKeyPair(using: .system)
        XCTAssertNotEqual(a.privateKey, b.privateKey)
        XCTAssertNoThrow(try B163.validatePublicKey(a.publicKey))
        XCTAssertEqual(try B163.sharedSecret(privateKey: a.privateKey, peerPublicKey: b.publicKey),
                       try B163.sharedSecret(privateKey: b.privateKey, peerPublicKey: a.publicKey))
    }

    // MARK: Public-key validation

    private var validPublicKey: [UInt8] { SpecC.strapPubX + SpecC.strapPubY }

    private func assertRejected(_ key: [UInt8], _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try B163.validatePublicKey(key), reason, file: file, line: line) { error in
            guard case B163.Error.invalidPublicKey = error else {
                return XCTFail("expected invalidPublicKey for \(reason), got \(error)", file: file, line: line)
            }
        }
        XCTAssertThrowsError(try B163.sharedSecret(privateKey: SpecC.phoneDrawnPrivate, peerPublicKey: key),
                             reason, file: file, line: line)
    }

    func testValidPublicKeyIsAccepted() {
        XCTAssertNoThrow(try B163.validatePublicKey(validPublicKey))
    }

    func testRejectsWrongLengths() {
        for length in [0, 47, 49, 64] {
            XCTAssertThrowsError(try B163.validatePublicKey([UInt8](repeating: 1, count: length))) {
                XCTAssertEqual($0 as? B163.Error, .invalidLength)
            }
        }
        XCTAssertThrowsError(try B163.publicKey(forPrivateKey: [1, 2, 3]))
        XCTAssertThrowsError(try B163.sharedSecret(privateKey: [UInt8](repeating: 1, count: 23),
                                                   peerPublicKey: validPublicKey))
    }

    func testRejectsPointAtInfinity() {
        assertRejected([UInt8](repeating: 0, count: 48), "infinity")
    }

    func testRejectsPointOffTheCurve() {
        var key = validPublicKey
        key[24] ^= 0x01
        assertRejected(key, "off curve")
        assertRejected(SpecC.strapPubY + SpecC.strapPubX, "coordinates swapped")
    }

    func testRejectsUnreducedCoordinates() {
        var key = validPublicKey
        key[20] |= 0x08                                      // bit 163 of X
        assertRejected(key, "X bit 163")
        var keyY = validPublicKey
        keyY[47] = 0x80                                      // bit 191 of Y
        assertRejected(keyY, "Y bit 191")
    }

    func testRejectsTheOrderTwoPoint() {
        // (0, √b) is on y² + xy = x³ + x² + b; √a = a^(2^162) in GF(2^163).
        var root = B163.coefficientB
        for _ in 0..<162 { root = B163.multiply(root, root) }
        XCTAssertEqual(B163.multiply(root, root), B163.coefficientB)
        let t = B163Point(x: .zero, y: root)
        XCTAssertTrue(B163.isOnCurve(t))
        assertRejected(t.x.littleEndianBytes + t.y.littleEndianBytes, "order-2 point")
    }

    func testRejectsAPointOutsideThePrimeOrderSubgroup() throws {
        var root = B163.coefficientB
        for _ in 0..<162 { root = B163.multiply(root, root) }
        let t = B163Point(x: .zero, y: root)
        let p = try XCTUnwrap(try? B163.validatedPoint(validPublicKey))
        let coset = B163.add(p, t)                           // order 2n: on the curve, not in <G>
        XCTAssertTrue(B163.isOnCurve(coset))
        XCTAssertFalse(B163.multiply(coset, by: B163.order).isInfinity)
        assertRejected(coset.x.littleEndianBytes + coset.y.littleEndianBytes, "coset point")
    }

    func testFieldInverseRoundTrips() {
        var gen = TestBytes(seed: 163)
        for _ in 0..<20 {
            var e = B163Element(littleEndian: gen.bytes(24)[...])!
            e.clearBits(from: 163)
            guard !e.isZero else { continue }
            XCTAssertEqual(B163.multiply(e, B163.invert(e)), .one)
        }
    }
}
