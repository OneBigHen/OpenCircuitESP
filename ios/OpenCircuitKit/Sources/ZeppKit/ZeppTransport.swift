// The phone's side of the chunked protocol as one value type: outgoing handle counter,
// per-endpoint encryption, session crypto and reassembly (ZEPP_PROTOCOL.md §3). Pure — it never
// touches Bluetooth; the caller writes the returned chunks and feeds back notifications.

import Foundation

/// A decoded device → phone message.
public struct ZeppMessage: Equatable {
    public let endpoint: UInt16
    public let payload: [UInt8]
    public let handle: UInt8
    public let wasEncrypted: Bool
    /// See `ZeppSessionCrypto.Opened.trailerCRCMatches`; nil for plaintext messages.
    public let trailerCRCMatches: Bool?
}

public struct ZeppChunkedTransport {

    public enum Error: Swift.Error, Equatable {
        /// The endpoint is encrypted and no session is installed yet (auth not done).
        case notAuthenticated(endpoint: UInt16)
    }

    public enum Event: Equatable {
        case message(ZeppMessage)
        case deviceAck(handle: UInt8, count: UInt8)
        case dropped(ZeppChunkDropReason)
        /// An encrypted message that could not be decrypted (no session, or a bad length).
        case undecryptable(endpoint: UInt16, handle: UInt8)
    }

    public struct Received: Equatable {
        public var events: [Event] = []
        /// Chunk acks to write to `…0017`, in order.
        public var acks: [[UInt8]] = []
    }

    /// The "(MTU − 3)" term used for chunking (§3.2). Update it when the OS reports a new value.
    public var maxWriteLength: Int
    /// Handle of the last message sent; the next message uses this + 1 (wrapping), so the first
    /// message after a reset uses 0x01 (§3.1).
    public private(set) var lastHandle: UInt8 = 0
    public private(set) var session: ZeppSessionCrypto?
    public private(set) var encryption = ZeppEndpointEncryption()
    private var reassembler = ZeppChunkReassembler()

    public init(maxWriteLength: Int = 20) {
        self.maxWriteLength = maxWriteLength
    }

    /// Every (re)connect and re-auth starts from scratch: handle 0, no session, default
    /// encryption table, nothing half-reassembled (§9).
    public mutating func reset() {
        lastHandle = 0
        session = nil
        encryption = ZeppEndpointEncryption()
        reassembler.reset()
    }

    public mutating func install(session: ZeppSessionCrypto) {
        self.session = session
    }

    public mutating func apply(servicesList: ZeppServicesList) {
        encryption.apply(servicesList)
    }

    public func isEncrypted(endpoint: UInt16) -> Bool {
        encryption.isEncrypted(endpoint)
    }

    /// Chunks for one phone → device message, encrypted when the endpoint requires it.
    public mutating func encode(endpoint: UInt16, payload: [UInt8]) throws -> [[UInt8]] {
        let encrypted = encryption.isEncrypted(endpoint)
        if encrypted, session == nil { throw Error.notAuthenticated(endpoint: endpoint) }
        let handle = lastHandle &+ 1
        var body = payload
        var pendingSession = session
        if encrypted, var crypto = pendingSession {
            body = try crypto.seal(payload, handle: handle)
            pendingSession = crypto
        }
        let chunks = try ZeppChunkCodec.chunks(body: body, declaredLength: payload.count,
                                               endpoint: endpoint, handle: handle,
                                               encrypted: encrypted, maxWriteLength: maxWriteLength)
        // Commit the handle and sequence only once the whole message was built.
        lastHandle = handle
        session = pendingSession
        return chunks
    }

    /// Feed one `…0017` (or `…0016`) notification.
    public mutating func receive(_ notification: [UInt8]) -> Received {
        var out = Received()
        for event in reassembler.accept(notification) {
            switch event {
            case .ignored:
                continue
            case .deviceAck(let handle, let count):
                out.events.append(.deviceAck(handle: handle, count: count))
            case .dropped(let reason):
                out.events.append(.dropped(reason))
            case .message(let raw):
                guard let message = decode(raw) else {
                    out.events.append(.undecryptable(endpoint: raw.endpoint, handle: raw.handle))
                    continue
                }
                // SPEC-GAP: whether the device needs an ack for a message we could not use is
                // unknown (§3.4 / §10 item 6). Ack only messages that were delivered intact.
                if raw.ackRequested {
                    out.acks.append(ZeppChunkCodec.chunkAck(handle: raw.handle, count: raw.lastChunkIndex))
                }
                out.events.append(.message(message))
            }
        }
        return out
    }

    private func decode(_ raw: ZeppRawMessage) -> ZeppMessage? {
        guard raw.encrypted else {
            return ZeppMessage(endpoint: raw.endpoint, payload: raw.body, handle: raw.handle,
                               wasEncrypted: false, trailerCRCMatches: nil)
        }
        guard let session,
              let opened = try? session.open(raw.body, handle: raw.handle,
                                             plaintextLength: raw.declaredLength) else { return nil }
        return ZeppMessage(endpoint: raw.endpoint, payload: opened.payload, handle: raw.handle,
                           wasEncrypted: true, trailerCRCMatches: opened.trailerCRCMatches)
    }
}
