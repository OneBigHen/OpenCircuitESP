// The strap's HEALTH settings and alerts, read and changed one at a time (ZEPP_PROTOCOL.md §5.5,
// §13.4, §14, §15.1, §15.3; #228, #230).
//
// Config writes are PERSISTENT and can change what the strap RECORDS (§15.1). `ZeppHealthConfigEditor`
// therefore follows §15.3 for every user edit, and nothing else ever writes:
//   1. read the group's args with constraints on (a FRESH read, right before the write);
//   2. check the strap still holds the value the user saw, and validate the new value against the
//      strap's own allowed values (and the alert's prerequisite switch);
//   3. write ONE arg, in one message for the group, echoing the group version from that read;
//   4. expect `06 01`;
//   5. re-read and report the strap's value, whatever happened at 4.
// It never writes at session setup, never writes a value the user didn't change, never writes an
// arg the strap didn't report with the expected type, and never retries.
//
// SPEC-GAP: §15.3 is a 🔴 recommendation; a fuller config-write section is being written. The
// conservative readings taken here are marked below.

import Foundation

/// The HEALTH-group (`0x08`) settings OpenCircuit may change. Each is offered only when the strap
/// reported it, with the expected type, in a constraints-included read on this connection (§14).
///
/// SPEC-GAP: arg `0x05` (share heart rate, 🔴 "probably" Zepp's Heart Rate Push, §5.5) is not offered:
/// what it controls is unsettled. The inactivity and goal alerts (`41`–`46`, `51`) are not offered
/// either: whether they buzz on the Helio is 🔴 (§13.4). Goals (`52`–`57`) are never written (§15.1).
public enum ZeppHealthSetting: String, CaseIterable, Equatable, Hashable {
    /// Byte (`0x10`): `00` off, `ff` "smart"/automatic, N = every N minutes (§5.5).
    case heartRateMonitoring
    /// Bool: the vendor's "Active heart rate monitoring". It raises the sampling rate during
    /// detected activity and does NOT gate recording (🟢 §5.5).
    case activeHeartRateMonitoring
    /// Bool: high-accuracy sleep monitoring (uses HR for sleep; needed for REM staging 🔴).
    case highAccuracySleep
    /// Bool: sleep breathing quality (needed for sleep SpO₂; 🔴 likely sleep respiratory rate).
    case sleepBreathingQuality
    /// Bool: stress monitoring.
    case stressMonitoring
    /// Bool: all-day SpO₂ monitoring.
    case allDaySpO2
    /// Byte threshold, bpm; `00` = off (§13.4).
    case highHeartRateAlert
    /// Byte threshold, bpm; `00` = off (§13.4).
    case lowHeartRateAlert
    /// Bool: the relax (stress) reminder. Needs stress monitoring on (§13.4).
    case relaxReminder
    /// Byte threshold, %; `00` = off. Needs all-day SpO₂ on (§13.4).
    case lowSpO2Alert

    /// The recording and sampling settings (#228), in display order.
    public static let measurement: [ZeppHealthSetting] = [
        .heartRateMonitoring, .activeHeartRateMonitoring, .highAccuracySleep, .sleepBreathingQuality,
        .stressMonitoring, .allDaySpO2,
    ]

    /// The strap's own haptic alerts (#230), in display order.
    public static let alerts: [ZeppHealthSetting] = [.highHeartRateAlert, .lowHeartRateAlert, .lowSpO2Alert, .relaxReminder]

    public var argument: UInt8 {
        switch self {
        case .heartRateMonitoring: return ZeppConfig.HealthArgument.heartRateMonitoring
        case .activeHeartRateMonitoring: return ZeppConfig.HealthArgument.heartRateDuringActivity
        case .highAccuracySleep: return ZeppConfig.HealthArgument.highAccuracySleep
        case .sleepBreathingQuality: return ZeppConfig.HealthArgument.sleepBreathingQuality
        case .stressMonitoring: return ZeppConfig.HealthArgument.stressMonitoring
        case .allDaySpO2: return ZeppConfig.HealthArgument.allDaySpO2
        case .highHeartRateAlert: return 0x02
        case .lowHeartRateAlert: return 0x03
        case .relaxReminder: return 0x14
        case .lowSpO2Alert: return 0x32
        }
    }

    /// true for a bool (`0x0b`) switch, false for a byte (`0x10`) with allowed values.
    public var isSwitch: Bool {
        switch self {
        case .heartRateMonitoring, .highHeartRateAlert, .lowHeartRateAlert, .lowSpO2Alert: return false
        default: return true
        }
    }

    /// The switch that must be ON for this alert to work (§13.4, Amazfit's manual).
    public var prerequisite: ZeppHealthSetting? {
        switch self {
        case .relaxReminder: return .stressMonitoring
        case .lowSpO2Alert: return .allDaySpO2
        default: return nil
        }
    }

    /// The settings whose prerequisite this one is.
    public var dependents: [ZeppHealthSetting] {
        Self.allCases.filter { $0.prerequisite == self }
    }
}

/// The strap's HEALTH settings from ONE constraints-included read, keeping only the settings it
/// reported exactly once with the expected type (and, for a byte, a non-empty allowed list). The
/// strap's values, for display and validation: never "the setting" on the phone's side.
public struct ZeppHealthConfig: Equatable {

    public struct Entry: Equatable {
        public let value: ZeppConfigValue
        /// A byte setting's allowed values, exactly as the strap listed them; nil for a switch.
        public let allowedValues: [UInt8]?
    }

    /// The HEALTH group version from the reply; a write echoes it (§9, §13.4).
    public let groupVersion: UInt8
    public let entries: [ZeppHealthSetting: Entry]
    /// Parsing stopped early (an unknown type code): settings after that point are missing (§5.5).
    public let isPartial: Bool

    /// nil unless the reply is a HEALTH reply with constraints included, at a group version the
    /// args are known at (§13.4).
    public init?(_ reply: ZeppConfigReadReply) {
        guard reply.group == ZeppConfig.healthGroup, reply.includesConstraints,
              ZeppHapticAlertSettings.knownHealthVersions.contains(reply.groupVersion) else { return nil }
        groupVersion = reply.groupVersion
        isPartial = reply.isPartial
        var entries: [ZeppHealthSetting: Entry] = [:]
        for setting in ZeppHealthSetting.allCases {
            let matches = reply.entries.filter { $0.argument == setting.argument }
            guard matches.count == 1, let entry = matches.first else { continue }
            switch (setting.isSwitch, entry.value, entry.constraint) {
            case (true, .bool, _):
                entries[setting] = Entry(value: entry.value, allowedValues: nil)
            case (false, .byte, .allowedValues(let allowed)?) where !allowed.isEmpty:
                entries[setting] = Entry(value: entry.value, allowedValues: allowed)
            default:
                // Wrong type, or a byte without allowed values to validate against: hide it (§14).
                continue
            }
        }
        self.entries = entries
    }

    public func value(_ setting: ZeppHealthSetting) -> ZeppConfigValue? { entries[setting]?.value }

    public func isOn(_ setting: ZeppHealthSetting) -> Bool? {
        if case .bool(let on)? = value(setting) { return on }
        return nil
    }

    /// The values the user may pick: off/on for a switch, the strap's allowed list (in its order)
    /// for a byte. Empty when the strap didn't report the setting.
    public func options(_ setting: ZeppHealthSetting) -> [ZeppConfigValue] {
        guard let entry = entries[setting] else { return [] }
        if let allowed = entry.allowedValues { return allowed.map(ZeppConfigValue.byte) }
        return [.bool(false), .bool(true)]
    }

    public enum Availability: Equatable {
        case available
        /// Not reported with the expected type: hide it.
        case notReported
        /// Its prerequisite switch reads off (or wasn't reported): show it disabled, with why.
        case needs(ZeppHealthSetting)
    }

    public func availability(_ setting: ZeppHealthSetting) -> Availability {
        guard entries[setting] != nil else { return .notReported }
        if let prerequisite = setting.prerequisite, isOn(prerequisite) != true { return .needs(prerequisite) }
        return .available
    }

    /// Throws unless `value` is one the strap offers for `setting` and the setting is available.
    public func validate(_ setting: ZeppHealthSetting, _ value: ZeppConfigValue) throws {
        switch availability(setting) {
        case .available: break
        case .notReported: throw ZeppHealthConfigEditor.Error.notReported(setting)
        case .needs(let prerequisite): throw ZeppHealthConfigEditor.Error.prerequisiteOff(setting, needs: prerequisite)
        }
        guard options(setting).contains(value) else { throw ZeppHealthConfigEditor.Error.valueNotAllowed(setting, value) }
    }
}

/// The §15.3 sequence as a pure state machine, one per connection. Every message it returns goes to
/// the config endpoint (0x000A); feed it every decoded config payload that isn't a session-setup
/// reply, and call `tick(now:)` at `nextDeadline`.
public struct ZeppHealthConfigEditor {

    public struct Configuration: Equatable {
        /// How long to wait for a read reply or a write ack. SPEC-GAP: the spec gives no figure; the
        /// same 5 s as the alarm editor and the session's setup steps.
        public var replyTimeout: TimeInterval

        public init(replyTimeout: TimeInterval = 5) {
            self.replyTimeout = replyTimeout
        }
    }

    /// `03 01 08 0a 01 04 11 12 13 31 02 03 14 32`: HEALTH, constraints on, every setting above.
    /// SPEC-GAP: the strap answering ten args in one constraints-included reply is inferred from
    /// §10.1 item 20 (eleven args, constraints on, parsed cleanly on the Helio).
    public static var readRequest: [UInt8] {
        ZeppConfig.readRequest(group: ZeppConfig.healthGroup,
                               arguments: ZeppHealthSetting.allCases.map(\.argument), includeConstraints: true)
    }

    public enum ReadFailure: Swift.Error, Equatable {
        case timedOut
        /// Not a well-formed `04 01` HEALTH reply with constraints included.
        case malformed
        /// A HEALTH group version the args aren't known at (§13.4): nothing is offered.
        case unknownGroupVersion(UInt8)
    }

    public enum ReadState: Equatable {
        case notRead
        case read(ZeppHealthConfig)
        case unreadable(ReadFailure)
    }

    /// One user edit of one setting: the value the user saw, and the one they picked.
    public struct Change: Equatable {
        public let setting: ZeppHealthSetting
        public let from: ZeppConfigValue
        public let to: ZeppConfigValue

        public init(setting: ZeppHealthSetting, from: ZeppConfigValue, to: ZeppConfigValue) {
            self.setting = setting
            self.from = from
            self.to = to
        }
    }

    public enum WriteFailure: Equatable {
        /// An ack with a status other than `01` (nil: the status byte was missing).
        case status(UInt8?)
        /// No ack in time. The strap may or may not have applied the write.
        case noAck
    }

    /// The re-read after a write, acknowledged or not (§15.3's last step).
    public struct WriteCheck: Equatable {
        public let change: Change
        /// nil when the strap acknowledged `06 01`.
        public let failure: WriteFailure?
        /// The strap's settings after the write: show these, not the phone's idea of them.
        public let config: ZeppHealthConfig
        /// The strap's value for the setting now; nil when the re-read no longer reports it.
        public var readBack: ZeppConfigValue? { config.value(change.setting) }
        /// The strap now holds the requested value.
        public var matches: Bool { readBack == change.to }
        /// Every other setting reads back as it did before the write.
        public let otherSettingsUnchanged: Bool
    }

    public enum Event: Equatable {
        case read(ZeppHealthConfig)
        case readFailed(ReadFailure)
        /// The fresh read before the write found a different value than the user saw (another app,
        /// or the strap itself, changed it): nothing was written.
        case changedOnStrap(Change, current: ZeppConfigValue?)
        /// The fresh read before the write made the change invalid (the setting vanished, its
        /// allowed values changed, its prerequisite is off): nothing was written.
        case refused(Change, Error)
        case writeAcknowledged(Change)
        /// The write failed; a re-read is under way.
        case writeNotAcknowledged(Change, WriteFailure)
        case writeChecked(WriteCheck)
        /// The re-read after the write failed: the strap's value is unknown.
        case writeUnverified(Change, failure: WriteFailure?, ReadFailure)
    }

    public enum Error: Swift.Error, Equatable {
        /// A read or write is in flight.
        case busy
        /// The config capabilities (§5.5) weren't read on this connection, the service version
        /// isn't understood, or HEALTH isn't listed.
        case groupNotOffered
        /// No usable HEALTH read on this connection yet.
        case notRead
        /// The strap didn't report this setting with the expected type: never write it (§14).
        case notReported(ZeppHealthSetting)
        /// `from` equals `to`: the user changed nothing, so nothing is written.
        case unchanged(ZeppHealthSetting)
        /// Not one of the strap's allowed values.
        case valueNotAllowed(ZeppHealthSetting, ZeppConfigValue)
        /// The alert's prerequisite switch is off.
        case prerequisiteOff(ZeppHealthSetting, needs: ZeppHealthSetting)
    }

    public struct Output: Equatable {
        public var messages: [ZeppControlMessage] = []
        public var events: [Event] = []
    }

    private enum Pending: Equatable {
        case none
        case reading(deadline: Date)
        case preReading(Change, deadline: Date)
        case writing(Change, base: ZeppHealthConfig, deadline: Date)
        case verifying(Change, base: ZeppHealthConfig, failure: WriteFailure?, deadline: Date)
    }

    public let capabilities: ZeppControlCapabilities
    public let configuration: Configuration
    public private(set) var configCapabilities: ZeppConfigCapabilities?
    public private(set) var state: ReadState = .notRead
    private var pending: Pending = .none

    public init(capabilities: ZeppControlCapabilities, configCapabilities: ZeppConfigCapabilities? = nil,
                configuration: Configuration = Configuration()) {
        self.capabilities = capabilities
        self.configCapabilities = configCapabilities
        self.configuration = configuration
    }

    /// The config capabilities reply of this connection (§5.5).
    public mutating func noteConfigCapabilities(_ capabilities: ZeppConfigCapabilities?) {
        configCapabilities = capabilities
    }

    /// The strap's settings from the last good read on this connection.
    public var config: ZeppHealthConfig? {
        if case .read(let config) = state { return config }
        return nil
    }

    /// §14 "Haptic alert settings", applied to every HEALTH setting: the config endpoint is listed
    /// (the `.hapticAlerts` control is that endpoint's gate), and the config capabilities list
    /// HEALTH at an understood service version.
    public var isOffered: Bool {
        guard capabilities.isSupported(.hapticAlerts), let configCapabilities else { return false }
        return configCapabilities.isVersionUnderstood && configCapabilities.groups.contains(ZeppConfig.healthGroup)
    }

    public var isBusy: Bool { pending != .none }

    /// The change being written or checked, for the UI's "Saving…".
    public var changeInFlight: Change? {
        switch pending {
        case .none, .reading: return nil
        case .preReading(let change, _), .writing(let change, _, _), .verifying(let change, _, _, _): return change
        }
    }

    public var nextDeadline: Date? {
        switch pending {
        case .none: return nil
        case .reading(let deadline), .preReading(_, let deadline), .writing(_, _, let deadline),
             .verifying(_, _, _, let deadline):
            return deadline
        }
    }

    // MARK: Inputs

    /// Reads every setting with constraints. Read-only.
    public mutating func read(now: Date) throws -> Output {
        try preconditions()
        pending = .reading(deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.readRequest)])
    }

    /// Starts one user edit: a fresh read first (§15.3 step 1); the write goes out only if that read
    /// still holds `change.from` and `change.to` is valid against it.
    public mutating func change(_ change: Change, now: Date) throws -> Output {
        try preconditions()
        guard change.from != change.to else { throw Error.unchanged(change.setting) }
        guard let config else { throw Error.notRead }
        // Checked against the last read too, so a value the UI never offered fails here, loudly.
        try config.validate(change.setting, change.to)
        pending = .preReading(change, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.readRequest)])
    }

    /// A decoded payload from the config endpoint.
    public mutating func receive(_ payload: [UInt8], now: Date) -> Output {
        switch payload.first {
        case 0x04: return receiveRead(payload, now: now)
        case 0x06: return receiveAck(ZeppConfig.parseWriteAck(payload), now: now)
        default: return Output()
        }
    }

    /// Call at (or after) `nextDeadline`.
    public mutating func tick(now: Date) -> Output {
        guard let deadline = nextDeadline, now >= deadline else { return Output() }
        switch pending {
        case .none:
            return Output()
        case .reading:
            pending = .none
            state = .unreadable(.timedOut)
            return Output(events: [.readFailed(.timedOut)])
        case .preReading(let change, _):
            pending = .none
            state = .unreadable(.timedOut)
            return Output(events: [.readFailed(.timedOut), .refused(change, .notRead)])
        case .writing(let change, let base, _):
            // No ack: re-read so the screen shows what the strap actually holds.
            return reRead(change, base: base, failure: .noAck, now: now)
        case .verifying(let change, _, let failure, _):
            pending = .none
            state = .unreadable(.timedOut)
            return Output(events: [.writeUnverified(change, failure: failure, .timedOut)])
        }
    }

    // MARK: Steps

    private static func message(_ payload: [UInt8]) -> ZeppControlMessage {
        ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: payload)
    }

    private func preconditions() throws {
        try capabilities.require(.hapticAlerts)
        guard isOffered else { throw Error.groupNotOffered }
        guard pending == .none else { throw Error.busy }
    }

    private static func parse(_ payload: [UInt8]) -> Result<ZeppHealthConfig, ReadFailure> {
        guard let reply = ZeppConfig.parseReadReply(payload), reply.group == ZeppConfig.healthGroup,
              reply.includesConstraints else { return .failure(.malformed) }
        guard let config = ZeppHealthConfig(reply) else { return .failure(.unknownGroupVersion(reply.groupVersion)) }
        return .success(config)
    }

    private mutating func receiveRead(_ payload: [UInt8], now: Date) -> Output {
        let result = Self.parse(payload)
        switch pending {
        case .reading:
            pending = .none
            switch result {
            case .success(let config):
                state = .read(config)
                return Output(events: [.read(config)])
            case .failure(let failure):
                state = .unreadable(failure)
                return Output(events: [.readFailed(failure)])
            }
        case .preReading(let change, _):
            pending = .none
            switch result {
            case .failure(let failure):
                state = .unreadable(failure)
                return Output(events: [.readFailed(failure), .refused(change, .notRead)])
            case .success(let config):
                state = .read(config)
                var events: [Event] = [.read(config)]
                let current = config.value(change.setting)
                guard current == change.from else {
                    events.append(.changedOnStrap(change, current: current))
                    return Output(events: events)
                }
                do {
                    try config.validate(change.setting, change.to)
                } catch let error as Error {
                    events.append(.refused(change, error))
                    return Output(events: events)
                } catch {
                    return Output(events: events)
                }
                guard let write = ZeppConfig.writeRequest(group: ZeppConfig.healthGroup, groupVersion: config.groupVersion,
                                                          entries: [(change.setting.argument, change.to)]) else {
                    events.append(.refused(change, .valueNotAllowed(change.setting, change.to)))
                    return Output(events: events)
                }
                pending = .writing(change, base: config, deadline: now.addingTimeInterval(configuration.replyTimeout))
                return Output(messages: [Self.message(write)], events: events)
            }
        case .verifying(let change, let base, let failure, _):
            pending = .none
            switch result {
            case .success(let config):
                state = .read(config)
                let others = ZeppHealthSetting.allCases.filter { $0 != change.setting }
                let unchanged = others.allSatisfy { base.entries[$0] == config.entries[$0] }
                return Output(events: [.writeChecked(WriteCheck(change: change, failure: failure, config: config,
                                                                otherSettingsUnchanged: unchanged))])
            case .failure(let readFailure):
                state = .unreadable(readFailure)
                return Output(events: [.writeUnverified(change, failure: failure, readFailure)])
            }
        case .none, .writing:
            // SPEC-GAP: the strap is not known to send a read reply unasked. One that arrives unasked
            // (or after its read timed out) is ignored rather than standing in for a read.
            return Output()
        }
    }

    private mutating func receiveAck(_ status: UInt8?, now: Date) -> Output {
        guard case .writing(let change, let base, _) = pending else { return Output() }
        guard status == 0x01 else {
            return reRead(change, base: base, failure: .status(status), now: now)
        }
        pending = .verifying(change, base: base, failure: nil, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.readRequest)], events: [.writeAcknowledged(change)])
    }

    /// A failed write still ends in a re-read: the screen must show the strap's actual value. No retry.
    private mutating func reRead(_ change: Change, base: ZeppHealthConfig, failure: WriteFailure, now: Date) -> Output {
        pending = .verifying(change, base: base, failure: failure, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [Self.message(Self.readRequest)], events: [.writeNotAcknowledged(change, failure)])
    }
}
