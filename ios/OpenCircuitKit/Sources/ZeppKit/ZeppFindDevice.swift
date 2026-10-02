// Find device, find phone and the short buzz (ZEPP_PROTOCOL.md §11, §13.2, §15.4) on endpoint
// 0x001A, as a pure state machine: idle → buzzing → stopped. Time is an input (`now`); the caller
// runs a timer to `nextDeadline` and calls `tick(now:)`.
//
// Safety rules it enforces:
// - nothing is sent unless `ZeppControlCapabilities` supports the control on this connection;
// - every `03` is paired with a `06`: the user's stop, the phone-side cap (60 s at most, never the
//   strap's own timeout), the end of a buzz, and, when the link dropped mid-find, once on the next
//   connection that supports find device (§11.4, §15.4);
// - nothing starts on its own: only `start` and `buzz` send `03` (§15.4).

import Foundation

/// A message a control machine asks the caller to send with `ZeppLink.send(endpoint:payload:)`.
public struct ZeppControlMessage: Equatable {
    public let endpoint: UInt16
    public let payload: [UInt8]

    public init(endpoint: UInt16, payload: [UInt8]) {
        self.endpoint = endpoint
        self.payload = payload
    }
}

/// Phone → strap payloads on endpoint 0x001A (§11.3). Opcodes `05`, `08`–`10` and above `15` are
/// never sent.
public enum ZeppFindDeviceCommand {
    /// Capabilities request; the reply carries the find-device version (§11.2).
    public static let capabilitiesRequest: [UInt8] = [0x01]
    /// Start "find device": the strap starts vibrating.
    public static let start: [UInt8] = [0x03]
    /// Stop "find device".
    public static let stop: [UInt8] = [0x06]
    /// Acknowledges the strap's find-phone request `11` (`01` = success).
    public static let findPhoneAck: [UInt8] = [0x12, 0x01]
    /// The phone ends "find phone" (the user found it).
    public static let endFindPhone: [UInt8] = [0x14]
}

/// Find-phone mode byte of `15 <mode>` (§11.3).
public enum ZeppFindPhoneMode: Equatable {
    case vibrateOnly
    case ring
    case other(UInt8)

    public init(_ byte: UInt8) {
        switch byte {
        case 0x00: self = .vibrateOnly
        case 0x01: self = .ring
        default: self = .other(byte)
        }
    }
}

/// Strap → phone messages on endpoint 0x001A (§11.3).
public enum ZeppFindDeviceMessage: Equatable {
    /// A well-formed capabilities reply `02 01 <version>` (exactly 3 bytes, §11.2, §14).
    case capabilities(version: UInt8)
    /// Any other reply starting `02`: ignored, the version is left as it was (§11.2).
    case malformedCapabilities
    /// `04`: the strap acknowledges a start. Further bytes are not read.
    case startAcknowledged
    /// `07`: the strap stopped "find device" on its own side.
    case stoppedByStrap
    /// `11`: the strap asks the phone to ring.
    case findPhoneRequested
    /// `13`: the strap ends "find phone".
    case findPhoneEnded
    /// `15 <mode>`.
    case findPhoneMode(ZeppFindPhoneMode)

    /// nil for an empty payload, an unknown opcode, or `15` without its mode byte.
    public static func parse(_ payload: [UInt8]) -> ZeppFindDeviceMessage? {
        guard let opcode = payload.first else { return nil }
        switch opcode {
        case 0x02:
            // SPEC-GAP: byte [1] is `01` in every recorded reply and not interpreted by the reference
            // (🔴 probably a status). §14 writes the reply as `02 01 <v>`, so any other [1] is treated
            // as malformed: one-shot emulation, still with the 60 s phone-side stop.
            guard payload.count == 3, payload[1] == 0x01 else { return .malformedCapabilities }
            return .capabilities(version: payload[2])
        case 0x04: return .startAcknowledged
        case 0x07: return .stoppedByStrap
        case 0x11: return .findPhoneRequested
        case 0x13: return .findPhoneEnded
        case 0x15:
            guard payload.count >= 2 else { return nil }
            return .findPhoneMode(ZeppFindPhoneMode(payload[1]))
        default: return nil
        }
    }
}

public struct ZeppFindDevice {

    public struct Configuration: Equatable {
        /// The phone-side cap: `06` goes out at the latest this long after a find's `03`. §11.4
        /// says 60 s at the latest, so larger values are clamped to 60.
        public var maxDuration: TimeInterval
        /// One-shot emulation: the delay between a `04` and the next `03` (§11.4: 10 s).
        public var oneShotResendDelay: TimeInterval
        /// A buzz is a start with the stop this long after it (§13.2: 500 ms).
        public var buzzLength: TimeInterval

        public static let maxFindDuration: TimeInterval = 60

        public init(maxDuration: TimeInterval = 60, oneShotResendDelay: TimeInterval = 10,
                    buzzLength: TimeInterval = 0.5) {
            self.maxDuration = min(max(maxDuration, 0), Self.maxFindDuration)
            self.oneShotResendDelay = max(oneShotResendDelay, 0)
            self.buzzLength = min(max(buzzLength, 0), Self.maxFindDuration)
        }
    }

    /// How a find is kept going (§11.4).
    public enum Mode: Equatable {
        /// Version ≥ 2: one `03` buzzes until `06`.
        case continuous
        /// Version < 2 or no well-formed capabilities reply: another `03` 10 s after each `04`.
        case oneShotEmulation
    }

    public enum Activity: Equatable {
        case find
        case buzz
    }

    public enum StopReason: Equatable {
        /// `stop()`.
        case user
        /// The phone-side cap (`Configuration.maxDuration`) ran out.
        case phoneTimeout
        /// A buzz's stop went out.
        case buzzEnded
        /// `07` from the strap. A `06` was still sent to pair the start.
        case strapStopped
        /// The link dropped while buzzing: a `06` is owed to the next supporting connection.
        case linkLost
    }

    public enum State: Equatable {
        case idle
        case buzzing(Activity, mode: Mode, since: Date)
        case stopped(StopReason)
    }

    public enum Event: Equatable {
        /// The capabilities reply: the version, or nil when the reply was malformed.
        case capabilities(version: UInt8?)
        case startAcknowledged
        case stopped(StopReason)
        /// The `06` owed since a link loss went out on this connection.
        case owedStopSent
        case findPhoneRequested
        case findPhoneMode(ZeppFindPhoneMode)
        case findPhoneEnded
    }

    public struct Output: Equatable {
        public var messages: [ZeppControlMessage] = []
        public var events: [Event] = []
    }

    public enum Error: Swift.Error, Equatable {
        /// A find or buzz is already running; stop it first.
        case alreadyActive
    }

    public let configuration: Configuration
    public private(set) var state: State = .idle
    public private(set) var capabilities: ZeppControlCapabilities = .disconnected
    /// The find-device version from this connection's well-formed capabilities reply.
    public private(set) var version: UInt8?
    /// A `03` went out on a connection that dropped before its `06`.
    public private(set) var isStopOwed = false
    public private(set) var isFindPhoneActive = false

    private var stopAt: Date?
    private var resendAt: Date?

    /// Keep one machine across reconnects: it carries the owed stop from one connection to the next.
    /// `stopOwed` seeds that stop from outside this process: an app the system ended while a find
    /// may have been running sends the `06` on its next connection (§11.4, §15.4).
    public init(configuration: Configuration = Configuration(), stopOwed: Bool = false) {
        self.configuration = configuration
        isStopOwed = stopOwed
    }

    /// The mode a find started now would use.
    public var mode: Mode {
        if let version, version >= 2 { return .continuous }
        return .oneShotEmulation
    }

    public var isBuzzing: Bool {
        if case .buzzing = state { return true }
        return false
    }

    /// When `tick(now:)` next has something to do; nil when nothing is scheduled.
    public var nextDeadline: Date? {
        [stopAt, resendAt].compactMap { $0 }.min()
    }

    // MARK: Connection

    /// A new authenticated connection with its services list. Sends the owed `06` first (if any),
    /// then the read-only capabilities request, and only when the strap supports find device.
    public mutating func connected(_ capabilities: ZeppControlCapabilities) -> Output {
        if isBuzzing { markLinkLost() }
        self.capabilities = capabilities
        version = nil
        isFindPhoneActive = false
        var out = Output()
        // SPEC-GAP: §11.4 owes the stop to "the next authenticated connection". One that doesn't
        // list 0x001A can't carry it, so the stop stays owed until a connection that does.
        guard capabilities.isSupported(.findDevice) else { return out }
        if isStopOwed {
            out.messages.append(message(ZeppFindDeviceCommand.stop))
            out.events.append(.owedStopSent)
            isStopOwed = false
        }
        out.messages.append(message(ZeppFindDeviceCommand.capabilitiesRequest))
        return out
    }

    /// The link dropped. A running find or buzz becomes `.stopped(.linkLost)` and its `06` is owed
    /// to the next connection (the strap may keep vibrating until its own, unknown, timeout).
    public mutating func connectionLost() {
        if isBuzzing { markLinkLost() }
        capabilities = .disconnected
        version = nil
        isFindPhoneActive = false
    }

    // MARK: User actions

    /// Starts "find device" (`03`). It stops after `configuration.maxDuration` at the latest.
    public mutating func start(now: Date) throws -> Output {
        try capabilities.require(.findDevice)
        guard !isBuzzing else { throw Error.alreadyActive }
        state = .buzzing(.find, mode: mode, since: now)
        stopAt = now.addingTimeInterval(configuration.maxDuration)
        resendAt = nil
        return Output(messages: [message(ZeppFindDeviceCommand.start)])
    }

    /// One short buzz: `03` now, `06` after `configuration.buzzLength` (§13.2). How long the strap
    /// actually vibrates for a given delay is unknown (🔴).
    public mutating func buzz(now: Date) throws -> Output {
        try capabilities.require(.buzz)
        guard !isBuzzing else { throw Error.alreadyActive }
        state = .buzzing(.buzz, mode: mode, since: now)
        stopAt = now.addingTimeInterval(configuration.buzzLength)
        resendAt = nil
        return Output(messages: [message(ZeppFindDeviceCommand.start)])
    }

    /// Stops a running find or buzz (`06`). Nothing to send when idle or already stopped.
    public mutating func stop() -> Output {
        guard isBuzzing else { return Output() }
        return finish(.user)
    }

    /// Ends a find-phone request from the strap (`14`).
    public mutating func endFindPhone() -> Output {
        guard isFindPhoneActive, capabilities.isSupported(.findPhone) else { return Output() }
        isFindPhoneActive = false
        return Output(messages: [message(ZeppFindDeviceCommand.endFindPhone)], events: [.findPhoneEnded])
    }

    // MARK: Inputs

    /// Call at (or after) `nextDeadline`.
    public mutating func tick(now: Date) -> Output {
        guard case .buzzing(let activity, let mode, _) = state else { return Output() }
        if let stopAt, now >= stopAt {
            return finish(activity == .buzz ? .buzzEnded : .phoneTimeout)
        }
        if activity == .find, mode == .oneShotEmulation, let resendAt, now >= resendAt {
            self.resendAt = nil
            return Output(messages: [message(ZeppFindDeviceCommand.start)])
        }
        return Output()
    }

    /// A decoded message from endpoint 0x001A.
    public mutating func receive(_ payload: [UInt8], now: Date) -> Output {
        guard let parsed = ZeppFindDeviceMessage.parse(payload) else { return Output() }
        switch parsed {
        case .capabilities(let reported):
            version = reported
            return Output(events: [.capabilities(version: reported)])
        case .malformedCapabilities:
            // Ignored: the version stays whatever it was (unknown, unless a well-formed reply came).
            return Output(events: [.capabilities(version: nil)])
        case .startAcknowledged:
            // One-shot emulation: another `03` after the delay, unless the stop comes first.
            if case .buzzing(.find, .oneShotEmulation, _) = state, let stopAt {
                let next = now.addingTimeInterval(configuration.oneShotResendDelay)
                resendAt = next < stopAt ? next : nil
            }
            return Output(events: [.startAcknowledged])
        case .stoppedByStrap:
            guard isBuzzing else { return Output() }
            // SPEC-GAP: whether the strap expects a `06` after its own `07` is unknown (🔴 §11.3).
            // ZeppKit still sends one, so every start stays paired with a stop (§15.4).
            return finish(.strapStopped)
        case .findPhoneRequested:
            guard capabilities.isSupported(.findPhone) else { return Output() }
            isFindPhoneActive = true
            return Output(messages: [message(ZeppFindDeviceCommand.findPhoneAck)], events: [.findPhoneRequested])
        case .findPhoneMode(let mode):
            guard isFindPhoneActive else { return Output() }
            return Output(events: [.findPhoneMode(mode)])
        case .findPhoneEnded:
            guard isFindPhoneActive else { return Output() }
            isFindPhoneActive = false
            return Output(events: [.findPhoneEnded])
        }
    }

    // MARK: Helpers

    private func message(_ payload: [UInt8]) -> ZeppControlMessage {
        ZeppControlMessage(endpoint: ZeppEndpoint.findDevice, payload: payload)
    }

    private mutating func finish(_ reason: StopReason) -> Output {
        state = .stopped(reason)
        stopAt = nil
        resendAt = nil
        guard capabilities.isSupported(.findDevice) else {
            // Not reachable while buzzing on a live connection; owe the stop rather than drop it.
            isStopOwed = true
            state = .stopped(.linkLost)
            return Output(events: [.stopped(.linkLost)])
        }
        return Output(messages: [message(ZeppFindDeviceCommand.stop)], events: [.stopped(reason)])
    }

    private mutating func markLinkLost() {
        state = .stopped(.linkLost)
        stopAt = nil
        resendAt = nil
        isStopOwed = true
    }
}
