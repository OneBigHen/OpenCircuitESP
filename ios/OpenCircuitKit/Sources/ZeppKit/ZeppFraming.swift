// The chunked transport framing (ZEPP_PROTOCOL.md §3.1–§3.4). A message addressed to a 16-bit
// endpoint is split into chunks written to `…0016` (phone → device) or notified on `…0017`
// (device → phone). This file only frames bytes; encryption is `ZeppSessionCrypto` and the
// stateful phone side is `ZeppChunkedTransport`.

import Foundation

/// Chunk flag bits, byte `[1]` of every chunk (§3.1).
public enum ZeppChunkFlag {
    public static let first: UInt8 = 0x01
    public static let last: UInt8 = 0x02
    /// Always set together with `last` by the sender.
    public static let ackRequested: UInt8 = 0x04
    /// Set on every chunk of an encrypted message.
    public static let encrypted: UInt8 = 0x08
}

public enum ZeppChunkCodec {

    /// Byte `[0]` of every chunk.
    public static let chunkMarker: UInt8 = 0x03
    /// Byte `[0]` of a chunk-level ack (§3.4).
    public static let ackMarker: UInt8 = 0x04
    public static let firstHeaderLength = 11
    public static let laterHeaderLength = 5
    /// ATT MTU − 3 is capped at 512 (§3.2).
    public static let maxWriteLengthCap = 512

    public enum Error: Swift.Error, Equatable {
        /// The write length cannot carry an 11-byte first header plus at least one data byte.
        case writeLengthTooSmall
        /// The chunk index is a u8; more than 256 chunks cannot be addressed.
        /// SPEC-GAP: whether the index wraps is unspecified; ZeppKit refuses such a message (no
        /// phone → device message comes near it).
        case tooManyChunks
    }

    /// Splits `body` (the plaintext payload, or the padded ciphertext of an encrypted message) into
    /// chunks. `declaredLength` goes in the first chunk's total-length field and is always the
    /// PLAINTEXT length (§3.3 step 4). `maxWriteLength` is the "(MTU − 3)" term: on iOS,
    /// `maximumWriteValueLength(for:)`.
    public static func chunks(body: [UInt8], declaredLength: Int, endpoint: UInt16, handle: UInt8,
                              encrypted: Bool, maxWriteLength: Int) throws -> [[UInt8]] {
        let writeLength = min(maxWriteLength, maxWriteLengthCap)
        guard writeLength > firstHeaderLength else { throw Error.writeLengthTooSmall }
        var out = [[UInt8]]()
        var offset = 0
        var index = 0
        while true {
            let isFirst = index == 0
            let capacity = writeLength - (isFirst ? firstHeaderLength : laterHeaderLength)
            let remaining = body.count - offset
            let isLast = remaining <= capacity
            let take = min(remaining, capacity)
            guard index <= Int(UInt8.max) else { throw Error.tooManyChunks }

            var flags: UInt8 = 0
            if isFirst { flags |= ZeppChunkFlag.first }
            if isLast { flags |= ZeppChunkFlag.last | ZeppChunkFlag.ackRequested }
            if encrypted { flags |= ZeppChunkFlag.encrypted }

            var chunk: [UInt8] = [chunkMarker, flags, 0x00, handle, UInt8(index)]
            if isFirst {
                chunk += ZeppLE.u32(UInt32(truncatingIfNeeded: declaredLength))
                chunk += ZeppLE.u16(endpoint)
            }
            chunk += body[offset..<(offset + take)]
            out.append(chunk)
            offset += take
            index += 1
            if isLast { return out }
        }
    }

    /// The 5-byte chunk ack the phone writes to `…0017` for a device message whose last chunk
    /// requested one: `04 00 <handle> 01 <count>` (§3.4).
    public static func chunkAck(handle: UInt8, count: UInt8) -> [UInt8] {
        [ackMarker, 0x00, handle, 0x01, count]
    }

    /// Size of the ciphertext for a plaintext of `length` bytes: payload + 4-byte sequence + 4-byte
    /// CRC, padded to a multiple of 16 (§3.3).
    public static func paddedCiphertextLength(plaintextLength length: Int) -> Int {
        let raw = length + 8
        return (raw + 15) / 16 * 16
    }
}

/// A fully reassembled message, before decryption.
public struct ZeppRawMessage: Equatable {
    public let endpoint: UInt16
    public let handle: UInt8
    public let encrypted: Bool
    /// The first chunk's total-length field: the plaintext length.
    public let declaredLength: Int
    /// The concatenated chunk data (ciphertext when `encrypted`).
    public let body: [UInt8]
    /// Count byte of the last chunk, for the chunk ack.
    public let lastChunkIndex: UInt8
    public let ackRequested: Bool
}

public enum ZeppChunkDropReason: Equatable {
    /// Too short for its header.
    case truncatedHeader
    /// A continuation chunk arrived with no message in progress.
    case orphanContinuation
    /// A continuation chunk carried another handle than the message in progress. The chunk is
    /// ignored; the message in progress is kept (§3.2).
    case foreignHandle(expected: UInt8, got: UInt8)
    /// A chunk index was skipped or repeated; the message in progress is discarded (§9: be stricter
    /// than Gadgetbridge, which does not check `count`).
    case chunkIndexGap(expected: UInt8, got: UInt8)
    /// More data than the declared length allows; the message is discarded.
    case overflow
    /// The last chunk arrived with less data than the declared length needs; discarded.
    case shortBody
    /// A new first chunk arrived while another message was incomplete; the old one is discarded.
    case supersededByNewMessage(handle: UInt8)
}

/// Device → phone reassembly (§3.2). Pure: feed it each `…0017` notification.
public struct ZeppChunkReassembler {

    public enum Event: Equatable {
        case message(ZeppRawMessage)
        /// A device chunk ack (`04 … <handle> … <count>`). Informational only (§3.4).
        case deviceAck(handle: UInt8, count: UInt8)
        case dropped(ZeppChunkDropReason)
        /// Not a chunk and not an ack: ignored (§3.1).
        case ignored
    }

    private struct Partial {
        let endpoint: UInt16
        let handle: UInt8
        let encrypted: Bool
        let declaredLength: Int
        let maxBodyLength: Int
        var body: [UInt8]
        var nextIndex: Int
    }

    private var partial: Partial?

    public init() {}

    public var hasMessageInProgress: Bool { partial != nil }

    public mutating func reset() { partial = nil }

    /// Returns the events one notification produced (usually zero or one).
    public mutating func accept(_ chunk: [UInt8]) -> [Event] {
        guard let marker = chunk.first else { return [.ignored] }
        if marker == ZeppChunkCodec.ackMarker {
            guard chunk.count >= 5 else { return [.ignored] }
            return [.deviceAck(handle: chunk[2], count: chunk[4])]
        }
        guard marker == ZeppChunkCodec.chunkMarker else { return [.ignored] }
        guard chunk.count >= ZeppChunkCodec.laterHeaderLength else { return [.dropped(.truncatedHeader)] }

        let flags = chunk[1]
        let handle = chunk[3]
        let index = chunk[4]
        let isFirst = flags & ZeppChunkFlag.first != 0
        let isLast = flags & ZeppChunkFlag.last != 0
        var events = [Event]()

        if isFirst {
            guard chunk.count >= ZeppChunkCodec.firstHeaderLength else { return [.dropped(.truncatedHeader)] }
            if let old = partial {
                events.append(.dropped(.supersededByNewMessage(handle: old.handle)))
                partial = nil
            }
            guard index == 0 else {
                events.append(.dropped(.chunkIndexGap(expected: 0, got: index)))
                return events
            }
            var reader = ZeppByteReader(chunk, offset: 5)
            guard let total = reader.u32(), let endpoint = reader.u16() else {
                events.append(.dropped(.truncatedHeader))
                return events
            }
            let encrypted = flags & ZeppChunkFlag.encrypted != 0
            let declared = Int(total)
            let maxBody = encrypted ? ZeppChunkCodec.paddedCiphertextLength(plaintextLength: declared) : declared
            partial = Partial(endpoint: endpoint, handle: handle, encrypted: encrypted,
                              declaredLength: declared, maxBodyLength: maxBody,
                              body: [], nextIndex: 0)
        } else {
            guard let current = partial else { return [.dropped(.orphanContinuation)] }
            guard handle == current.handle else {
                return [.dropped(.foreignHandle(expected: current.handle, got: handle))]
            }
        }

        guard var current = partial else { return events }
        guard Int(index) == current.nextIndex else {
            partial = nil
            events.append(.dropped(.chunkIndexGap(expected: UInt8(truncatingIfNeeded: current.nextIndex),
                                                  got: index)))
            return events
        }
        let dataStart = isFirst ? ZeppChunkCodec.firstHeaderLength : ZeppChunkCodec.laterHeaderLength
        current.body += chunk[dataStart...]
        current.nextIndex += 1
        guard current.body.count <= current.maxBodyLength else {
            partial = nil
            events.append(.dropped(.overflow))
            return events
        }
        guard isLast else {
            partial = current
            return events
        }
        partial = nil
        guard bodyIsComplete(current) else {
            events.append(.dropped(.shortBody))
            return events
        }
        events.append(.message(ZeppRawMessage(endpoint: current.endpoint, handle: current.handle,
                                              encrypted: current.encrypted,
                                              declaredLength: current.declaredLength,
                                              body: current.body, lastChunkIndex: index,
                                              ackRequested: flags & ZeppChunkFlag.ackRequested != 0)))
        return events
    }

    private func bodyIsComplete(_ p: Partial) -> Bool {
        guard p.encrypted else { return p.body.count == p.declaredLength }
        // SPEC-GAP: is the device's ciphertext always pad16(L + 8) (a `seq ‖ CRC` trailer like ours,
        // §3.3 🔴)? Accept any whole number of blocks that covers the plaintext and fits the padded
        // maximum, which is what decrypt-then-truncate needs.
        let minimum = (p.declaredLength + 15) / 16 * 16
        return p.body.count % ZeppAES.blockLength == 0
            && p.body.count >= minimum
            && p.body.count <= p.maxBodyLength
    }
}
