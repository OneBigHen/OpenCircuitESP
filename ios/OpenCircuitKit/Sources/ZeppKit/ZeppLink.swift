// Bytes-in / bytes-out connection core: the chunked transport plus the auth handshake
// (ZEPP_PROTOCOL.md §3–§4). The BLE layer feeds it every notification from `…0017`/`…0016` and
// performs the writes it returns; everything else is decided here, testably, without Bluetooth.

import Foundation

/// One GATT write the caller must perform.
public struct ZeppWrite: Equatable {
    public let characteristic: ZeppCharacteristic
    public let bytes: [UInt8]

    public init(_ characteristic: ZeppCharacteristic, _ bytes: [UInt8]) {
        self.characteristic = characteristic
        self.bytes = bytes
    }
}

public struct ZeppLink {

    public enum Event: Equatable {
        case authenticated
        case authenticationFailed(ZeppAuthFailure)
        /// A decoded message on any endpoint other than auth.
        case message(ZeppMessage)
        case deviceChunkAck(handle: UInt8, count: UInt8)
        case droppedChunk(ZeppChunkDropReason)
        case undecryptable(endpoint: UInt16)
    }

    public struct Output: Equatable {
        public var writes: [ZeppWrite] = []
        public var events: [Event] = []
    }

    public private(set) var transport: ZeppChunkedTransport
    public private(set) var authenticator: ZeppAuthenticator

    public init(authKey: ZeppAuthKey, random: ZeppRandom = .system, maxWriteLength: Int = 20) {
        transport = ZeppChunkedTransport(maxWriteLength: maxWriteLength)
        authenticator = ZeppAuthenticator(authKey: authKey, random: random)
    }

    public var isAuthenticated: Bool { authenticator.state == .authenticated }

    public mutating func setMaxWriteLength(_ length: Int) {
        transport.maxWriteLength = length
    }

    /// Resets the transport (handle 0, no session) and sends the public-key message. Call it after
    /// notifications on `…0017` are enabled (§2).
    public mutating func startAuthentication() -> Output {
        transport.reset()
        var out = Output()
        let step = authenticator.start()
        apply(step, into: &out)
        if case .failed(let failure) = step.state { out.events.append(.authenticationFailed(failure)) }
        return out
    }

    /// Applies a services-list reply so later messages use the device's encryption table (§5.2).
    public mutating func apply(servicesList: ZeppServicesList) {
        transport.apply(servicesList: servicesList)
    }

    /// Chunks for one message; encrypted when the endpoint requires it.
    public mutating func send(endpoint: UInt16, payload: [UInt8]) throws -> [ZeppWrite] {
        try transport.encode(endpoint: endpoint, payload: payload).map { ZeppWrite(.chunkedWrite, $0) }
    }

    /// Feed one notification from `…0017` (device messages) or `…0016` (device chunk acks).
    public mutating func receive(_ notification: [UInt8]) -> Output {
        var out = Output()
        let received = transport.receive(notification)
        out.writes += received.acks.map { ZeppWrite(.chunkedRead, $0) }
        for event in received.events {
            switch event {
            case .deviceAck(let handle, let count):
                out.events.append(.deviceChunkAck(handle: handle, count: count))
            case .dropped(let reason):
                out.events.append(.droppedChunk(reason))
            case .undecryptable(let endpoint, _):
                out.events.append(.undecryptable(endpoint: endpoint))
            case .message(let message) where message.endpoint == ZeppEndpoint.authentication:
                let before = authenticator.state
                let step = authenticator.handle(message.payload)
                apply(step, into: &out)
                if step.state != before {
                    switch step.state {
                    case .authenticated: out.events.append(.authenticated)
                    case .failed(let failure): out.events.append(.authenticationFailed(failure))
                    default: break
                    }
                }
            case .message(let message):
                out.events.append(.message(message))
            }
        }
        return out
    }

    private mutating func apply(_ step: ZeppAuthenticator.Step, into out: inout Output) {
        if let session = step.session { transport.install(session: session) }
        guard let payload = step.send else { return }
        do {
            out.writes += try send(endpoint: ZeppEndpoint.authentication, payload: payload)
        } catch {
            // Only reachable with a write length too small to chunk anything.
            out.events.append(.authenticationFailed(.localCryptoFailure))
        }
    }
}
