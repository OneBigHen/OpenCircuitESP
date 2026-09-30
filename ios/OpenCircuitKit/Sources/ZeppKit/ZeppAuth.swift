// The auth handshake on endpoint 0x0082 (ZEPP_PROTOCOL.md §4) as a pure state machine over
// message payloads: it never sees chunks or Bluetooth. `ZeppLink` wraps it with the transport.

import Foundation

/// The 16-byte key Zepp's cloud mints at pairing (§4.1). Its bytes never appear in a description,
/// debug description or reflection, so it cannot leak through `print`, `dump` or string
/// interpolation.
public struct ZeppAuthKey: Equatable {
    let bytes: [UInt8]

    /// Accepts exactly: optional `0x`/`0X`, then 32 hex digits, surrounding whitespace trimmed.
    /// Anything else is nil — never a fallback key (§4.1, §9 #12).
    public init?(hex text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
        guard digits.count == 32 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(16)
        var high: UInt8?
        for character in digits {
            guard let ascii = character.asciiValue, let nibble = Self.nibble(ascii) else { return nil }
            if let h = high {
                out.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        bytes = out
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    private static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x41...0x46: return ascii - 0x41 + 10
        case 0x61...0x66: return ascii - 0x61 + 10
        default: return nil
        }
    }
}

extension ZeppAuthKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ZeppAuthKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Session parameters from the 48-byte shared point (§4.4).
public enum ZeppSessionKeys {
    /// Session key = shared[8..<24] XOR auth key; sequence seed = u32 LE of shared[0..<4].
    public static func derive(sharedSecret: [UInt8], authKey: ZeppAuthKey) throws -> ZeppSessionCrypto {
        guard sharedSecret.count == B163.sharedSecretLength else { throw B163.Error.invalidLength }
        let key = (0..<16).map { sharedSecret[8 + $0] ^ authKey.bytes[$0] }
        var reader = ZeppByteReader(sharedSecret)
        let seed = reader.u32() ?? 0
        return try ZeppSessionCrypto(sessionKey: key, sequenceSeed: seed)
    }
}

public enum ZeppAuthFailure: Swift.Error, Equatable {
    /// `10 05 25`: the strap rejected our proof. The key is wrong or was invalidated (unpaired in
    /// Zepp, or the strap was reset). Surface "key rejected: re-extract it" (§4.4).
    case wrongAuthKey
    /// A non-`01` status on the public-key reply.
    case publicKeyRejected(status: UInt8)
    /// A non-`01`, non-`25` status on the session reply.
    case sessionRejected(status: UInt8)
    /// The public-key reply was shorter than 67 bytes.
    case malformedReply
    /// The strap's public key failed validation.
    case invalidDevicePublicKey
    /// Key generation, ECDH or AES failed locally.
    case localCryptoFailure
}

public struct ZeppAuthenticator {

    public enum State: Equatable {
        case idle
        case awaitingPublicKeyReply
        case awaitingSessionReply
        case authenticated
        case failed(ZeppAuthFailure)
    }

    /// What one step asks the caller to do.
    public struct Step: Equatable {
        /// A payload to send on the auth endpoint (plaintext), if any.
        public var send: [UInt8]?
        /// Install these session parameters NOW — before the `05` message goes out (§4.4).
        public var session: ZeppSessionCrypto?
        public var state: State
    }

    /// Byte `[0]` of every strap reply on the auth endpoint.
    public static let responseMarker: UInt8 = 0x10
    public static let publicKeyCommand: UInt8 = 0x04
    public static let sessionCommand: UInt8 = 0x05
    /// The fixed, unexplained bytes after the `04` command (§4.3).
    public static let publicKeyPreamble: [UInt8] = [0x02, 0x00, 0x02]
    public static let statusSuccess: UInt8 = 0x01
    public static let statusWrongKey: UInt8 = 0x25
    /// `10 04 01` + 16-byte random + 48-byte public key.
    public static let publicKeyReplyLength = 3 + 16 + B163.publicKeyLength

    public private(set) var state: State = .idle
    private let authKey: ZeppAuthKey
    private let random: ZeppRandom
    private var keyPair: B163.KeyPair?

    public init(authKey: ZeppAuthKey, random: ZeppRandom = .system) {
        self.authKey = authKey
        self.random = random
    }

    /// Generates a fresh ephemeral keypair and returns the `04 02 00 02 ‖ phonePub` payload.
    public mutating func start() -> Step {
        guard let pair = try? B163.generateKeyPair(using: random) else {
            return fail(.localCryptoFailure)
        }
        keyPair = pair
        state = .awaitingPublicKeyReply
        return Step(send: [Self.publicKeyCommand] + Self.publicKeyPreamble + pair.publicKey,
                    session: nil, state: state)
    }

    /// Feed one reassembled payload from the auth endpoint. Payloads that are not a reply to the
    /// command we are waiting for are ignored (the state is unchanged, nothing to send).
    public mutating func handle(_ payload: [UInt8]) -> Step {
        guard payload.count >= 3, payload[0] == Self.responseMarker else { return idleStep }
        switch (state, payload[1]) {
        case (.awaitingPublicKeyReply, Self.publicKeyCommand):
            return handlePublicKeyReply(payload)
        case (.awaitingSessionReply, Self.sessionCommand):
            switch payload[2] {
            case Self.statusSuccess:
                state = .authenticated
                return Step(send: nil, session: nil, state: state)
            case Self.statusWrongKey:
                return fail(.wrongAuthKey)
            default:
                return fail(.sessionRejected(status: payload[2]))
            }
        default:
            return idleStep
        }
    }

    private var idleStep: Step { Step(send: nil, session: nil, state: state) }

    private mutating func handlePublicKeyReply(_ payload: [UInt8]) -> Step {
        guard payload[2] == Self.statusSuccess else { return fail(.publicKeyRejected(status: payload[2])) }
        // SPEC-GAP: §10 item 3 expects exactly 67 bytes; a longer reply is accepted and its tail ignored.
        guard payload.count >= Self.publicKeyReplyLength else { return fail(.malformedReply) }
        guard let pair = keyPair else { return fail(.localCryptoFailure) }
        let deviceRandom = Array(payload[3..<19])
        let devicePublicKey = Array(payload[19..<67])
        let shared: [UInt8]
        do {
            shared = try B163.sharedSecret(privateKey: pair.privateKey, peerPublicKey: devicePublicKey)
        } catch B163.Error.invalidPublicKey {
            return fail(.invalidDevicePublicKey)
        } catch {
            return fail(.localCryptoFailure)
        }
        // The ephemeral private key is not needed again.
        keyPair = nil
        guard let session = try? ZeppSessionKeys.derive(sharedSecret: shared, authKey: authKey),
              let proofAuth = try? ZeppAES.encryptECB(key: authKey.bytes, deviceRandom),
              let proofSession = try? ZeppAES.encryptECB(key: session.sessionKey, deviceRandom) else {
            return fail(.localCryptoFailure)
        }
        state = .awaitingSessionReply
        return Step(send: [Self.sessionCommand] + proofAuth + proofSession, session: session, state: state)
    }

    private mutating func fail(_ failure: ZeppAuthFailure) -> Step {
        keyPair = nil
        state = .failed(failure)
        return Step(send: nil, session: nil, state: state)
    }
}
