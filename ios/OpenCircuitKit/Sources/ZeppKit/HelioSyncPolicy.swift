// The Amazfit Helio Strap's app-side rules (#215 phase 3; the decisions of record are
// briefs/helio-decisions.md 4, 8–17): what a pasted key is, where each history type's next fetch
// starts, and which parts of a fetched round may be stored and written to Apple Health.
//
// Pure: no CoreBluetooth, HealthKit or SwiftData, so every rule is covered by `swift test`. The app
// (ios/OpenCircuit/Helio) only moves bytes and rows.

import Foundation
import OpenCircuitKit

// MARK: - Key text (decision 4)

/// The 16-byte auth key as a person pastes it.
public enum HelioKeyText {

    /// The key as 32 lower-case hex digits, or nil. Accepts exactly 32 hex digits with any
    /// whitespace and colons anywhere, after one optional leading `0x`/`0X`. Anything else (31 or
    /// 33 digits, a hyphen, a non-hex letter, a full-width digit) is rejected: a wrong key must be a
    /// visible error, never a fallback (ZEPP_PROTOCOL.md §4.1, §9 #12).
    public static func normalized(_ text: String) -> String? {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.hasPrefix("0x") || body.hasPrefix("0X") { body = body.dropFirst(2) }
        let digits = body.filter { !$0.isWhitespace && $0 != ":" }
        guard digits.count == 32, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return digits.lowercased()
    }

    /// The key for `ZeppLink`, or nil for anything `normalized` rejects.
    public static func parse(_ text: String) -> ZeppAuthKey? {
        normalized(text).flatMap { ZeppAuthKey(hex: $0) }
    }
}

// MARK: - Apple Health policy (decisions 12, 14, 15, 17)

public enum HelioHealthPolicy {

    /// Decision 14: Apple Health's only HRV type is SDNN, and the strap's HRV statistic is unverified
    /// (RMSSD vs SDNN, ZEPP_PROTOCOL.md §6.5 🔴). The strap's HRV is stored and shown in the app and
    /// NOT written to Apple Health in v1. This constant is the whole switch.
    public static let writesHRV = false

    /// The stored kinds a strap's timeline mirrors to Apple Health through the ring's store → Health
    /// path: heart rate, SpO₂ and respiratory rate (decision 17) and the gated skin temperature
    /// (decision 12). Resting HR, steps and energy go through the ring's own daily and cumulative
    /// writers (decisions 16–17); stress and PAI have no Health type and stay in the app (decision 15).
    public static func healthMirroredKinds(writesHRV: Bool = writesHRV) -> [MetricKind] {
        var kinds: [MetricKind] = [.heartRate, .spo2, .respiratoryRate, .temperature]
        if writesHRV { kinds.append(.hrvSDNN) }
        return kinds
    }

    /// Decision 12: a skin temperature outside this band is dropped, never stored or written (°C).
    public static let skinTemperatureRange: ClosedRange<Double> = 30...42
}

// MARK: - Mapping into the store (decision 10)

extension ZeppMetricMapping {

    /// Samples for the LOCAL store from one parsed round: `samples(from:)` (the Apple-Health-clean
    /// mapping) plus the strap's HRV as `.hrvSDNN`, which is stored and shown in the app but kept out
    /// of Apple Health by `HelioHealthPolicy.writesHRV` (decision 14). An HRV of 0 ms is no reading.
    /// The strap's all-day stress becomes `.stress` (`stressSamples`), which has no Health type at all.
    ///
    /// Steps and skin temperature are NOT here: steps go to the step ledger as additive per-minute
    /// deltas (decision 16) and temperature only through `HelioSkinTemperatureGate` (decision 12).
    public static func storedSamples(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        if case .hrv(let readings) = parsed.records {
            return readings.compactMap { reading in
                reading.milliseconds > 0
                    ? QuantitySample(kind: .hrvSDNN, start: reading.time, value: Double(reading.milliseconds))
                    : nil
            }
        }
        if case .autoStress = parsed.records { return stressSamples(from: parsed) }
        return samples(from: parsed).filter { $0.kind != .steps && $0.kind != .temperature }
    }

    /// The all-day stress minutes of an `.autoStress` round as `.stress` samples (0–100), one per
    /// minute at the minute's own time (#239). A byte above 100 is the strap's "no reading" (`ff`,
    /// ZEPP_PROTOCOL.md §6.5 `0x13`) and is skipped, never stored as a value. Empty for any other type.
    ///
    /// In the app only (decision 15): `.stress` is in no Health-mirrored kind list and
    /// `HealthKitWriter.quantityType(for: .stress)` is nil.
    public static func stressSamples(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        guard case .autoStress(let minutes) = parsed.records else { return [] }
        return minutes.compactMap { minute in
            minute.rawLevel <= 100 ? QuantitySample(kind: .stress, start: minute.time, value: Double(minute.rawLevel)) : nil
        }
    }

    /// The per-minute step counts of an activity round, each spanning its own minute (decision 16:
    /// additive deltas over their real interval). Minutes with no steps are omitted.
    public static func stepMinutes(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        samples(from: parsed).filter { $0.kind == .steps }
    }
}

// MARK: - Skin temperature gate (decision 12)

/// Which of the strap's per-minute skin temperatures may be stored and written to Apple Health.
///
/// The review of #219 (U1) found that ungated per-minute `0x2e` values can be ambient or charger
/// temperature. A minute is kept only when ALL of these hold:
/// 1. it has a reading in 30–42 °C (`HelioHealthPolicy.skinTemperatureRange`);
/// 2. the strap's activity record for the SAME minute is known and marks it worn: not `0x73`
///    (not worn) and not `0x76` (charging), ZEPP_PROTOCOL.md §6.5. A minute whose activity record we
///    don't hold is dropped: unknown wear is not evidence of wear;
/// 3. it lies inside one of the strap's own sleep windows (the ring's #29/#41 nightly semantics).
public enum HelioSkinTemperatureGate {

    public enum Exclusion: Equatable {
        /// No reading, or outside 30–42 °C.
        case noReadingInRange
        /// No activity record for the minute.
        case wearUnknown
        case notWorn
        case charging
        case outsideSleepWindow
    }

    /// Whole minutes since 1970, the join key between two per-minute types.
    public static func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// nil when the minute is kept, else why it isn't.
    public static func exclusion(for minute: ZeppTemperatureMinute, activityKind: UInt8?,
                                 sleepWindows: [DateInterval]) -> Exclusion? {
        guard let celsius = minute.celsius, HelioHealthPolicy.skinTemperatureRange.contains(celsius) else {
            return .noReadingInRange
        }
        guard let kind = activityKind else { return .wearUnknown }
        if kind == ZeppActivityMinute.kindNotWorn { return .notWorn }
        if kind == ZeppActivityMinute.kindCharging { return .charging }
        // Half-open: a reading taken at the window's end minute is already outside it.
        guard sleepWindows.contains(where: { $0.start <= minute.time && minute.time < $0.end }) else {
            return .outsideSleepWindow
        }
        return nil
    }

    /// The earliest minute with a reading in range whose activity record isn't in `activity`: it may
    /// still pass once that record arrives (`HelioFetchPlan.temperatureCursor` waits for it).
    public static func earliestWearUnknown(temperatures: [ZeppTemperatureMinute],
                                           activity: [ZeppActivityMinute]) -> Date? {
        let known = Set(activity.map { minuteKey($0.time) })
        return temperatures
            .filter { exclusion(for: $0, activityKind: known.contains(minuteKey($0.time)) ? 0x01 : nil,
                                sleepWindows: [DateInterval(start: .distantPast, end: .distantFuture)]) == .wearUnknown }
            .map(\.time).min()
    }

    /// The kept minutes as `.temperature` samples, oldest first.
    public static func samples(temperatures: [ZeppTemperatureMinute], activity: [ZeppActivityMinute],
                               sleepWindows: [DateInterval]) -> [QuantitySample] {
        var kindByMinute: [Int: UInt8] = [:]
        for minute in activity { kindByMinute[minuteKey(minute.time)] = minute.kind }
        return temperatures
            .filter { exclusion(for: $0, activityKind: kindByMinute[minuteKey($0.time)], sleepWindows: sleepWindows) == nil }
            .sorted { $0.time < $1.time }
            .compactMap { minute in minute.celsius.map { QuantitySample(kind: .temperature, start: minute.time, value: $0) } }
    }
}

// MARK: - Sleep-stage selection (decision 13)

/// Which sleep staging reaches the store and Apple Health for the strap.
///
/// Decision 13 is: the strap's own staging when it has a night; otherwise OpenCircuit's
/// `SleepStaging` on the strap's per-minute HR and motion; never overwrite a manually edited night.
///
/// DECISION-GAP: the `SleepStaging` fallback is not implemented. `SleepStaging.classify` only
/// accepts RingConn `0x4c` wire records (`BulkRecord`): 150 s epochs whose motion channel and
/// thresholds are calibrated to the ring's accelerometer counts. Feeding it the strap would mean
/// synthesising ring records and inventing an intensity → ring-motion calibration that no capture
/// supports, which decision 25 forbids ("never invent a number"). The most conservative
/// alternative is used instead: a night the strap did not stage is not staged, stored or written,
/// and the app says so. `nights(from:now:)` is the single place a fallback would plug in.
public enum HelioSleepSelection {

    /// One night the strap staged.
    public struct Night: Equatable {
        /// Stage segments, oldest first, never overlapping. No `.inBed` segment: the strap's record
        /// has no separate in-bed span (ZEPP_PROTOCOL.md §6.6 🔴), so none is invented.
        public let segments: [SleepSegment]
        /// First segment start … last segment end.
        public let window: DateInterval
        /// The strap's own sleep score, kept for display. Not OpenCircuit's composite score.
        public let strapScore: UInt8
        /// The time zone the night was recorded in, from the strap's local-midnight reference
        /// (`ZeppSleepSession.midnightReference`). nil when unknown; then the phone's zone is used.
        public let recordedTimeZone: TimeZone?

        public init(segments: [SleepSegment], window: DateInterval, strapScore: UInt8,
                    recordedTimeZone: TimeZone? = nil) {
            self.segments = segments
            self.window = window
            self.strapScore = strapScore
            self.recordedTimeZone = recordedTimeZone
        }

        /// The calendar to judge this night in (decision 28e, review-224d S-2): the phone's calendar
        /// in the zone the night was RECORDED in, never the zone the phone is in at sync time.
        public var recordedCalendar: Calendar {
            var calendar = Calendar.current
            if let recordedTimeZone { calendar.timeZone = recordedTimeZone }
            return calendar
        }
    }

    /// The fixed-offset zone whose local midnight is `midnight` (the strap's own reference).
    ///
    /// SPEC-GAP: §6.6 gives only the instant, not the offset. An offset is read off the instant's
    /// time of day, normalised to (−12 h, +12 h]; a zone at +13/+14 h reads as −11/−10 h, which only
    /// matters for a night judged near the 09:00/21:00 gate edges there.
    public static func recordedTimeZone(midnight: Date) -> TimeZone? {
        let seconds = Int(midnight.timeIntervalSince1970.rounded())
        var utcTimeOfDay = seconds % 86_400
        if utcTimeOfDay < 0 { utcTimeOfDay += 86_400 }
        var offset = -utcTimeOfDay
        if offset <= -12 * 3600 { offset += 86_400 }
        return TimeZone(secondsFromGMT: offset)
    }

    /// A staged night longer than this is not plausible for one sleep and is dropped (it is what a
    /// wrong minute base, §6.6 🔴, would produce).
    public static let maxNightLength: TimeInterval = 20 * 3600

    /// Stage bytes (§6.6): `04` light → core, `05` deep, `07` awake, `08` REM.
    ///
    /// SPEC-GAP: any other stage byte is "generic sleep" (§6.6). OpenCircuit's `SleepStage` has no
    /// unspecified-sleep case, so it maps to `.asleepCore`, the stage OpenCircuit's own staging gives
    /// "asleep, nothing more specific". It is counted as sleep either way; only the label is a choice.
    public static func stage(for kind: ZeppSleepSession.StageKind) -> SleepStage {
        switch kind {
        case .light: return .asleepCore
        case .deep: return .asleepDeep
        case .awake: return .awake
        case .rem: return .asleepREM
        case .other: return .asleepCore
        }
    }

    /// The night one sleep-session record describes, or nil when it has no usable staging.
    ///
    /// Each stage's own start and end are used (§6.6: "use both and flag gaps"): a gap between
    /// stages stays a gap, never filled in. A stage that starts before the previous one ends is
    /// trimmed to start where the previous ended, so no two segments overlap. nil when nothing
    /// survives, when the night is longer than `maxNightLength`, or when it ends in the future.
    public static func night(from session: ZeppSleepSession, now: Date) -> Night? {
        var segments: [SleepSegment] = []
        var previousEnd = Date.distantPast
        for stage in session.stages.sorted(by: { $0.start < $1.start }) {
            let start = max(stage.start, previousEnd)
            guard stage.end > start else { continue }
            segments.append(SleepSegment(start: start, end: stage.end, stage: Self.stage(for: stage.kind)))
            previousEnd = stage.end
        }
        guard let first = segments.first?.start, let last = segments.last?.end, last > first else { return nil }
        let window = DateInterval(start: first, end: last)
        guard window.duration <= maxNightLength, last <= now.addingTimeInterval(3600) else { return nil }
        guard segments.contains(where: { $0.stage != .awake }) else { return nil }
        return Night(segments: segments, window: window, strapScore: session.score,
                     recordedTimeZone: recordedTimeZone(midnight: session.midnightReference))
    }

    /// Decision 28f (review-224d S-3): consecutive sessions this far apart or closer are one night.
    /// Amazfit's own rule: sleep more than 60 min from the main sleep is recorded as a nap.
    public static let stitchGap: TimeInterval = 60 * 60

    /// Every staged night in `sessions`, oldest first: each session's night (`night(from:now:)`), then
    /// `stitch`.
    public static func nights(from sessions: [ZeppSleepSession], now: Date) -> [Night] {
        stitch(sessions.compactMap { night(from: $0, now: now) })
    }

    /// The single stitching rule (decision 28f), for anything that turns strap sleeps into nights or
    /// naps: oldest first; a sleep whose window overlaps an earlier one is dropped (the strap
    /// re-delivers sessions on an overlapping fetch); sleeps `stitchGap` or less apart become ONE
    /// (their segments stay exactly as reported, and the gap between them stays a gap: no segment is
    /// invented for it), unless the result would exceed `maxNightLength`.
    public static func stitch(_ sleeps: [Night]) -> [Night] {
        var out: [Night] = []
        for night in sleeps.sorted(by: { $0.window.start < $1.window.start }) {
            if let last = out.last, last.window.end > night.window.start { continue }
            if let last = out.last,
               night.window.start.timeIntervalSince(last.window.end) <= stitchGap,
               night.window.end.timeIntervalSince(last.window.start) <= maxNightLength {
                out[out.count - 1] = stitched(last, night)
                continue
            }
            out.append(night)
        }
        return out
    }

    /// Two sessions as one night: both segment lists as reported, the window spanning both, the
    /// longer session's score and the first's recorded zone.
    static func stitched(_ first: Night, _ second: Night) -> Night {
        Night(segments: first.segments + second.segments,
              window: DateInterval(start: first.window.start, end: second.window.end),
              strapScore: second.window.duration > first.window.duration ? second.strapScore : first.strapScore,
              recordedTimeZone: first.recordedTimeZone ?? second.recordedTimeZone)
    }

    /// The nights that may be stored or written: decision 13's "never overwrite a manually edited
    /// night". A night whose window overlaps a manually edited window is left to the person's edit.
    public static func nightsToWrite(_ nights: [Night], manuallyEdited: [DateInterval]) -> [Night] {
        nights.filter { night in
            !manuallyEdited.contains { edited in
                edited.start < night.window.end && night.window.start < edited.end
            }
        }
    }
}

// MARK: - Fetch plan and watermarks

/// Where each history type's next fetch starts. One watermark per type (§6.4), persisted per strap
/// as a `StoredCursor` row named `cursorName(for:)` under the strap's timeline (`SyncCursorKey`).
public enum HelioFetchPlan {

    /// The types the app fetches, in this order. Activity and sleep sessions come before
    /// temperature so the skin-temperature gate has their minutes when the temperature rounds
    /// arrive. Not fetched: max HR (no Health type, §6.5), manual HR and manual stress (only ever
    /// empty on the Helio, §10.1), sleep SpO₂ (its layout is 🔴, §6.5) and workouts (out of scope).
    public static let types: [ZeppFetchType] = [
        .activity, .sleepSession, .temperature, .spo2, .sleepRespiratoryRate,
        .restingHeartRate, .hrv, .autoStress, .pai,
    ]

    /// How far back a type's first-ever fetch reaches.
    ///
    /// SPEC-GAP: §6.4 only records that Gadgetbridge starts 100 days back. The strap keeps everything
    /// (the app always acks `03 09`, decision 8), so nothing is lost by starting nearer: a week gives
    /// last night and the week's trends on the first sync without a long first transfer, and without
    /// re-importing months of data Zepp may already have written to Apple Health.
    public static let firstSyncLookback: TimeInterval = 7 * 86_400

    /// No fetch reaches further back than this, however old a watermark is: the store keeps 30 days
    /// of raw samples (`LocalStore.sampleRetentionDays`).
    public static let maxLookback: TimeInterval = 30 * 86_400

    /// A watermark this far ahead of the phone's clock is treated as unknown (a clock that moved
    /// back, or a strap clock that ran ahead before the time was set), rather than stalling the type.
    public static let futureTolerance: TimeInterval = 5 * 60

    /// Sleep sessions are re-fetched from this far before the temperature watermark, so every
    /// temperature minute still to be gated has its night's session in the same sync.
    public static let sleepSessionOverlap: TimeInterval = 24 * 3600

    private static let cursorPrefix = "zepp.fetch."

    /// The cursor name for a type (`zepp.fetch.2e`). Not a `MetricKind`, so no store reader mistakes
    /// it for a sample watermark.
    public static func cursorName(for type: ZeppFetchType) -> String {
        cursorPrefix + String(format: "%02x", type.rawValue)
    }

    /// The type a cursor name belongs to; nil for any other name.
    public static func type(forCursorName name: String) -> ZeppFetchType? {
        guard name.hasPrefix(cursorPrefix), let raw = UInt8(name.dropFirst(cursorPrefix.count), radix: 16) else {
            return nil
        }
        return ZeppFetchType(rawValue: raw)
    }

    /// `date` rounded down to the whole minute: the fetch *since* has minute precision (§6.2).
    public static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// The fetch plan: each type with the *since* of its first round.
    ///
    /// - A type with no watermark, or one more than `futureTolerance` ahead of `now`, starts
    ///   `firstSyncLookback` back. No type starts more than `maxLookback` back.
    /// - Activity starts at the earlier of its own and temperature's watermark, and sleep sessions
    ///   at the earlier of their own and temperature's minus `sleepSessionOverlap`: the temperature
    ///   gate needs each minute's wear state and night. Re-delivered minutes are deduplicated by the
    ///   store's per-kind cursors.
    /// - `notBefore` (decision 28: the strap's CURRENT ownership start) bounds every type's start,
    ///   including those two re-fetch windows: the strap never fetches time the ring owned.
    public static func plan(cursors: [ZeppFetchType: Date], now: Date,
                            notBefore: Date? = nil) -> [(type: ZeppFetchType, since: Date)] {
        let first = floorToMinute(now.addingTimeInterval(-firstSyncLookback))
        let oldest = floorToMinute(now.addingTimeInterval(-maxLookback))
        let latest = floorToMinute(now)
        let bound = notBefore.map { min(floorToMinute($0), latest) }
        func resolved(_ type: ZeppFetchType) -> Date {
            guard let cursor = cursors[type], cursor <= now.addingTimeInterval(futureTolerance) else { return first }
            return min(max(floorToMinute(cursor), oldest), latest)
        }
        var since: [ZeppFetchType: Date] = [:]
        for type in types { since[type] = resolved(type) }
        let temperature = resolved(.temperature)
        since[.activity] = min(resolved(.activity), temperature)
        since[.sleepSession] = max(oldest, min(resolved(.sleepSession),
                                               temperature.addingTimeInterval(-sleepSessionOverlap)))
        return types.map { type in
            let start = since[type] ?? first
            return (type, bound.map { max(start, $0) } ?? start)
        }
    }

    /// The watermark to persist once `round` is durably stored: the round's next *since* (last
    /// record + 1 minute), never later than `now` and never behind `previous`. `previous` when the
    /// round had no records.
    public static func advancedCursor(previous: Date?, round: ZeppFetchRound, now: Date) -> Date? {
        guard let next = round.nextSince else { return previous }
        let clamped = min(next, floorToMinute(now))
        guard let previous else { return clamped }
        return max(previous, clamped)
    }

    // MARK: Stress backfill (#239)

    /// How far back a stress backfill reaches at most. Build 59 fetched the all-day stress (`0x13`)
    /// on every sync but kept only its latest value, while the type's watermark advanced, so no stress
    /// history was stored; build 60 does the same. Rewinding that watermark refetches the hole.
    ///
    /// SPEC-GAP: how much stress history the strap itself still holds is not documented (§6.4 says
    /// nothing about retention). The app always acked `03 09` (keep on strap, decision 8), so nothing
    /// was released; if the strap has rotated older minutes out, those rounds just come back short.
    public static let stressBackfillLookback: TimeInterval = 7 * 86_400

    /// The stress watermark a backfill rewinds to, or nil when no backfill is due.
    ///
    /// **The test is exact: "did another build advance the stress watermark?"** (review-242b SF-1).
    /// `ledger` is the watermark as THIS code last left it, written in the same save as every advance
    /// or rewind this code makes (`LocalStore.helioStressLedger`). So:
    ///
    /// - `watermark > ledger` can only mean a build that fetches `0x13` and drops it moved the
    ///   watermark on. The hole is exactly `[ledger, watermark]`, and it is refetched.
    /// - `watermark == ledger` is every ordinary case — a wear gap, charging, stress monitoring off
    ///   (#240), a strap that rotated minutes out — because this code advanced the watermark itself
    ///   and recorded that it did. **Never due.** The previous gap heuristic could not tell those
    ///   apart from a rollback: `ff` minutes advance the watermark but store no row, so an hour off
    ///   the wrist re-armed a 7-day refetch whose minutes the strictly-forward `.stress` ingest cursor
    ///   then dropped — pure cost, roughly once per gap.
    /// - No `ledger` yet, but a watermark exists: the first run of this code on a timeline that an
    ///   older build already advanced. That is the original build-59/60 upgrade, and it gets the
    ///   7-day backfill.
    /// - No watermark at all: nil. The type's first fetch already reaches `firstSyncLookback` back.
    ///
    /// The rewind is `max(ledger, watermark − stressBackfillLookback, notBefore)` — never past the
    /// ledger (everything before it is already stored), never more than a week, and never before
    /// `notBefore` (decision 28: the strap's current ownership start, rounded UP to its minute, so the
    /// target never lies even seconds inside the ring's time). nil when that leaves nothing to move.
    ///
    /// `plan(cursors:now:notBefore:)` bounds every type's start by `notBefore` again, so even a
    /// watermark written before any of this existed cannot reach time the ring owned.
    public static func stressBackfillCursor(watermark: Date?, ledger: Date?, notBefore: Date?) -> Date? {
        guard let watermark else { return nil }
        // Due only when another build moved the watermark past where this code left it.
        if let ledger, watermark <= ledger { return nil }
        var target = floorToMinute(watermark.addingTimeInterval(-stressBackfillLookback))
        if let ledger { target = max(target, ledger) }
        if let notBefore {
            target = max(target, Date(timeIntervalSince1970: (notBefore.timeIntervalSince1970 / 60).rounded(.up) * 60))
        }
        return target < watermark ? target : nil
    }

    /// How far back a temperature minute may still be waiting for its night: a night's session is
    /// written when the strap sees the wake, so a sync during (or just after) the night comes before it.
    public static let temperatureSettleWindow: TimeInterval = 36 * 3600

    /// The temperature watermark after a round, held back so no minute that may still pass the gate
    /// (decision 12) is skipped for good. `proposed` is `advancedCursor`'s value.
    ///
    /// A minute excluded only because its night isn't recorded yet, or its activity record wasn't
    /// fetched, becomes gateable later, but nothing re-fetches temperature behind its own watermark.
    /// So the watermark never passes:
    /// - the earliest minute of this round excluded as `wearUnknown`;
    /// - the end of the latest night known this sync, or `now − temperatureSettleWindow` if that is
    ///   later (a night can only arrive for minutes after the last known one; older minutes are final).
    /// It never moves behind `previous`. The cost is re-fetching up to a day and a half of
    /// temperature and activity per sync; the store's cursors deduplicate them.
    public static func temperatureCursor(proposed: Date?, previous: Date?, earliestWearUnknown: Date?,
                                         latestNightEnd: Date?, now: Date) -> Date? {
        guard let proposed else { return previous }
        var limit = max(latestNightEnd ?? .distantPast, floorToMinute(now.addingTimeInterval(-temperatureSettleWindow)))
        if let wearUnknown = earliestWearUnknown { limit = min(limit, floorToMinute(wearUnknown)) }
        let held = min(proposed, limit)
        guard let previous else { return held }
        return max(previous, held)
    }
}
