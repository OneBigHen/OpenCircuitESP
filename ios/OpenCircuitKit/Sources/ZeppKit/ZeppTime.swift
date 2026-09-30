// Time encodings (ZEPP_PROTOCOL.md §5.1, §6.2, §6.4). Every function takes the time zone
// explicitly, so nothing here depends on the process's current zone.

import Foundation

/// The 8-byte timestamp of the history-fetch "since" and start-reply fields: u16 year, month, day,
/// hour, minute (local), u8 second, i8 UTC offset INCLUDING DST in quarter-hours (§6.2).
public enum ZeppFetchTimestamp {

    public static let length = 8

    /// Local fields in `timeZone`. Seconds are sent as 00 by default: minute precision (§6.2).
    public static func encode(_ date: Date, timeZone: TimeZone, includeSeconds: Bool = false) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(clamping: c.year ?? 0)
        var out = ZeppLE.u16(year)
        out.append(UInt8(clamping: c.month ?? 0))
        out.append(UInt8(clamping: c.day ?? 0))
        out.append(UInt8(clamping: c.hour ?? 0))
        out.append(UInt8(clamping: c.minute ?? 0))
        out.append(includeSeconds ? UInt8(clamping: c.second ?? 0) : 0)
        out.append(UInt8(bitPattern: quarterHourOffset(timeZone, at: date)))
        return out
    }

    /// The absolute instant: local fields − offset × 15 min, using the timestamp's OWN offset byte
    /// (§6.4), never the phone's zone. nil when a field is out of range or the input is short.
    public static func decode(_ bytes: ArraySlice<UInt8>) -> Date? {
        var reader = ZeppByteReader(bytes)
        guard let year = reader.u16(), let month = reader.u8(), let day = reader.u8(),
              let hour = reader.u8(), let minute = reader.u8(), let second = reader.u8(),
              let offset = reader.i8() else { return nil }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else {
            return nil
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: Int(year), month: Int(month), day: Int(day),
                                        hour: Int(hour), minute: Int(minute), second: Int(second))
        guard let asIfUTC = utc.date(from: components),
              utc.component(.day, from: asIfUTC) == Int(day) else { return nil }
        return asIfUTC.addingTimeInterval(-TimeInterval(offset) * 900)
    }

    /// The zone's offset from UTC (DST included) at `date`, in quarter-hours.
    public static func quarterHourOffset(_ timeZone: TimeZone, at date: Date) -> Int8 {
        Int8(clamping: timeZone.secondsFromGMT(for: date) / 900)
    }
}

/// Time endpoint (0x0047) commands, §5.1.
public enum ZeppTimeCommand {

    /// `05` + 11 bytes: u16 year, month, day, hour, minute, second, day of week (Sunday = 0),
    /// fraction in 1/256 s, `08` when DST is in effect else `00`, i8 UTC offset incl. DST in
    /// quarter-hours. The same 11 bytes (without `05`) are the `0x2A2B` fallback.
    public static func setTime(_ date: Date, timeZone: TimeZone) -> [UInt8] {
        [0x05] + currentTimeBytes(date, timeZone: timeZone)
    }

    public static func currentTimeBytes(_ date: Date, timeZone: TimeZone) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday, .nanosecond],
                                        from: date)
        var out = ZeppLE.u16(UInt16(clamping: c.year ?? 0))
        out.append(UInt8(clamping: c.month ?? 0))
        out.append(UInt8(clamping: c.day ?? 0))
        out.append(UInt8(clamping: c.hour ?? 0))
        out.append(UInt8(clamping: c.minute ?? 0))
        out.append(UInt8(clamping: c.second ?? 0))
        out.append(UInt8(clamping: (c.weekday ?? 1) - 1))   // Calendar: Sunday = 1
        let nanos = c.nanosecond ?? 0
        out.append(UInt8(clamping: nanos * 256 / 1_000_000_000))
        out.append(timeZone.isDaylightSavingTime(for: date) ? 0x08 : 0x00)
        out.append(UInt8(bitPattern: ZeppFetchTimestamp.quarterHourOffset(timeZone, at: date)))
        return out
    }

    /// `07` + u32 Unix seconds of the next transition + i16 offset change in seconds; nil when the
    /// zone has no future transition (§5.1: skip it then).
    public static func nextDSTTransition(after date: Date, timeZone: TimeZone) -> [UInt8]? {
        guard let transition = timeZone.nextDaylightSavingTimeTransition(after: date) else { return nil }
        let before = timeZone.secondsFromGMT(for: transition.addingTimeInterval(-1))
        let after = timeZone.secondsFromGMT(for: transition)
        let seconds = transition.timeIntervalSince1970
        guard seconds >= 0, seconds <= TimeInterval(UInt32.max) else { return nil }
        return [0x07] + ZeppLE.u32(UInt32(seconds)) + ZeppLE.i16(Int16(clamping: after - before))
    }

    /// Reply `06 <status>` (set time) / `08 <status>` (DST); status `01` observed as success.
    public static func isSuccessReply(_ payload: [UInt8]) -> Bool {
        payload.count >= 2 && (payload[0] == 0x06 || payload[0] == 0x08) && payload[1] == 0x01
    }
}
