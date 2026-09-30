// Alarms on endpoint 0x000F (ZEPP_PROTOCOL.md §12, §14, §15.2): the 10-byte record, the commands,
// the list reply, and `ZeppAlarmEditor`, a read-before-write state machine.
//
// Alarm writes are PERSISTENT: a create overwrites whatever its slot held, a delete removes it
// (§15.1). The editor therefore writes exactly one slot per user action, only after a well-formed
// read on this connection with no `0f` (changed on the strap) since, only once the strap's clock was
// set on this connection, and then re-reads to check the slot. It never writes a slot the caller did
// not name, and nothing is written at session setup.
//
// Never encoded, so never sent: the alarm capabilities request `01` (🔴 reply layout unknown, never
// sent by the reference) and "update" `07` (🔴 layout unknown), §12.2.

import Foundation

/// The days an alarm repeats on: Monday = bit 0 … Sunday = bit 6; empty = once (§12.3).
///
/// Monday-first, unlike the time command's day of week (Sunday = 0, §5.1). The two share nothing.
public struct ZeppAlarmDays: OptionSet, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let monday = ZeppAlarmDays(rawValue: 0x01)
    public static let tuesday = ZeppAlarmDays(rawValue: 0x02)
    public static let wednesday = ZeppAlarmDays(rawValue: 0x04)
    public static let thursday = ZeppAlarmDays(rawValue: 0x08)
    public static let friday = ZeppAlarmDays(rawValue: 0x10)
    public static let saturday = ZeppAlarmDays(rawValue: 0x20)
    public static let sunday = ZeppAlarmDays(rawValue: 0x40)

    /// No repeat: the strap fires at the next occurrence of the time. What it does with a fired
    /// once-alarm (disable, delete, keep) is unknown (🔴 §12.3).
    public static let once: ZeppAlarmDays = []
    public static let weekdays: ZeppAlarmDays = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: ZeppAlarmDays = [.saturday, .sunday]
    public static let everyDay: ZeppAlarmDays = [.weekdays, .weekend]

    /// Bit 7 is never set (§12.3).
    public var isValid: Bool { rawValue & 0x80 == 0 }

    private static let names: [(ZeppAlarmDays, String)] = [
        (.monday, "mon"), (.tuesday, "tue"), (.wednesday, "wed"), (.thursday, "thu"),
        (.friday, "fri"), (.saturday, "sat"), (.sunday, "sun"),
    ]

    /// Parses day names separated by `,` or `+`, case-insensitive: `mon` … `sun`, `weekdays`,
    /// `weekend`, `daily`, `once`. nil for an empty list, an unknown name, or `once` mixed with days.
    public init?(list: String) {
        let tokens = list.lowercased().split(whereSeparator: { $0 == "," || $0 == "+" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.isEmpty else { return nil }
        var days: ZeppAlarmDays = []
        var sawOnce = false
        for token in tokens {
            switch token {
            case "once": sawOnce = true
            case "daily": days.formUnion(.everyDay)
            case "weekdays": days.formUnion(.weekdays)
            case "weekend": days.formUnion(.weekend)
            default:
                guard let day = Self.names.first(where: { $0.1 == token })?.0 else { return nil }
                days.formUnion(day)
            }
        }
        if sawOnce && !days.isEmpty { return nil }
        self = days
    }

    /// `once`, `daily`, `weekdays`, `weekend`, or the day names (`mon wed fri`). Bit 7 shows as `+bit7`.
    public var summary: String {
        let named = Self.names.filter { contains($0.0) }.map(\.1)
        guard isValid else { return (named + ["+bit7"]).joined(separator: " ") }
        switch self {
        case .once: return "once"
        case .everyDay: return "daily"
        case .weekdays: return "weekdays"
        case .weekend: return "weekend"
        default: return named.joined(separator: " ")
        }
    }
}

public enum ZeppAlarmError: Error, Equatable {
    case slotOutOfRange(UInt8)
    case hourOutOfRange(UInt8)
    case minuteOutOfRange(UInt8)
    /// Bit 7 of the repeat mask set.
    case invalidDays(UInt8)
}

/// One alarm: the 10-byte record of §12.3.
///
/// ```
/// [0] flags  [1] slot  [2] hour  [3] minute  [4] repeat  [5..9] unknown
/// ```
public struct ZeppAlarm: Equatable {
    /// The strap stores up to 10 alarms, slots 0–9 (§12.4).
    public static let slotCount: UInt8 = 10
    public static let recordLength = 10

    /// Flag bit 0: smart wake.
    public static let smartWakeFlag: UInt8 = 0x01
    /// Flag bit 2: enabled.
    public static let enabledFlag: UInt8 = 0x04

    /// 0–9: the alarm's only identity (§12.3).
    public var slot: UInt8
    /// 0–23, in the strap's local wall-clock time (whatever the last time set used, §5.1).
    public var hour: UInt8
    /// 0–59.
    public var minute: UInt8
    public var days: ZeppAlarmDays
    public var isEnabled: Bool
    /// Whether the Helio honours it is unknown (🔴 §12.3). v1 does not offer it; the editor keeps
    /// the bit on alarms that already have it (§14).
    public var smartWake: Bool
    /// The flag byte as the strap returned it; nil for an alarm built on the phone. Diagnostic only:
    /// writes send bits 0 and 2 and zero the rest (§15.2).
    public let rawFlags: UInt8?
    /// Bytes `[5..9]` as the strap returned them (the device sets `[8]` to `01`); empty for an alarm
    /// built on the phone. Ignored; writes send five `00`s (§12.3).
    public let unknownTail: [UInt8]

    public init(slot: UInt8, hour: UInt8, minute: UInt8, days: ZeppAlarmDays = .once,
                isEnabled: Bool = true, smartWake: Bool = false) {
        self.slot = slot
        self.hour = hour
        self.minute = minute
        self.days = days
        self.isEnabled = isEnabled
        self.smartWake = smartWake
        self.rawFlags = nil
        self.unknownTail = []
    }

    private init(record r: [UInt8]) {
        slot = r[1]
        hour = r[2]
        minute = r[3]
        days = ZeppAlarmDays(rawValue: r[4])
        isEnabled = r[0] & Self.enabledFlag != 0
        smartWake = r[0] & Self.smartWakeFlag != 0
        rawFlags = r[0]
        unknownTail = Array(r[5..<10])
    }

    public func validate() throws {
        guard slot < Self.slotCount else { throw ZeppAlarmError.slotOutOfRange(slot) }
        guard hour < 24 else { throw ZeppAlarmError.hourOutOfRange(hour) }
        guard minute < 60 else { throw ZeppAlarmError.minuteOutOfRange(minute) }
        guard days.isValid else { throw ZeppAlarmError.invalidDays(days.rawValue) }
    }

    /// The flag byte a write carries: smart wake and enabled only.
    public var flagsForWrite: UInt8 {
        (smartWake ? Self.smartWakeFlag : 0) | (isEnabled ? Self.enabledFlag : 0)
    }

    /// The 10-byte record for a write. Throws `ZeppAlarmError` for any out-of-range field.
    public func record() throws -> [UInt8] {
        try validate()
        return [flagsForWrite, slot, hour, minute, days.rawValue, 0, 0, 0, 0, 0]
    }

    /// Decodes one record; nil unless it is exactly 10 bytes. Field ranges are NOT checked here
    /// (`ZeppAlarmList.parse` does).
    public static func parse(record: ArraySlice<UInt8>) -> ZeppAlarm? {
        guard record.count == recordLength else { return nil }
        return ZeppAlarm(record: Array(record))
    }

    /// Same slot, time, days, enabled and smart-wake: what a re-read can confirm. The raw flag byte
    /// and the unknown tail are ignored.
    public func hasSameSetting(as other: ZeppAlarm) -> Bool {
        slot == other.slot && hour == other.hour && minute == other.minute && days == other.days
            && isEnabled == other.isEnabled && smartWake == other.smartWake
    }

    /// `slot 0  06:30  weekdays  on`, for logs.
    public var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        var parts = ["slot \(slot)", time, days.summary, isEnabled ? "on" : "off"]
        if smartWake { parts.append("smart wake") }
        return parts.joined(separator: "  ")
    }
}

public enum ZeppAlarmListError: Error, Equatable {
    /// Not an `0a` reply.
    case notAList
    /// The payload is not exactly 2 + 10 × count bytes (§12.2).
    case lengthMismatch(count: Int, length: Int)
    /// count > 10 (§12.4).
    case tooManyAlarms(Int)
    case slotOutOfRange(UInt8)
    case duplicateSlot(UInt8)
    /// A record whose hour, minute or repeat mask is out of range.
    case invalidAlarm(slot: UInt8, ZeppAlarmError)
    /// The editor got no list in time.
    case timedOut
}

public enum ZeppAlarmList {
    /// `0a <count> <record>…` (§12.2). Any violation of the §12.4 defensive rule (count > 10, a slot
    /// ≥ 10, a repeated slot) or of the length rule rejects the whole reply: alarms are then
    /// unsupported for the connection and nothing is written. Alarms come back sorted by slot.
    public static func parse(_ payload: [UInt8]) -> Result<[ZeppAlarm], ZeppAlarmListError> {
        guard payload.count >= 2, payload[0] == 0x0a else { return .failure(.notAList) }
        let count = Int(payload[1])
        guard payload.count == 2 + ZeppAlarm.recordLength * count else {
            return .failure(.lengthMismatch(count: count, length: payload.count))
        }
        guard count <= Int(ZeppAlarm.slotCount) else { return .failure(.tooManyAlarms(count)) }
        var alarms = [ZeppAlarm]()
        var seen = Set<UInt8>()
        for index in 0..<count {
            let start = 2 + index * ZeppAlarm.recordLength
            guard let alarm = ZeppAlarm.parse(record: payload[start..<(start + ZeppAlarm.recordLength)]) else {
                return .failure(.lengthMismatch(count: count, length: payload.count))
            }
            guard alarm.slot < ZeppAlarm.slotCount else { return .failure(.slotOutOfRange(alarm.slot)) }
            guard seen.insert(alarm.slot).inserted else { return .failure(.duplicateSlot(alarm.slot)) }
            // SPEC-GAP: §12 does not say what an out-of-range hour, minute or repeat bit 7 in a READ
            // record means. Editing such an alarm would silently change it, so the whole list is
            // treated as malformed (alarms unsupported for this connection, nothing written).
            do { try alarm.validate() } catch let error as ZeppAlarmError {
                return .failure(.invalidAlarm(slot: alarm.slot, error))
            } catch {
                return .failure(.notAList)
            }
            alarms.append(alarm)
        }
        return .success(alarms.sorted { $0.slot < $1.slot })
    }
}

/// Phone → strap alarm payloads (§12.2).
public enum ZeppAlarmCommand {
    /// Read all alarms; the strap replies `0a …`.
    public static let readAll: [UInt8] = [0x09]

    /// `03 01 <record>`: create the alarm in `alarm.slot`, or REPLACE whatever that slot holds.
    /// The `01` is unexplained (🔴 probably the record count); ZeppKit always sends one record.
    public static func createOrReplace(_ alarm: ZeppAlarm) throws -> [UInt8] {
        [0x03, 0x01] + (try alarm.record())
    }

    /// `05 01 <slot>`: DELETE the alarm in `slot`.
    public static func delete(slot: UInt8) throws -> [UInt8] {
        guard slot < ZeppAlarm.slotCount else { throw ZeppAlarmError.slotOutOfRange(slot) }
        return [0x05, 0x01, slot]
    }
}

/// Strap → phone alarm messages (§12.2, §12.5).
public enum ZeppAlarmReply: Equatable {
    /// `04 <status>`; nil status when the byte is missing.
    case createAck(status: UInt8?)
    /// `06 <status>`.
    case deleteAck(status: UInt8?)
    /// `08 <status>`. ZeppKit never sends the update it acknowledges.
    case updateAck(status: UInt8?)
    /// `0a …`, parsed and validated.
    case list(Result<[ZeppAlarm], ZeppAlarmListError>)
    /// `0f`: the alarms changed on the strap. Further bytes are ignored.
    case changedOnStrap

    /// SPEC-GAP: the ack status is only logged by the reference (🔴). `01` is taken as success, by
    /// analogy with every other Zepp OS ack; anything else, or no ack, is a failure (§12.2).
    public static let successStatus: UInt8 = 0x01

    /// nil for an empty payload or any other opcode (including a `02` capabilities reply, whose
    /// layout is unknown).
    public static func parse(_ payload: [UInt8]) -> ZeppAlarmReply? {
        guard let opcode = payload.first else { return nil }
        let status = payload.count >= 2 ? payload[1] : nil
        switch opcode {
        case 0x04: return .createAck(status: status)
        case 0x06: return .deleteAck(status: status)
        case 0x08: return .updateAck(status: status)
        case 0x0a: return .list(ZeppAlarmList.parse(payload))
        case 0x0f: return .changedOnStrap
        default: return nil
        }
    }
}

/// The §15.2 read-before-write sequence as a pure state machine. Build one per connection. Every
/// message it returns goes to endpoint 0x000F; feed it every decoded 0x000F payload and call
/// `tick(now:)` at `nextDeadline`.
public struct ZeppAlarmEditor {

    public struct Configuration: Equatable {
        /// How long to wait for a list or an ack. SPEC-GAP: §15.2 says "a few seconds".
        public var replyTimeout: TimeInterval

        public init(replyTimeout: TimeInterval = 5) {
            self.replyTimeout = replyTimeout
        }
    }

    public enum ListState: Equatable {
        case notRead
        case read([ZeppAlarm])
        /// The last read failed. Never show "no alarms" for this: it is a different statement (§14).
        /// A malformed list (anything but `.timedOut`) disables alarms for the rest of the connection.
        case unreadable(ZeppAlarmListError)
    }

    /// One user edit: exactly one slot.
    public enum Write: Equatable {
        case set(ZeppAlarm)
        case delete(slot: UInt8)

        public var slot: UInt8 {
            switch self {
            case .set(let alarm): return alarm.slot
            case .delete(let slot): return slot
            }
        }
    }

    public enum WriteFailure: Equatable {
        /// An ack with a status other than `01` (nil: the status byte was missing).
        case status(UInt8?)
        /// No ack in time. The strap may or may not have applied the write: re-read.
        case noAck
    }

    /// The re-read after an acknowledged write (§15.2 step 7).
    public struct WriteCheck: Equatable {
        public let write: Write
        /// The strap's list after the write: show this, not the phone's idea of it.
        public let list: [ZeppAlarm]
        /// The written slot holds what was written (for a delete: the slot is empty).
        public let slotMatches: Bool
        /// Every other slot reads back exactly as before the write.
        public let otherSlotsUnchanged: Bool
    }

    public enum Event: Equatable {
        case listRead([ZeppAlarm])
        case listUnreadable(ZeppAlarmListError)
        /// `0f`: the list must be re-read before the next edit.
        case changedOnStrap
        case writeAcknowledged(Write)
        case writeFailed(Write, WriteFailure)
        case writeChecked(WriteCheck)
        /// The write was acknowledged but the re-read failed.
        case writeUnverified(Write, ZeppAlarmListError)
    }

    public enum Error: Swift.Error, Equatable {
        /// A read or write is in flight.
        case busy
        /// The strap returned a malformed list on this connection: alarms are unsupported until the
        /// next connection, and nothing is written (§12.4).
        case listMalformedThisConnection(ZeppAlarmListError)
        /// No well-formed list was read on this connection.
        case listNotRead
        /// `0f` arrived after the last read: re-read, then ask the user to confirm again.
        case listChangedOnStrap
        /// Alarms fire in strap-local time, so edits need a confirmed time set on this connection.
        case timeNotSet
        /// The strap already has 10 alarms.
        case noFreeSlot
        /// The slot holds no alarm to replace or delete.
        case slotEmpty(UInt8)
        /// v1 does not offer smart wake: a replace must keep the slot's current bit (§14).
        case smartWakeNotOffered
        case invalidAlarm(ZeppAlarmError)
    }

    public struct Output: Equatable {
        public var messages: [ZeppControlMessage] = []
        public var events: [Event] = []
    }

    private enum Pending: Equatable {
        case none
        case reading(deadline: Date)
        case writing(Write, before: [ZeppAlarm], deadline: Date)
        case verifying(Write, before: [ZeppAlarm], deadline: Date)
    }

    public let capabilities: ZeppControlCapabilities
    public let configuration: Configuration
    public private(set) var list: ListState = .notRead
    /// A `06 01` time-set reply was seen on this connection.
    public private(set) var isTimeSet = false
    /// A `0f` arrived after the last list request.
    public private(set) var isListStale = false
    /// The malformed list that disabled alarms for this connection (§12.4); nil while usable.
    public private(set) var malformedList: ZeppAlarmListError?
    private var pending: Pending = .none
    private var changeSeenSinceRequest = false

    public init(capabilities: ZeppControlCapabilities, configuration: Configuration = Configuration()) {
        self.capabilities = capabilities
        self.configuration = configuration
    }

    /// The strap's alarms, when a well-formed list was read on this connection.
    public var alarms: [ZeppAlarm]? {
        if case .read(let alarms) = list { return alarms }
        return nil
    }

    /// §14 "Alarms (view)": endpoint listed and a well-formed list read on this connection.
    public var canView: Bool {
        capabilities.isSupported(.alarms) && malformedList == nil && alarms != nil
    }

    /// §14 "Alarms (edit)": the view condition, a confirmed time set, no `0f` since the read, and
    /// nothing in flight.
    public var canEdit: Bool {
        canView && isTimeSet && !isListStale && pending == .none
    }

    public var isBusy: Bool { pending != .none }

    /// Free slots in the last list, lowest first; empty when no list was read.
    public var freeSlots: [UInt8] {
        guard let alarms else { return [] }
        let used = Set(alarms.map(\.slot))
        return (0..<ZeppAlarm.slotCount).filter { !used.contains($0) }
    }

    public var nextDeadline: Date? {
        switch pending {
        case .none: return nil
        case .reading(let deadline), .writing(_, _, let deadline), .verifying(_, _, let deadline): return deadline
        }
    }

    // MARK: Inputs

    /// Feed the reply to a time set on endpoint 0x0047. Only `06 01` counts. SPEC-GAP: a time set
    /// through the `0x2A2B` fallback has no reply, so it never enables edits.
    @discardableResult
    public mutating func noteTimeSetReply(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[0] == 0x06, payload[1] == 0x01 else { return false }
        isTimeSet = true
        return true
    }

    /// Reads the list (`09`). Read-only.
    public mutating func read(now: Date) throws -> Output {
        try capabilities.require(.alarms)
        if let malformedList { throw Error.listMalformedThisConnection(malformedList) }
        guard pending == .none else { throw Error.busy }
        pending = .reading(deadline: now.addingTimeInterval(configuration.replyTimeout))
        changeSeenSinceRequest = false
        return Output(messages: [message(ZeppAlarmCommand.readAll)])
    }

    /// A NEW alarm in the lowest free slot (§15.2 step 4). Smart wake is never set.
    public mutating func add(hour: UInt8, minute: UInt8, days: ZeppAlarmDays = .once, isEnabled: Bool = true,
                             now: Date) throws -> Output {
        let before = try writePreconditions()
        guard let slot = freeSlots.first else { throw Error.noFreeSlot }
        let alarm = ZeppAlarm(slot: slot, hour: hour, minute: minute, days: days, isEnabled: isEnabled)
        return try write(.set(alarm), before: before, now: now)
    }

    /// Replaces the alarm in `alarm.slot`, which must hold one. Change the fields the user edited on
    /// the alarm from `alarms` and pass it here; the write sends the full record, with the unknown
    /// flag bits and tail bytes zeroed (§15.2 step 4). Enable/disable is a replace with
    /// `isEnabled` changed (§12.2).
    public mutating func replace(_ alarm: ZeppAlarm, now: Date) throws -> Output {
        let before = try writePreconditions()
        guard let existing = before.first(where: { $0.slot == alarm.slot }) else { throw Error.slotEmpty(alarm.slot) }
        guard alarm.smartWake == existing.smartWake else { throw Error.smartWakeNotOffered }
        return try write(.set(alarm), before: before, now: now)
    }

    /// Deletes the alarm in `slot`, which must hold one. DESTRUCTIVE.
    public mutating func delete(slot: UInt8, now: Date) throws -> Output {
        let before = try writePreconditions()
        guard before.contains(where: { $0.slot == slot }) else { throw Error.slotEmpty(slot) }
        return try write(.delete(slot: slot), before: before, now: now)
    }

    /// A decoded payload from endpoint 0x000F.
    public mutating func receive(_ payload: [UInt8], now: Date) -> Output {
        guard let reply = ZeppAlarmReply.parse(payload) else { return Output() }
        switch reply {
        case .changedOnStrap:
            isListStale = true
            changeSeenSinceRequest = true
            return Output(events: [.changedOnStrap])
        case .list(let result):
            return receiveList(result)
        case .createAck(let status):
            guard case .writing(.set(let alarm), let before, _) = pending else { return Output() }
            return receiveAck(.set(alarm), status: status, before: before, now: now)
        case .deleteAck(let status):
            guard case .writing(.delete(let slot), let before, _) = pending else { return Output() }
            return receiveAck(.delete(slot: slot), status: status, before: before, now: now)
        case .updateAck:
            return Output()
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
            list = .unreadable(.timedOut)
            return Output(events: [.listUnreadable(.timedOut)])
        case .writing(let write, _, _):
            pending = .none
            isListStale = true
            return Output(events: [.writeFailed(write, .noAck)])
        case .verifying(let write, _, _):
            pending = .none
            isListStale = true
            list = .unreadable(.timedOut)
            return Output(events: [.writeUnverified(write, .timedOut)])
        }
    }

    // MARK: Steps

    private func message(_ payload: [UInt8]) -> ZeppControlMessage {
        ZeppControlMessage(endpoint: ZeppEndpoint.alarms, payload: payload)
    }

    /// §15.2 step 1 (and step 5's race check). Returns the list the edit is based on.
    private func writePreconditions() throws -> [ZeppAlarm] {
        try capabilities.require(.alarms)
        if let malformedList { throw Error.listMalformedThisConnection(malformedList) }
        guard pending == .none else { throw Error.busy }
        guard let alarms else { throw Error.listNotRead }
        guard !isListStale else { throw Error.listChangedOnStrap }
        guard isTimeSet else { throw Error.timeNotSet }
        return alarms
    }

    private mutating func write(_ write: Write, before: [ZeppAlarm], now: Date) throws -> Output {
        let payload: [UInt8]
        do {
            switch write {
            case .set(let alarm): payload = try ZeppAlarmCommand.createOrReplace(alarm)
            case .delete(let slot): payload = try ZeppAlarmCommand.delete(slot: slot)
            }
        } catch let error as ZeppAlarmError {
            throw Error.invalidAlarm(error)
        }
        pending = .writing(write, before: before, deadline: now.addingTimeInterval(configuration.replyTimeout))
        return Output(messages: [message(payload)])
    }

    private mutating func receiveAck(_ write: Write, status: UInt8?, before: [ZeppAlarm], now: Date) -> Output {
        guard status == ZeppAlarmReply.successStatus else {
            // The strap's state is unknown now: no blind retry, and re-read before the next edit.
            pending = .none
            isListStale = true
            return Output(events: [.writeFailed(write, .status(status))])
        }
        // §15.2 step 7: re-read and check the slot.
        pending = .verifying(write, before: before, deadline: now.addingTimeInterval(configuration.replyTimeout))
        changeSeenSinceRequest = false
        return Output(messages: [message(ZeppAlarmCommand.readAll)], events: [.writeAcknowledged(write)])
    }

    private mutating func receiveList(_ result: Result<[ZeppAlarm], ZeppAlarmListError>) -> Output {
        switch pending {
        case .reading:
            pending = .none
            switch result {
            case .success(let alarms):
                list = .read(alarms)
                isListStale = changeSeenSinceRequest
                return Output(events: [.listRead(alarms)])
            case .failure(let error):
                list = .unreadable(error)
                malformedList = error
                return Output(events: [.listUnreadable(error)])
            }
        case .verifying(let write, let before, _):
            pending = .none
            switch result {
            case .success(let after):
                list = .read(after)
                isListStale = changeSeenSinceRequest
                return Output(events: [.writeChecked(Self.check(write, before: before, after: after))])
            case .failure(let error):
                list = .unreadable(error)
                isListStale = true
                malformedList = error
                return Output(events: [.writeUnverified(write, error)])
            }
        case .none, .writing:
            // Not asked for: ignore it rather than let an unsolicited list stand in for a read.
            return Output()
        }
    }

    private static func check(_ write: Write, before: [ZeppAlarm], after: [ZeppAlarm]) -> WriteCheck {
        let target = write.slot
        let slotMatches: Bool
        switch write {
        case .set(let alarm): slotMatches = after.first { $0.slot == target }?.hasSameSetting(as: alarm) ?? false
        case .delete: slotMatches = !after.contains { $0.slot == target }
        }
        let others = (0..<ZeppAlarm.slotCount).filter { $0 != target }
        let otherSlotsUnchanged = others.allSatisfy { slot in
            let old = before.first { $0.slot == slot }
            let new = after.first { $0.slot == slot }
            switch (old, new) {
            case (nil, nil): return true
            case (let old?, let new?): return old.hasSameSetting(as: new)
            default: return false
            }
        }
        return WriteCheck(write: write, list: after, slotMatches: slotMatches, otherSlotsUnchanged: otherSlotsUnchanged)
    }
}
