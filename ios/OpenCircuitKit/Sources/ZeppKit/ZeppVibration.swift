// Vibration (ZEPP_PROTOCOL.md §13).
//
// What v1 can make the motor do, and what it deliberately can't:
// - "Vibrate now" is the find-device pulse, `ZeppFindDevice.buzz` (§13.2). No reference has a
//   dedicated vibrate or motor-test opcode.
// - Strap-side haptic alerts are persistent config settings the strap evaluates itself (§13.4).
//   `ZeppHapticAlertSettings` offers only the four Amazfit documents for the Helio, only when the
//   strap reported them with the expected type and allowed values, and builds a write only for a
//   value the strap offered (§14, §15.3).
// - Vibration patterns (endpoint 0x0018, §13.1) are never exposed: a set is persistent and cannot be
//   read back (§15.1). The layout encoder below is INTERNAL so no client can send it; it exists to
//   pin the 🟡 layout with a test.
// - SPEC-GAP: pattern "test" (set with test = `01`) is 🔴 on the Helio and may persist (§13.2): not
//   used.

import Foundation

/// The strap-side haptic alerts v1 may offer: the HEALTH-group (`0x08`) args whose feature Amazfit
/// documents for the Helio (§13.4). Whether the strap reports each arg is 🔴; a strap that doesn't
/// report one simply doesn't get it offered.
///
/// SPEC-GAP: the other §13.4 rows (inactivity `41`–`46`, goal alert `51`, goals `52`–`57`, SOUND &
/// VIBRATION group `03`, SYSTEM DND in group `0a`, WORKOUT `41`) have 🔴 Helio evidence or meaning:
/// not offered.
public enum ZeppHapticAlert: String, CaseIterable, Equatable {
    /// Byte threshold: `00` off, otherwise bpm.
    case highHeartRate
    /// Byte threshold: `00` off, otherwise bpm.
    case lowHeartRate
    /// Switch; the strap also needs stress monitoring (HEALTH `13`) on (§13.4).
    case relaxReminder
    /// Byte threshold: `00` off, otherwise %. Needs all-day SpO₂ (HEALTH `31`) on (§13.4).
    case lowSpO2

    public var group: UInt8 { ZeppConfig.healthGroup }

    public var argument: UInt8 {
        switch self {
        case .highHeartRate: return 0x02
        case .lowHeartRate: return 0x03
        case .relaxReminder: return 0x14
        case .lowSpO2: return 0x32
        }
    }

    /// true for a bool (`0x0b`) switch, false for a byte (`0x10`) threshold.
    public var isSwitch: Bool { self == .relaxReminder }
}

/// One alert as the strap reported it.
public struct ZeppHapticAlertSetting: Equatable {
    public let alert: ZeppHapticAlert
    /// `.bool` for a switch, `.byte` for a threshold (`00` = off).
    public let value: ZeppConfigValue
    /// A threshold's allowed values exactly as the strap listed them (`00` = off); nil for a switch.
    public let allowedValues: [UInt8]?
}

/// The haptic alerts the strap reported, and validated single-argument writes for them.
public struct ZeppHapticAlertSettings: Equatable {

    /// The HEALTH group versions the §13.4 args are known at.
    public static let knownHealthVersions: ClosedRange<UInt8> = 1...3

    /// HEALTH, constraints on, the four alert args (§13.4 worked example H: `03 01 08 04 02 03 14 32`).
    public static var readRequest: [UInt8] {
        ZeppConfig.readRequest(group: ZeppConfig.healthGroup,
                               arguments: ZeppHapticAlert.allCases.map(\.argument), includeConstraints: true)
    }

    public enum Error: Swift.Error, Equatable {
        /// The strap did not report the alert in a usable form: hide it, never write it.
        case unsupported(ZeppHapticAlert)
        /// The value's type is wrong, or it is not one of the strap's allowed values.
        case valueNotAllowed(ZeppHapticAlert, ZeppConfigValue)
    }

    /// The HEALTH group version from the read reply; a write echoes it (§9, §13.4).
    public let groupVersion: UInt8?
    /// The alerts that may be shown, in `ZeppHapticAlert.allCases` order.
    public let settings: [ZeppHapticAlertSetting]

    /// §14 "Haptic alert settings": the config endpoint is listed, the config capabilities reply
    /// lists HEALTH at an understood service version, and the constraints-included HEALTH read
    /// reply (at a known group version) holds the arg exactly once with the expected type.
    public init(capabilities: ZeppControlCapabilities, configCapabilities: ZeppConfigCapabilities?,
                healthReply: ZeppConfigReadReply?) {
        guard capabilities.isSupported(.hapticAlerts),
              let configCapabilities, configCapabilities.isVersionUnderstood,
              configCapabilities.groups.contains(ZeppConfig.healthGroup),
              let reply = healthReply, reply.group == ZeppConfig.healthGroup, reply.includesConstraints,
              Self.knownHealthVersions.contains(reply.groupVersion) else {
            groupVersion = nil
            settings = []
            return
        }
        groupVersion = reply.groupVersion
        settings = ZeppHapticAlert.allCases.compactMap { alert in
            let matches = reply.entries.filter { $0.argument == alert.argument }
            guard matches.count == 1, let entry = matches.first else { return nil }
            switch (alert.isSwitch, entry.value, entry.constraint) {
            case (true, .bool, _):
                return ZeppHapticAlertSetting(alert: alert, value: entry.value, allowedValues: nil)
            case (false, .byte, .allowedValues(let allowed)?) where !allowed.isEmpty:
                return ZeppHapticAlertSetting(alert: alert, value: entry.value, allowedValues: allowed)
            default:
                // Wrong type, or a threshold without allowed values to validate against: hide it.
                return nil
            }
        }
    }

    public func setting(_ alert: ZeppHapticAlert) -> ZeppHapticAlertSetting? {
        settings.first { $0.alert == alert }
    }

    /// The config write for ONE alert (`05 08 <version> 00 01 <arg> <type> <value>`), after
    /// validating the value against what the strap offered. PERSISTENT: send it only for an explicit
    /// user edit of that one setting, expect `06 01`, then re-read (§15.3).
    public func writeRequest(_ alert: ZeppHapticAlert, value: ZeppConfigValue) throws -> [UInt8] {
        guard let setting = setting(alert), let groupVersion else { throw Error.unsupported(alert) }
        switch (value, setting.allowedValues) {
        case (.bool, nil) where alert.isSwitch:
            break
        case (.byte(let byte), let allowed?) where allowed.contains(byte):
            break
        default:
            throw Error.valueNotAllowed(alert, value)
        }
        guard let payload = ZeppConfig.writeRequest(group: alert.group, groupVersion: groupVersion,
                                                    entries: [(alert.argument, value)]) else {
            throw Error.valueNotAllowed(alert, value)
        }
        return payload
    }
}

/// §13.1 vibration-pattern "set" layout: `03`, type, source (`01` custom / `00` device default),
/// test (`01` play now), n, then n × (u16 on ms, u16 off ms).
///
/// INTERNAL ON PURPOSE. v1 must not send it (§14, §15.1): it overwrites a pattern the user made in
/// Zepp, and there is no read command to save that pattern first. Kept only so a test pins the
/// layout for a later phase.
enum ZeppVibrationPatternCommand {

    struct Pair: Equatable {
        let onMilliseconds: UInt16
        let offMilliseconds: UInt16
    }

    /// The reference caps a pattern at 10 s in total (on + off), attributing the cap to the official
    /// app (§13.1).
    static let maxTotalMilliseconds = 10_000

    /// nil for an empty custom pattern, more than 255 pairs, or more than 10 s in total. `pattern`
    /// nil = the device default (source `00`, n = `00`).
    static func set(type: UInt8, pattern: [Pair]?, playNow: Bool) -> [UInt8]? {
        let test: UInt8 = playNow ? 0x01 : 0x00
        guard let pattern else { return [0x03, type, 0x00, test, 0x00] }
        let total = pattern.reduce(0) { $0 + Int($1.onMilliseconds) + Int($1.offMilliseconds) }
        guard !pattern.isEmpty, pattern.count <= Int(UInt8.max), total <= maxTotalMilliseconds else { return nil }
        var out: [UInt8] = [0x03, type, 0x01, test, UInt8(pattern.count)]
        for pair in pattern {
            out += ZeppLE.u16(pair.onMilliseconds) + ZeppLE.u16(pair.offMilliseconds)
        }
        return out
    }

    /// Reply `04 <status>`: the status, or nil when the payload is not that reply.
    static func parseReply(_ payload: [UInt8]) -> UInt8? {
        guard payload.count >= 2, payload[0] == 0x04 else { return nil }
        return payload[1]
    }
}
