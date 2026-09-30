// Message encryption for the chunked transport (ZEPP_PROTOCOL.md §3.3), keyed by the session
// parameters the auth handshake derives (§4.4).

import Foundation

public struct ZeppSessionCrypto: Equatable {

    public enum Error: Swift.Error, Equatable {
        case invalidSessionKey
        case ciphertextTooShort
    }

    /// 16 bytes. Secret: never logged (see `description`).
    let sessionKey: [UInt8]
    /// The encrypted-sequence number the NEXT encrypted message will carry.
    public private(set) var nextSequence: UInt32

    public init(sessionKey: [UInt8], sequenceSeed: UInt32) throws {
        guard sessionKey.count == ZeppAES.keyLength else { throw Error.invalidSessionKey }
        self.sessionKey = sessionKey
        self.nextSequence = sequenceSeed
    }

    /// The session key with every byte XORed with the message's handle (§3.3 step 2).
    func messageKey(handle: UInt8) -> [UInt8] {
        sessionKey.map { $0 ^ handle }
    }

    /// `AES-ECB(messageKey, P ‖ S ‖ CRC32(P ‖ S) ‖ zero padding)`, consuming one sequence number.
    public mutating func seal(_ plaintext: [UInt8], handle: UInt8) throws -> [UInt8] {
        var buffer = plaintext + ZeppLE.u32(nextSequence)
        buffer += ZeppLE.u32(ZeppCRC32.checksum(buffer))
        let padded = ZeppChunkCodec.paddedCiphertextLength(plaintextLength: plaintext.count)
        buffer += [UInt8](repeating: 0, count: padded - buffer.count)
        let sealed = try ZeppAES.encryptECB(key: messageKey(handle: handle), buffer)
        nextSequence &+= 1
        return sealed
    }

    public struct Opened: Equatable {
        public let payload: [UInt8]
        /// Whether the bytes after the payload are `S ‖ CRC32(P ‖ S)` as in our own messages; nil
        /// when the ciphertext is too short to hold such a trailer. Diagnostic only: Gadgetbridge
        /// checks neither the device's sequence number nor its CRC, and whether the device's
        /// trailer has our layout is unconfirmed (§3.3 🔴, §10 item 5). It is NOT enforced.
        public let trailerCRCMatches: Bool?
        /// The device's trailing sequence number under the same assumption; nil as above.
        public let trailerSequence: UInt32?
    }

    /// Decrypts with the INCOMING message's handle and keeps the first `plaintextLength` bytes.
    public func open(_ ciphertext: [UInt8], handle: UInt8, plaintextLength: Int) throws -> Opened {
        guard plaintextLength >= 0, ciphertext.count >= plaintextLength else { throw Error.ciphertextTooShort }
        let plain = try ZeppAES.decryptECB(key: messageKey(handle: handle), ciphertext)
        let payload = Array(plain[0..<plaintextLength])
        guard plain.count >= plaintextLength + 8 else {
            return Opened(payload: payload, trailerCRCMatches: nil, trailerSequence: nil)
        }
        var reader = ZeppByteReader(plain, offset: plaintextLength)
        let sequence = reader.u32()
        let crc = reader.u32()
        let expected = ZeppCRC32.checksum(plain[0..<(plaintextLength + 4)])
        return Opened(payload: payload, trailerCRCMatches: crc == expected, trailerSequence: sequence)
    }
}

extension ZeppSessionCrypto: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ZeppSessionCrypto(<redacted>, nextSequence: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
