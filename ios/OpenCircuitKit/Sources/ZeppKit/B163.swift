// NIST B-163 (sect163r2) elliptic-curve Diffie-Hellman, as the Zepp OS auth handshake needs it
// (ZEPP_PROTOCOL.md §4.1–§4.2). CryptoKit has no binary curves, so the curve maths is ported.
//
// ATTRIBUTION: the field arithmetic (shift-and-add multiplication, binary extended-Euclid
// inversion), the affine point double/add formulas, the double-and-add scalar multiplication, the
// on-curve test and the key-generation rules below are a Swift port of tiny-ECDH-c by kokke,
// https://github.com/kokke/tiny-ECDH-c (ecdh.c, commit a6095d6), which is released into the PUBLIC
// DOMAIN under the Unlicense ("This is free and unencumbered software released into the public
// domain…", see http://unlicense.org). The curve constants are tiny-ECDH-c's NIST_B163 set, which
// are the FIPS 186 / SEC 2 sect163r2 parameters.
//
// Differences from tiny-ECDH-c, all hardening:
//   • field elements are three UInt64 limbs instead of six UInt32 words (same bits, same byte
//     encoding on the wire: 24 bytes, little-endian);
//   • a peer public key is also rejected when a coordinate has a bit ≥ 163 set, when X is zero
//     (the curve's order-2 point), and when it lies outside the prime-order subgroup (n·P ≠ ∞);
//   • key generation also rejects a scalar that is too small AFTER the top bits are cleared, and
//     a shared secret that is the point at infinity is an error rather than 48 zero bytes.
//
// Like tiny-ECDH-c this is NOT constant-time. The phone's key is ephemeral (one per connection),
// which limits what a timing observer could learn.

import Foundation

/// One element of GF(2^163), three 64-bit limbs, least-significant first. Also used for scalars,
/// which share the 192-bit container.
struct B163Element: Equatable {
    var l0: UInt64
    var l1: UInt64
    var l2: UInt64

    static let zero = B163Element(l0: 0, l1: 0, l2: 0)
    static let one = B163Element(l0: 1, l1: 0, l2: 0)

    /// From tiny-ECDH-c's six little-endian 32-bit words.
    init(words w: [UInt32]) {
        precondition(w.count == 6)
        l0 = UInt64(w[0]) | UInt64(w[1]) << 32
        l1 = UInt64(w[2]) | UInt64(w[3]) << 32
        l2 = UInt64(w[4]) | UInt64(w[5]) << 32
    }

    init(l0: UInt64, l1: UInt64, l2: UInt64) {
        self.l0 = l0
        self.l1 = l1
        self.l2 = l2
    }

    /// 24 bytes, little-endian (ZEPP_PROTOCOL.md §4.2).
    init?(littleEndian bytes: ArraySlice<UInt8>) {
        guard bytes.count == 24 else { return nil }
        var limbs: [UInt64] = [0, 0, 0]
        for (i, byte) in bytes.enumerated() {
            limbs[i / 8] |= UInt64(byte) << UInt64((i % 8) * 8)
        }
        l0 = limbs[0]
        l1 = limbs[1]
        l2 = limbs[2]
    }

    var littleEndianBytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(24)
        for limb in [l0, l1, l2] {
            for shift in stride(from: 0, to: 64, by: 8) {
                out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        return out
    }

    var isZero: Bool { l0 == 0 && l1 == 0 && l2 == 0 }

    /// Index of the highest set bit + 1 (0 for zero), as tiny-ECDH-c's `bitvec_degree`.
    var degree: Int {
        if l2 != 0 { return 192 - l2.leadingZeroBitCount }
        if l1 != 0 { return 128 - l1.leadingZeroBitCount }
        if l0 != 0 { return 64 - l0.leadingZeroBitCount }
        return 0
    }

    @inline(__always)
    func bit(_ i: Int) -> Bool {
        switch i / 64 {
        case 0: return (l0 >> UInt64(i % 64)) & 1 == 1
        case 1: return (l1 >> UInt64(i % 64)) & 1 == 1
        case 2: return (l2 >> UInt64(i % 64)) & 1 == 1
        default: return false
        }
    }

    mutating func clearBits(from index: Int) {
        for i in index..<192 {
            let mask = ~(UInt64(1) << UInt64(i % 64))
            switch i / 64 {
            case 0: l0 &= mask
            case 1: l1 &= mask
            default: l2 &= mask
            }
        }
    }

    @inline(__always)
    static func ^ (a: B163Element, b: B163Element) -> B163Element {
        B163Element(l0: a.l0 ^ b.l0, l1: a.l1 ^ b.l1, l2: a.l2 ^ b.l2)
    }

    /// Left shift within the 192-bit container; bits shifted past bit 191 are lost (as in the C).
    func shiftedLeft(_ n: Int) -> B163Element {
        if n <= 0 { return self }
        if n >= 192 { return .zero }
        var a0 = l0
        var a1 = l1
        var a2 = l2
        switch n / 64 {
        case 1:
            a2 = a1; a1 = a0; a0 = 0
        case 2:
            a2 = a0; a1 = 0; a0 = 0
        default:
            break
        }
        let b = UInt64(n % 64)
        if b != 0 {
            a2 = (a2 << b) | (a1 >> (64 - b))
            a1 = (a1 << b) | (a0 >> (64 - b))
            a0 = a0 << b
        }
        return B163Element(l0: a0, l1: a1, l2: a2)
    }
}

/// Affine point; (0, 0) is the point at infinity, as in tiny-ECDH-c (it is not on the curve
/// because b ≠ 0).
struct B163Point: Equatable {
    var x: B163Element
    var y: B163Element

    static let infinity = B163Point(x: .zero, y: .zero)
    var isInfinity: Bool { x.isZero && y.isZero }
}

/// NIST B-163 / sect163r2 ECDH with the Zepp wire layout (ZEPP_PROTOCOL.md §4.2).
public enum B163 {

    public static let privateKeyLength = 24
    public static let publicKeyLength = 48
    public static let sharedSecretLength = 48
    /// The field degree m of GF(2^m).
    static let degree = 163

    public enum Error: Swift.Error, Equatable {
        case invalidLength
        /// The peer's public key failed validation; `reason` is for logs and tests.
        case invalidPublicKey(reason: String)
        /// The private scalar has fewer than 81 significant bits.
        case privateKeyTooSmall
        /// No acceptable private key after this many draws (a broken RNG).
        case randomSourceExhausted
        /// The shared point came out as the point at infinity.
        case degenerateSharedSecret
    }

    public struct KeyPair: Equatable {
        /// The EFFECTIVE scalar (bits ≥ 162 already cleared), 24 bytes little-endian.
        public let privateKey: [UInt8]
        /// X ‖ Y, 24 bytes each, little-endian.
        public let publicKey: [UInt8]
    }

    // MARK: Curve constants (tiny-ECDH-c's NIST_B163 set, 32-bit words, least-significant first)

    /// Reduction polynomial x^163 + x^7 + x^6 + x^3 + 1.
    static let polynomial = B163Element(words: [0x0000_00c9, 0, 0, 0, 0, 0x0000_0008])
    /// Curve y² + xy = x³ + a·x² + b with a = 1.
    static let coefficientB = B163Element(words: [0x4a32_05fd, 0x512f_7874, 0x1481_eb10,
                                                  0xb8c9_53ca, 0x0a60_1907, 0x0000_0002])
    static let generator = B163Point(
        x: B163Element(words: [0xe834_3e36, 0xd499_4637, 0xa099_1168,
                               0x86a2_d57e, 0xf0eb_a162, 0x0000_0003]),
        y: B163Element(words: [0x7973_24f1, 0xb11c_5c0c, 0xa2cd_d545,
                               0x71a0_094f, 0xd51f_bc6c, 0x0000_0000]))
    /// Order n of the generator (cofactor 2).
    static let order = B163Element(words: [0xa423_4c33, 0x77e7_0c12, 0x0002_92fe, 0, 0, 0x0000_0004])

    // MARK: Field arithmetic, GF(2^163)

    static func multiply(_ x: B163Element, _ y: B163Element) -> B163Element {
        var z = y.bit(0) ? x : .zero
        var t = x
        for i in 1..<degree {
            // t = 2^i · x, reduced whenever it reaches degree 163.
            t = B163Element(l0: t.l0 << 1,
                            l1: (t.l1 << 1) | (t.l0 >> 63),
                            l2: (t.l2 << 1) | (t.l1 >> 63))
            if t.bit(degree) { t = t ^ polynomial }
            if y.bit(i) { z = z ^ t }
        }
        return z
    }

    /// 1/x. `x` must be non-zero; every caller guarantees it (the point formulas never invert 0).
    static func invert(_ x: B163Element) -> B163Element {
        precondition(!x.isZero, "B163: inverse of zero")
        var u = x
        var v = polynomial
        var g = B163Element.zero
        var z = B163Element.one
        while u != .one {
            var i = u.degree - v.degree
            if i < 0 {
                swap(&u, &v)
                swap(&g, &z)
                i = -i
            }
            u = u ^ v.shiftedLeft(i)
            z = z ^ g.shiftedLeft(i)
        }
        return z
    }

    // MARK: Point arithmetic (a = 1)

    static func double(_ p: B163Point) -> B163Point {
        if p.x.isZero { return .infinity }
        // λ = x + y/x; x' = λ² + λ + a; y' = x² + (λ + 1)·x'
        var l = multiply(invert(p.x), p.y) ^ p.x
        let xx = multiply(p.x, p.x)
        var x3 = multiply(l, l)
        l = l ^ .one
        x3 = x3 ^ l
        let y3 = xx ^ multiply(l, x3)
        return B163Point(x: x3, y: y3)
    }

    static func add(_ p: B163Point, _ q: B163Point) -> B163Point {
        if q.isInfinity { return p }
        if p.isInfinity { return q }
        if p.x == q.x {
            return p.y == q.y ? double(p) : .infinity
        }
        // λ = (y1 + y2)/(x1 + x2); x3 = λ² + λ + x1 + x2 + a; y3 = λ·(x1 + x3) + x3 + y1
        let sumY = p.y ^ q.y
        let sumX = p.x ^ q.x
        let lambda = multiply(invert(sumX), sumY)
        let x3 = multiply(lambda, lambda) ^ lambda ^ sumX ^ .one
        let y3 = multiply(p.x ^ x3, lambda) ^ x3 ^ p.y
        return B163Point(x: x3, y: y3)
    }

    /// k·P by double-and-add from the scalar's top bit.
    static func multiply(_ p: B163Point, by k: B163Element) -> B163Point {
        var acc = B163Point.infinity
        var i = k.degree - 1
        while i >= 0 {
            acc = double(acc)
            if k.bit(i) { acc = add(acc, p) }
            i -= 1
        }
        return acc
    }

    /// y² + xy == x³ + x² + b. The point at infinity counts as on the curve, as in tiny-ECDH-c;
    /// public-key validation rejects it separately.
    static func isOnCurve(_ p: B163Point) -> Bool {
        if p.isInfinity { return true }
        let xx = multiply(p.x, p.x)
        let rhs = multiply(xx, p.x) ^ xx ^ coefficientB
        let lhs = multiply(p.y, p.y) ^ multiply(p.x, p.y)
        return lhs == rhs
    }

    // MARK: Keys

    /// The number of significant bits a drawn private key must have (163 / 2, integer division).
    static let minimumPrivateKeyDegree = degree / 2
    /// Every bit from this index upward is cleared from a private key (degree(n) − 1 = 162).
    static let privateKeyClearFromBit = 162

    /// The effective scalar for 24 drawn bytes: bits ≥ 162 cleared (byte 20 masked to its low two
    /// bits, bytes 21–23 zeroed). Throws when the drawn value, or the cleared value, has fewer
    /// than 81 significant bits (§4.2: "draw again").
    public static func effectivePrivateKey(_ drawn: [UInt8]) throws -> [UInt8] {
        guard drawn.count == privateKeyLength,
              var k = B163Element(littleEndian: drawn[...]) else { throw Error.invalidLength }
        guard k.degree >= minimumPrivateKeyDegree else { throw Error.privateKeyTooSmall }
        k.clearBits(from: privateKeyClearFromBit)
        guard k.degree >= minimumPrivateKeyDegree else { throw Error.privateKeyTooSmall }
        return k.littleEndianBytes
    }

    /// Draws private keys from `random` until one is acceptable, then derives the public key.
    public static func generateKeyPair(using random: ZeppRandom, maxAttempts: Int = 32) throws -> KeyPair {
        for _ in 0..<maxAttempts {
            let drawn = try random.bytes(privateKeyLength)
            guard let effective = try? effectivePrivateKey(drawn) else { continue }
            return KeyPair(privateKey: effective, publicKey: try publicKey(forPrivateKey: effective))
        }
        throw Error.randomSourceExhausted
    }

    /// d·G for a private key (bits ≥ 162 are cleared first).
    public static func publicKey(forPrivateKey privateKey: [UInt8]) throws -> [UInt8] {
        let k = try scalar(privateKey)
        let p = multiply(generator, by: k)
        guard !p.isInfinity else { throw Error.privateKeyTooSmall }
        return p.x.littleEndianBytes + p.y.littleEndianBytes
    }

    /// The 48-byte shared POINT (X ‖ Y, §4.2) of our private key and the peer's validated public key.
    public static func sharedSecret(privateKey: [UInt8], peerPublicKey: [UInt8]) throws -> [UInt8] {
        let k = try scalar(privateKey)
        let peer = try validatedPoint(peerPublicKey)
        let s = multiply(peer, by: k)
        guard !s.isInfinity else { throw Error.degenerateSharedSecret }
        return s.x.littleEndianBytes + s.y.littleEndianBytes
    }

    /// Throws `invalidPublicKey` unless `publicKey` is a 48-byte encoding of a point of the
    /// prime-order subgroup (§4.2: reject infinity and off-curve points; the rest is hardening).
    public static func validatePublicKey(_ publicKey: [UInt8]) throws {
        _ = try validatedPoint(publicKey)
    }

    static func validatedPoint(_ bytes: [UInt8]) throws -> B163Point {
        guard bytes.count == publicKeyLength,
              let x = B163Element(littleEndian: bytes[0..<24]),
              let y = B163Element(littleEndian: bytes[24..<48]) else { throw Error.invalidLength }
        guard x.degree <= degree, y.degree <= degree else {
            throw Error.invalidPublicKey(reason: "coordinate not reduced (bit >= 163 set)")
        }
        let p = B163Point(x: x, y: y)
        guard !p.isInfinity else { throw Error.invalidPublicKey(reason: "point at infinity") }
        guard !x.isZero else { throw Error.invalidPublicKey(reason: "order-2 point (x = 0)") }
        guard isOnCurve(p) else { throw Error.invalidPublicKey(reason: "not on the curve") }
        guard multiply(p, by: order).isInfinity else {
            throw Error.invalidPublicKey(reason: "not in the prime-order subgroup")
        }
        return p
    }

    static func scalar(_ privateKey: [UInt8]) throws -> B163Element {
        guard privateKey.count == privateKeyLength,
              var k = B163Element(littleEndian: privateKey[...]) else { throw Error.invalidLength }
        k.clearBits(from: privateKeyClearFromBit)
        guard !k.isZero else { throw Error.privateKeyTooSmall }
        return k
    }
}
