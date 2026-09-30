// Bounds-checked little-endian reading and writing. Every parser in ZeppKit reads through
// `ZeppByteReader`, so a truncated or garbage input returns nil instead of trapping or reading
// past the end. All multi-byte integers in the protocol are little-endian (ZEPP_PROTOCOL.md §3.1).

import Foundation

public struct ZeppByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    /// An offset outside `0...bytes.count` is clamped, so a reader built past the end is simply at
    /// the end: every read returns nil, and `take(0)` returns `[]`.
    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = min(max(0, offset), bytes.count)
    }

    public init(_ bytes: ArraySlice<UInt8>) {
        self.init(Array(bytes))
    }

    public var remaining: Int { max(0, bytes.count - offset) }
    public var isAtEnd: Bool { remaining == 0 }

    public mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func i8() -> Int8? {
        u8().map { Int8(bitPattern: $0) }
    }

    public mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        let lo = UInt16(bytes[offset])
        let hi = UInt16(bytes[offset + 1])
        offset += 2
        return lo | (hi << 8)
    }

    public mutating func i16() -> Int16? {
        u16().map { Int16(bitPattern: $0) }
    }

    public mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 {
            let byte = UInt32(bytes[offset + i])
            value |= byte << UInt32(8 * i)
        }
        offset += 4
        return value
    }

    public mutating func i32() -> Int32? {
        u32().map { Int32(bitPattern: $0) }
    }

    public mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            let byte = UInt64(bytes[offset + i])
            value |= byte << UInt64(8 * i)
        }
        offset += 8
        return value
    }

    public mutating func i64() -> Int64? {
        u64().map { Int64(bitPattern: $0) }
    }

    public mutating func f32() -> Float? {
        u32().map { Float(bitPattern: $0) }
    }

    public mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    public mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }

    /// UTF-8 up to (and consuming) a NUL terminator; nil when there is no terminator.
    public mutating func nulTerminatedString() -> String? {
        guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        let raw = Array(bytes[offset..<end])
        offset = end + 1
        return String(decoding: raw, as: UTF8.self)
    }
}

enum ZeppLE {
    static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
    }

    static func u32(_ v: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) }
    }

    static func i16(_ v: Int16) -> [UInt8] { u16(UInt16(bitPattern: v)) }
}

public enum ZeppHex {
    /// Lower-case hex, no separators.
    public static func string<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses hex digits, ignoring spaces; nil on any other character or an odd digit count.
    public static func bytes(_ text: String) -> [UInt8]? {
        let digits = text.filter { $0 != " " }
        guard digits.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
