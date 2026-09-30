// Post-auth session commands and live-data parsers (ZEPP_PROTOCOL.md §5, §7): battery, the
// HEALTH settings that decide what the strap records, heart-rate control, and the standard
// Heart Rate Measurement / Battery Level characteristics. Builders return message payloads;
// the caller sends them to the named endpoint through `ZeppLink`.
//
// SPEC-GAP (device info, endpoint 0x0043, §5.3): flag bit 0 is "a length-prefixed blob" with no
// prefix width, and the Helio Strap's flags (0x7f) set bit 0, so no field after it can be located.
// Not implemented; HelioVerify reads the Device Information Service (0x2A26 / 0x2A27) instead.

import Foundation

// MARK: - Battery (endpoint 0x0029, §5.3)

public struct ZeppBatteryStatus: Equatable {
    /// Percent, 0–100.
    public let level: Int
    /// nil when the charging byte is neither `00` nor `01`.
    public let isCharging: Bool?
    /// When the strap was last charged, if the reply carries a valid date.
    public let lastCharge: Date?
    /// Level at the last charge, percent, if present and 0–100.
    public let lastChargeLevel: Int?

    public static let request: [UInt8] = [0x03]

    /// Reply `04` + 20 bytes. Offsets are relative to the full reply: `[2]` level, `[3]` charging,
    /// `[11..18]` last-charge date (u16 year, month, day, h, m, s, i8 quarter-hour offset), `[20]`
    /// last-charge level. nil unless it starts with `04` and has a 0–100 level.
    public static func parse(_ payload: [UInt8]) -> ZeppBatteryStatus? {
        guard payload.count >= 4, payload[0] == 0x04, payload[2] <= 100 else { return nil }
        let charging: Bool?
        switch payload[3] {
        case 0x00: charging = false
        case 0x01: charging = true
        default: charging = nil
        }
        let lastCharge = payload.count >= 19 ? ZeppFetchTimestamp.decode(payload[11..<19]) : nil
        var lastLevel: Int?
        if payload.count >= 21, payload[20] <= 100 { lastLevel = Int(payload[20]) }
        return ZeppBatteryStatus(level: Int(payload[2]), isCharging: charging,
                                 lastCharge: lastCharge, lastChargeLevel: lastLevel)
    }
}

// MARK: - Heart-rate control (endpoint 0x001D, §7.1)

public enum ZeppHeartRateControl {
    public static let start: [UInt8] = [0x04, 0x01]
    /// Must be re-sent every second to keep the stream running.
    public static let keepRunning: [UInt8] = [0x04, 0x02]
    public static let stop: [UInt8] = [0x04, 0x00]

    public enum Event: Equatable {
        /// `05 <status>`; `00` observed as success.
        case controlReply(status: UInt8)
        /// `06 01`.
        case fellAsleep
        /// `06 00`.
        case wokeUp
    }

    public static func parse(_ payload: [UInt8]) -> Event? {
        guard payload.count >= 2 else { return nil }
        switch (payload[0], payload[1]) {
        case (0x05, let status): return .controlReply(status: status)
        case (0x06, 0x01): return .fellAsleep
        case (0x06, 0x00): return .wokeUp
        default: return nil
        }
    }
}

// MARK: - Standard GATT live data (§7.1, §7.3)

/// A Heart Rate Measurement (`0x2A37`) notification, per the Bluetooth Heart Rate Service spec.
public struct ZeppHeartRateMeasurement: Equatable {
    public let beatsPerMinute: Int
    /// nil when the sensor does not report contact.
    public let sensorContact: Bool?
    public let energyExpendedKilojoules: Int?
    /// RR intervals in seconds (wire unit 1/1024 s).
    public let rrIntervals: [Double]

    public static func parse(_ bytes: [UInt8]) -> ZeppHeartRateMeasurement? {
        var reader = ZeppByteReader(bytes)
        guard let flags = reader.u8() else { return nil }
        let bpm: Int
        if flags & 0x01 != 0 {
            guard let value = reader.u16() else { return nil }
            bpm = Int(value)
        } else {
            guard let value = reader.u8() else { return nil }
            bpm = Int(value)
        }
        let contactSupported = flags & 0x04 != 0
        let contact: Bool? = contactSupported ? (flags & 0x02 != 0) : nil
        var energy: Int?
        if flags & 0x08 != 0 {
            guard let value = reader.u16() else { return nil }
            energy = Int(value)
        }
        var rr = [Double]()
        if flags & 0x10 != 0 {
            while reader.remaining >= 2, let value = reader.u16() {
                rr.append(Double(value) / 1024)
            }
        }
        return ZeppHeartRateMeasurement(beatsPerMinute: bpm, sensorContact: contact,
                                        energyExpendedKilojoules: energy, rrIntervals: rr)
    }
}

public enum ZeppBatteryLevelCharacteristic {
    /// `0x2A19`: one byte, 0–100.
    public static func parse(_ bytes: [UInt8]) -> Int? {
        guard let level = bytes.first, level <= 100 else { return nil }
        return Int(level)
    }
}

// MARK: - Config (endpoint 0x000A, §5.5), read-only

public enum ZeppConfigValue: Equatable {
    case bool(Bool)
    case byte(UInt8)
    case byteList([UInt8])
    case short(Int16)
    case shortList([Int16])
    case int(Int32)
    case string(String)
    case hourMinute(hour: UInt8, minute: UInt8)
    /// Milliseconds since 1970.
    case timestamp(Int64)
    case unboundedInt(Int32)
}

public struct ZeppConfigEntry: Equatable {
    public let argument: UInt8
    public let value: ZeppConfigValue
}

public struct ZeppConfigReadReply: Equatable {
    public let group: UInt8
    public let groupVersion: UInt8
    public let entries: [ZeppConfigEntry]
    /// True when parsing stopped early (an unknown type code or a truncated entry): `entries`
    /// holds what was parsed before that point (§5.5).
    public let isPartial: Bool
}

public enum ZeppConfig {

    /// The HEALTH settings group.
    public static let healthGroup: UInt8 = 0x08

    public enum HealthArgument {
        public static let heartRateMonitoring: UInt8 = 0x01
        public static let heartRateDuringActivity: UInt8 = 0x04
        public static let heartRateSharing: UInt8 = 0x05
        public static let highAccuracySleep: UInt8 = 0x11
        public static let sleepBreathingQuality: UInt8 = 0x12
        public static let stressMonitoring: UInt8 = 0x13
        public static let allDaySpO2: UInt8 = 0x31
    }

    /// The HEALTH arguments whose off state means a fetch type comes back empty.
    public static let recordingArguments: [UInt8] = [
        HealthArgument.heartRateMonitoring, HealthArgument.heartRateDuringActivity,
        HealthArgument.heartRateSharing, HealthArgument.highAccuracySleep,
        HealthArgument.sleepBreathingQuality, HealthArgument.stressMonitoring,
        HealthArgument.allDaySpO2,
    ]

    /// `03`, include-constraints `00`, group, arg count, args.
    /// SPEC-GAP: arg count `00` "asks for all args" is 🔴; ZeppKit always names the arguments.
    public static func readRequest(group: UInt8, arguments: [UInt8]) -> [UInt8] {
        [0x03, 0x00, group, UInt8(clamping: arguments.count)] + arguments
    }

    /// Reply: `04`, status (`01` ok), group, group version, includes-constraints, entry count,
    /// entries. nil unless the header is intact and the status is `01`.
    public static func parseReadReply(_ payload: [UInt8]) -> ZeppConfigReadReply? {
        var reader = ZeppByteReader(payload)
        guard reader.u8() == 0x04, reader.u8() == 0x01,
              let group = reader.u8(), let version = reader.u8(),
              let constraintsByte = reader.u8(), let count = reader.u8() else { return nil }
        let withConstraints = constraintsByte == 0x01
        var entries = [ZeppConfigEntry]()
        for _ in 0..<Int(count) {
            guard let entry = parseEntry(&reader, withConstraints: withConstraints) else {
                return ZeppConfigReadReply(group: group, groupVersion: version, entries: entries, isPartial: true)
            }
            entries.append(entry)
        }
        return ZeppConfigReadReply(group: group, groupVersion: version, entries: entries, isPartial: false)
    }

    private static func parseEntry(_ r: inout ZeppByteReader, withConstraints: Bool) -> ZeppConfigEntry? {
        guard let argument = r.u8(), let type = r.u8() else { return nil }
        let value: ZeppConfigValue
        // SPEC-GAP: §5.5 lists the constraint bytes per type but not their position; they are
        // assumed to follow the value. ZeppKit's own requests ask for no constraints.
        switch type {
        case 0x0b:
            guard let raw = r.u8(), raw <= 1 else { return nil }
            value = .bool(raw == 1)
        case 0x10:
            guard let raw = r.u8() else { return nil }
            if withConstraints { guard let n = r.u8(), r.skip(Int(n)) else { return nil } }
            value = .byte(raw)
        case 0x11:
            guard let n = r.u8(), let list = r.take(Int(n)) else { return nil }
            if withConstraints { guard let m = r.u8(), r.skip(Int(m)) else { return nil } }
            value = .byteList(list)
        case 0x01:
            guard let raw = r.i16() else { return nil }
            if withConstraints { guard r.skip(4) else { return nil } }
            value = .short(raw)
        case 0x02:
            guard let n = r.u8() else { return nil }
            var list = [Int16]()
            for _ in 0..<Int(n) {
                guard let item = r.i16() else { return nil }
                list.append(item)
            }
            if withConstraints { guard r.skip(6) else { return nil } }
            value = .shortList(list)
        case 0x03:
            guard let raw = r.i32() else { return nil }
            if withConstraints { guard r.skip(8) else { return nil } }
            value = .int(raw)
        case 0x20:
            guard let text = r.nulTerminatedString() else { return nil }
            if withConstraints { guard r.skip(1) else { return nil } }
            value = .string(text)
        case 0x21:
            guard let text = r.nulTerminatedString() else { return nil }
            if withConstraints {
                guard r.skip(1), let n = r.u8() else { return nil }
                for _ in 0..<Int(n) { guard r.nulTerminatedString() != nil else { return nil } }
            }
            value = .string(text)
        case 0x30:
            guard let hour = r.u8(), let minute = r.u8() else { return nil }
            value = .hourMinute(hour: hour, minute: minute)
        case 0x40:
            guard let raw = r.i64() else { return nil }
            value = .timestamp(raw)
        case 0x50:
            guard let raw = r.i32() else { return nil }
            value = .unboundedInt(raw)
        default:
            // No length field: an unknown type makes the rest unparseable (§5.5).
            return nil
        }
        return ZeppConfigEntry(argument: argument, value: value)
    }
}

/// The HEALTH switches that decide what the strap RECORDS (§5.5), read after auth so the user can
/// be warned instead of silently fetching nothing.
public struct ZeppHealthSettings: Equatable {
    /// `00` off, `ff` automatic, `N` every N minutes; nil when not reported.
    public let heartRateMonitoring: UInt8?
    public let heartRateDuringActivity: Bool?
    public let heartRateSharing: Bool?
    public let highAccuracySleep: Bool?
    public let sleepBreathingQuality: Bool?
    public let stressMonitoring: Bool?
    public let allDaySpO2: Bool?

    public init(_ reply: ZeppConfigReadReply) {
        func bool(_ arg: UInt8) -> Bool? {
            for entry in reply.entries where entry.argument == arg {
                if case .bool(let v) = entry.value { return v }
            }
            return nil
        }
        var monitoring: UInt8?
        for entry in reply.entries where entry.argument == ZeppConfig.HealthArgument.heartRateMonitoring {
            if case .byte(let v) = entry.value { monitoring = v }
        }
        heartRateMonitoring = monitoring
        heartRateDuringActivity = bool(ZeppConfig.HealthArgument.heartRateDuringActivity)
        heartRateSharing = bool(ZeppConfig.HealthArgument.heartRateSharing)
        highAccuracySleep = bool(ZeppConfig.HealthArgument.highAccuracySleep)
        sleepBreathingQuality = bool(ZeppConfig.HealthArgument.sleepBreathingQuality)
        stressMonitoring = bool(ZeppConfig.HealthArgument.stressMonitoring)
        allDaySpO2 = bool(ZeppConfig.HealthArgument.allDaySpO2)
    }

    /// One line per switch that is OFF, naming what will come back empty. Settings the strap did
    /// not report are not warned about (unknown is not off).
    public var warnings: [String] {
        var out = [String]()
        if heartRateMonitoring == 0x00 { out.append("all-day heart-rate monitoring is off: activity HR, resting/max HR and HRV may be empty") }
        if heartRateDuringActivity == false { out.append("heart rate during activity is off") }
        if heartRateSharing == false { out.append("heart-rate sharing (probably Zepp's \"Heart Rate Push\") is off: standard live HR may not broadcast") }
        if highAccuracySleep == false { out.append("high-accuracy sleep monitoring is off: sleep staging may be missing") }
        if sleepBreathingQuality == false { out.append("sleep breathing-quality monitoring is off: sleep SpO2 / respiratory rate may be empty") }
        if stressMonitoring == false { out.append("stress monitoring is off: stress (auto) will be empty") }
        if allDaySpO2 == false { out.append("all-day SpO2 monitoring is off: automatic SpO2 will be empty") }
        return out
    }
}
