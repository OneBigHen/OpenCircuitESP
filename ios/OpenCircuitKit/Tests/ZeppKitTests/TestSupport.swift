// Shared helpers for ZeppKitTests. Every fixture in this target is synthetic: made-up keys,
// made-up readings, or OpenSSL-generated keypairs (B163OpenSSLVectors.swift).

import Foundation
@testable import ZeppKit

/// Hex to bytes; spaces allowed. Traps on malformed fixtures (a test-authoring error).
func hex(_ text: String) -> [UInt8] {
    guard let bytes = ZeppHex.bytes(text) else { fatalError("bad hex fixture: \(text)") }
    return bytes
}

/// OpenSSL's 21-byte big-endian octet string → the spec's 24-byte little-endian layout (§4.2).
func le24(fromBigEndian text: String) -> [UInt8] {
    let be = hex(text)
    precondition(be.count <= 24)
    return Array((Array(repeating: 0, count: 24 - be.count) + be).reversed())
}

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

/// u32 little-endian at `offset`, assembled in a loop (no long shift-or chains: those time out the
/// Swift 6.3 type-checker on this project's CI host).
func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for i in 0..<4 {
        let byte = UInt32(bytes[offset + i])
        value |= byte << UInt32(8 * i)
    }
    return value
}

let utc = TimeZone(identifier: "UTC")!

func date(_ unix: TimeInterval) -> Date { Date(timeIntervalSince1970: unix) }

/// A deterministic byte generator (xorshift) for round-trip and fuzz inputs. Not for keys.
struct TestBytes {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) } }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

/// The made-up inputs of the spec's worked example C (§4.6).
enum SpecC {
    static let phoneDrawnPrivate = Array(UInt8(0x01)...UInt8(0x18))
    static let phoneEffectivePrivate = hex("01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 01 00 00 00")
    static let strapDrawnPrivate = Array(UInt8(0x81)...UInt8(0x98))
    static let authKey = ZeppAuthKey(hex: "00112233445566778899aabbccddeeff")!
    static let strapRandom = hex("f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff")
    static let phonePubX = hex("a1 e4 ad 02 c2 a4 4e a2 41 52 96 2c 14 0e a0 63 c6 9b 2e 5c 07 00 00 00")
    static let phonePubY = hex("cd 50 73 a0 6d 67 b7 8a 3b c5 f5 19 ab 85 fb 9c f5 85 5d c8 01 00 00 00")
    static let strapPubX = hex("a3 31 15 77 49 a9 09 f0 67 ad 23 2a 5c 17 ab 6f 21 72 c3 0c 00 00 00 00")
    static let strapPubY = hex("f4 f5 5b 1a df fc 66 c5 f3 5f 29 c2 5f 89 da 07 73 fd 25 6a 05 00 00 00")
    static let sharedX = hex("31 d2 33 29 56 1a c3 f2 8c 54 4c 35 67 c7 49 dc fb 57 ab 1b 01 00 00 00")
    static let sharedY = hex("06 e8 17 31 4f 23 79 8d ed fc f2 14 68 60 70 12 e1 9e c7 be 04 00 00 00")
    static let sequenceSeed: UInt32 = 0x2933_d231
    static let sessionKey = hex("8c 45 6e 06 23 92 2f ab 73 ce 01 a0 cd dd ee ff")
    static let proofAuth = hex("e8 55 41 bb 23 2f 07 09 90 89 75 3d 86 c0 dd f0")
    static let proofSession = hex("e0 f4 c3 cc 1c 86 76 7b dd 16 70 a2 1d 60 d5 4f")

    static var strapReply: [UInt8] { [0x10, 0x04, 0x01] + strapRandom + strapPubX + strapPubY }
}
