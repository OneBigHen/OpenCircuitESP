// GATT identifiers and device identification (ZEPP_PROTOCOL.md §1–§2), as plain strings so this
// module stays free of CoreBluetooth. The BLE layer turns them into `CBUUID`s.

import Foundation

/// The characteristics ZeppKit reads, writes or listens to.
public enum ZeppCharacteristic: String, CaseIterable, Equatable {
    /// `…0016`: phone → device chunks; device chunk acks arrive here as notifications.
    case chunkedWrite
    /// `…0017`: device → phone chunks (notify); the phone writes its chunk acks here.
    case chunkedRead
    /// `…0004`: history-fetch control, Path A (§6.1).
    case activityControl
    /// `…0005`: history-fetch data packets (§6.1).
    case activityData
    /// `0x2A37`: standard Heart Rate Measurement (§7.1).
    case heartRateMeasurement
    /// `0x2A19`: standard Battery Level. Existence on the Helio is unconfirmed (§2 🔴).
    case batteryLevel
    /// `0x2A2B`: Current Time, the time-set fallback (§5.1).
    case currentTime
    /// `0x2A26` / `0x2A27`: Device Information firmware / hardware revision strings.
    case firmwareRevision
    case hardwareRevision

    /// UUID string: full 128-bit form for the Huami characteristics, 16-bit form for SIG ones.
    public var uuidString: String {
        switch self {
        case .chunkedWrite: return ZeppGATT.huamiUUID(0x0016)
        case .chunkedRead: return ZeppGATT.huamiUUID(0x0017)
        case .activityControl: return ZeppGATT.huamiUUID(0x0004)
        case .activityData: return ZeppGATT.huamiUUID(0x0005)
        case .heartRateMeasurement: return "2A37"
        case .batteryLevel: return "2A19"
        case .currentTime: return "2A2B"
        case .firmwareRevision: return "2A26"
        case .hardwareRevision: return "2A27"
        }
    }
}

public enum ZeppGATT {
    /// The Huami main service.
    public static let mainServiceUUID = "FEE0"
    public static let heartRateServiceUUID = "180D"
    public static let batteryServiceUUID = "180F"
    public static let deviceInformationServiceUUID = "180A"
    /// The firmware-update service. Never write to it (§2).
    public static let firmwareUpdateServiceUUID = "00001530-0000-3512-2118-0009af100700"

    /// `0000XXXX-0000-3512-2118-0009af100700`.
    public static func huamiUUID(_ short: UInt16) -> String {
        String(format: "0000%04x-0000-3512-2118-0009af100700", short)
    }
}

/// Which Zepp OS product an advertised name belongs to (§1).
public enum ZeppDeviceModel: String, Equatable, CaseIterable {
    case helioStrap = "Amazfit Helio Strap"
    case helioRing = "Amazfit Helio Ring"

    /// Matches the exact product name, optionally followed by one or more `-`/space and exactly four
    /// `[A-Z0-9]` (`Amazfit Helio Strap`, `Amazfit Helio Strap 1A2B`, `Amazfit Helio Strap-1A2B`).
    /// Anything else, including other Zepp OS watches, is nil.
    public static func match(advertisedName name: String) -> ZeppDeviceModel? {
        for model in allCases {
            guard name.hasPrefix(model.rawValue) else { continue }
            let rest = name.dropFirst(model.rawValue.count)
            if rest.isEmpty { return model }
            let separators = rest.prefix { $0 == "-" || $0 == " " }
            let suffix = rest.dropFirst(separators.count)
            guard !separators.isEmpty, suffix.count == 4 else { continue }
            let isSuffixValid = suffix.allSatisfy { character in
                guard let ascii = character.asciiValue else { return false }
                return (0x41...0x5A).contains(ascii) || (0x30...0x39).contains(ascii)
            }
            if isSuffixValid { return model }
        }
        return nil
    }
}
