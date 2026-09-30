// One-line human summaries of fetched rounds, for HelioVerify and logs. Aggregates only: no
// identifiers, and no per-sample dump.

import Foundation

public enum ZeppRoundSummary {

    public static func describe(_ round: ZeppFetchRound) -> String {
        let parsed = round.parsed
        var line = "\(round.type.displayName) [0x\(String(format: "%02x", round.type.rawValue))]: "
        line += "\(parsed.records.count) record(s), \(round.rawData.count) B"
        line += round.crcVerified ? ", CRC ok" : ", no CRC"
        if parsed.skippedRecords > 0 { line += ", \(parsed.skippedRecords) skipped" }
        if let span = span(parsed) { line += ", \(span)" }
        let stats = details(parsed.records)
        if !stats.isEmpty { line += " — " + stats }
        return line
    }

    static func span(_ parsed: ZeppParsedRecords) -> String? {
        let times = recordTimes(parsed.records)
        guard let first = times.min(), let last = times.max() else { return nil }
        return "\(iso(first)) … \(iso(last))"
    }

    static func details(_ batch: ZeppRecordBatch) -> String {
        switch batch {
        case .activity(let minutes):
            let hr = minutes.compactMap(\.heartRate)
            let steps = minutes.reduce(0) { $0 + Int($1.steps) }
            let notWorn = minutes.filter { $0.kind == ZeppActivityMinute.kindNotWorn }.count
            return "HR \(range(hr)) bpm over \(hr.count) min, \(steps) steps, \(notWorn) min not worn"
        case .manualHeartRate(let r), .restingHeartRate(let r), .maxHeartRate(let r):
            return "\(range(r.compactMap(\.beatsPerMinute))) bpm"
        case .hrv(let r):
            return "\(range(r.map { Int($0.milliseconds) })) ms (statistic unknown)"
        case .spo2(let r):
            let auto = r.filter(\.isAutomatic).count
            return "\(range(r.compactMap(\.percent))) %, \(auto) automatic"
        case .sleepSpO2(let r):
            return "\(range(r.compactMap(\.percent))) %"
        case .temperature(let minutes):
            let valid = minutes.compactMap(\.celsius)
            guard let lo = valid.min(), let hi = valid.max() else { return "no valid readings" }
            return String(format: "%.2f–%.2f °C over %d min", lo, hi, valid.count)
        case .sleepRespiratoryRate(let r):
            return "\(range(r.map { Int($0.breathsPerMinute) })) breaths/min"
        case .autoStress(let minutes):
            let valid = minutes.compactMap(\.level)
            return "\(range(valid)) over \(valid.count) min"
        case .manualStress(let r):
            return range(r.compactMap(\.level))
        case .pai(let r):
            guard let last = r.last else { return "" }
            return String(format: "latest total PAI %.1f", last.totalPAI)
        case .sleepSession(let sessions):
            return sessions.map { s in
                "\(iso(s.sleepStart))→\(iso(s.sleepEnd)) score \(s.score), \(s.stages.count) stages "
                    + "(REM \(s.totalREMMinutes) / light \(s.totalLightMinutes) / deep \(s.totalDeepMinutes) / awake \(s.totalAwakeMinutes) min)"
            }.joined(separator: "; ")
        }
    }

    static func recordTimes(_ batch: ZeppRecordBatch) -> [Date] {
        switch batch {
        case .activity(let r): return r.map(\.time)
        case .manualHeartRate(let r), .restingHeartRate(let r), .maxHeartRate(let r): return r.map(\.time)
        case .hrv(let r): return r.map(\.time)
        case .spo2(let r): return r.map(\.time)
        case .sleepSpO2(let r): return r.map(\.time)
        case .temperature(let r): return r.map(\.time)
        case .sleepRespiratoryRate(let r): return r.map(\.time)
        case .autoStress(let r): return r.map(\.time)
        case .manualStress(let r): return r.map(\.time)
        case .pai(let r): return r.map(\.time)
        case .sleepSession(let r): return r.map(\.time)
        }
    }

    private static func range(_ values: [Int]) -> String {
        guard let lo = values.min(), let hi = values.max() else { return "none" }
        return lo == hi ? "\(lo)" : "\(lo)–\(hi)"
    }

    /// ISO 8601 in UTC.
    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// HelioVerify `--trace` lines for the history fetch. Control messages are printed in full: they
/// carry only commands, lengths, timestamps and CRCs. A data packet is printed as its length and
/// counter byte only, never its payload (that is health data).
public enum ZeppFetchTrace {

    /// `→ …0004 01 01 ea 07 …` / `← …0004 10 01 01 …`; `channel` names Path B's `0x004B` instead.
    public static func control(_ bytes: [UInt8], outgoing: Bool, channel: String = "…0004") -> String {
        let hex = bytes.isEmpty ? "(empty)" : bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "\(outgoing ? "→" : "←") \(channel) \(hex)"
    }

    /// `← …0005 241 B, counter 00`.
    public static func dataPacket(_ bytes: [UInt8]) -> String {
        guard let counter = bytes.first else { return "← …0005 0 B (empty)" }
        return "← …0005 \(bytes.count) B, counter " + String(format: "%02x", counter)
    }
}
