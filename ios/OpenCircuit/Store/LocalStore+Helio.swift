import Foundation
import os
import OpenCircuitKit
import SwiftData
import ZeppKit

// The Helio Strap's rows in `LocalStore` (#215 phase 3). No schema change: the strap writes the
// SchemaV8 tables the ring already uses, under its own timeline (`zeppos:<id>`, decision 10):
//   • samples through `ingest(_:device:)`, deduplicated by the timeline's per-kind cursors;
//   • per-minute steps into `StoredStepSample` / `StoredDaily`, deduplicated by a step cursor;
//   • each history type's fetch watermark as a `StoredCursor` row (`HelioFetchPlan.cursorName`);
//   • nights through `saveSleepSummary`, which already refuses to overwrite a manually edited night.

extension LocalStore {

    /// The step ledger's cursor name. Not a `MetricKind`: steps bypass `ingest`, whose cumulative
    /// counter path would take deltas of the strap's per-minute counts (decision 16: they are deltas).
    static let helioStepCursorName = "zepp.steps"

    // MARK: Cursors

    /// Every fetch watermark stored for `device`, by type.
    func helioFetchCursors(device: SyncDeviceID) -> [ZeppFetchType: Date] {
        var out: [ZeppFetchType: Date] = [:]
        for row in helioCursorRows(device: device) {
            guard let name = SyncCursorKey.name(fromKey: row.kindRaw, device: device),
                  let type = HelioFetchPlan.type(forCursorName: name) else { continue }
            out[type] = row.last
        }
        return out
    }

    /// The last value of one named cursor of `device`, or nil.
    func helioCursor(_ name: String, device: SyncDeviceID) -> Date? {
        let key = SyncCursorKey.key(name, device: device)
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        return (try? context.fetch(descriptor).first)?.last
    }

    /// Upsert a named cursor of `device` (not saved: the caller saves with its rows).
    func stageHelioCursor(_ name: String, to date: Date, device: SyncDeviceID) {
        let key = SyncCursorKey.key(name, device: device)
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.last = date
        } else {
            context.insert(StoredCursor(kindRaw: key, last: date, deviceID: device.rawValue))
        }
    }

    /// Persist one fetch watermark.
    ///
    /// A backfilled type's watermark carries its ledger (`stageHelioCursorWithLedger`, stress `0x13`
    /// and PAI `0x0d`): this is the ONLY place any watermark is written, so routing every type
    /// through here is what makes "the ledger moves in the same save as the watermark" impossible to
    /// forget at a future call site (review-242b SF-1). Any other type stages only its watermark,
    /// exactly as before.
    func setHelioFetchCursor(_ type: ZeppFetchType, to date: Date, device: SyncDeviceID) throws {
        stageHelioCursorWithLedger(type, to: date, device: device)
        do { try context.save() } catch { context.rollback(); throw error }
    }

    private func helioCursorRows(device: SyncDeviceID) -> [StoredCursor] {
        let deviceID = device.rawValue
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.deviceID == deviceID })
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Steps (decision 16)

    /// Store the strap's per-minute step counts newer than `device`'s step cursor, each as its own
    /// `StoredStepSample` over its own minute (so Apple Health gets additive deltas over their real
    /// interval, through the ring's step writer), and add them to the day's `StoredDaily`. Rows and
    /// cursor commit in one save; nothing is kept on failure. Returns the rows added.
    @discardableResult
    func ingestHelioStepMinutes(_ minutes: [QuantitySample], device: SyncDeviceID, now: Date = Date()) throws -> Int {
        let last = helioCursor(Self.helioStepCursorName, device: device) ?? .distantPast
        let ceiling = now.addingTimeInterval(86_400)
        let log = Self.ownershipLog()
        // Decision 28 / 28b, the ring's rule mirrored: a minute counts if `device` owns its last
        // instant, and its row is clamped to that ownership's start, so it lies wholly in the strap's
        // time (the minute a switch lands in goes to the device switched TO).
        func lastInstant(_ minute: QuantitySample) -> Date { max(minute.start, minute.end.addingTimeInterval(-1)) }
        let fresh = minutes
            .filter { $0.kind == .steps && $0.value > 0 && $0.start > last && $0.start <= ceiling }
            .filter { log.owns(device, at: lastInstant($0)) }
            .sorted { $0.start < $1.start }
        guard let newest = fresh.last?.start else { return 0 }
        var dailies: [Date: StoredDaily] = [:]
        for minute in fresh {
            let delta = Int(minute.value)
            let start = max(minute.start, log.ownershipStart(at: lastInstant(minute)))
            let day = Calendar.current.startOfDay(for: start)
            if dailies[day] == nil {
                let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == day })
                if let existing = try context.fetch(descriptor).first {
                    dailies[day] = existing
                } else {
                    let row = StoredDaily(day: day, steps: 0)
                    context.insert(row)
                    dailies[day] = row
                }
            }
            dailies[day]?.steps += delta
            dailies[day]?.updatedAt = now
            context.insert(StoredStepSample(start: start, end: minute.end, delta: delta))
        }
        stageHelioCursor(Self.helioStepCursorName, to: newest, device: device)
        do { try context.save() } catch { context.rollback(); throw error }
        return fresh.count
    }

    // MARK: Nights (decisions 12, 13)

    /// The in-bed windows of nights the person edited by hand (decision 13's "never overwrite").
    func manuallyEditedSleepWindows(from start: Date, to end: Date) -> [DateInterval] {
        let lo = start.addingTimeInterval(-86_400)
        let hi = end.addingTimeInterval(86_400)
        let rows = (try? sleepSummaries(from: lo, to: hi)) ?? []
        return rows.compactMap { row in
            guard row.isManuallyEdited, row.inBedEnd > row.inBedStart else { return nil }
            return DateInterval(start: row.inBedStart, end: row.inBedEnd)
        }
    }

    /// Store one of the strap's staged nights, with its nightly skin temperature judged exactly as
    /// the ring's (`SkinTempBaseline.nightlyVerdict` over the stored, gated readings in the window).
    @discardableResult
    func saveHelioNight(_ night: HelioSleepSelection.Night, device: SyncDeviceID) throws -> SleepPersistOutcome {
        let segments = night.segments
        let window = night.window
        var extras = SleepNightExtras()
        extras.hypnogram = segments
        let temperatures = helioTemperatures(in: window, device: device)
        switch SkinTempBaseline.nightlyVerdict(samples: temperatures, in: window) {
        case .published(let mean): extras.skinTempC = mean
        case .rejectedCoverage: extras.skinTempWithheld = true
        case .notMeasured: break
        }
        let sleep = SleepStaging.sleepWindow(segments)
        return try saveSleepSummary(SleepStaging.summary(segments),
                                    night: SleepNightKey.night(inBedStart: window.start, inBedEnd: window.end),
                                    inBedStart: window.start, inBedEnd: window.end,
                                    sleepOnset: sleep?.onset ?? .distantPast, sleepWake: sleep?.wake ?? .distantPast,
                                    extras: extras, device: device)
    }

    /// The span of the night already mirrored to Apple Health under `night`'s key (`mirrorSettledNight`
    /// records it), if any: the key of the stored summary it overlaps, else the key its window files
    /// under, as the mirror resolves it.
    func writtenNightSpan(for night: HelioSleepSelection.Night) -> DateInterval? {
        let row = try? sleepSummaryOverlapping(start: night.window.start, end: night.window.end)
        let key = row?.night ?? SleepNightKey.night(inBedStart: night.window.start, inBedEnd: night.window.end)
        guard let record = mirroredNight(night: key), record.spanEnd > record.spanStart else { return nil }
        return DateInterval(start: record.spanStart, end: record.spanEnd)
    }

    /// `device`'s stored skin temperatures in `window` (already gated when stored).
    func helioTemperatures(in window: DateInterval, device: SyncDeviceID) -> [TemperatureSample] {
        let kindRaw = MetricKind.temperature.rawValue
        let deviceID = device.rawValue
        let start = window.start
        let end = window.end
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.deviceID == deviceID && $0.start >= start && $0.start < end },
            sortBy: [SortDescriptor(\.start)])
        return ((try? context.fetch(descriptor)) ?? []).map { TemperatureSample(time: $0.start, celsius: $0.value) }
    }
}

// MARK: - The sink

/// `HelioHistorySink` over `LocalStore`: what each fetched round becomes (decisions 10–17).
@MainActor
final class HelioStoreSink: HelioHistorySink {
    private let store: LocalStore

    // Per-sync context: the temperature gate needs this sync's activity minutes and nights.
    private var activity: [ZeppActivityMinute] = []
    private var sessions: [ZeppSleepSession] = []
    private var storedNights: [HelioSleepSelection.Night] = []
    /// Daytime sessions already logged this sync (decision 28c), so a re-run logs each once.
    private var notOvernightLogged: Set<DateInterval> = []
    /// Sleeps kept out of a night already written to Apple Health (28f), logged once per sync.
    private var keptApartLogged: Set<DateInterval> = []
    private var latestStress: HelioReading?
    private var latestPAI: HelioReading?

    /// The strap's link breadcrumbs (`HelioConnection` hands them over); nil in tests.
    private let breadcrumbs: HelioBreadcrumbs?

    init(store: LocalStore, breadcrumbs: HelioBreadcrumbs? = nil) {
        self.store = store
        self.breadcrumbs = breadcrumbs
    }

    func fetchCursors(timeline: SyncDeviceID, now: Date) -> [ZeppFetchType: Date] {
        // Before the plan is built: #239 (stress `0x13`) and decision 45 (PAI `0x0d`). Each is due at
        // most once per hole another build left, and neither can fire for an ordinary quiet stretch.
        //
        // Both take the SYNC's `now`, like `notBefore` and `persist` (review-248 SF-1): PAI's rewind
        // is floored at `now − 30 days` of sample retention, and reading the wall clock for it while
        // the rest of the sync ran on the session clock made that floor disagree with the plan built
        // from it. On a phone the two are the same instant; under an injected clock they are not.
        store.applyHelioStressBackfillIfNeeded(device: timeline, now: now)
        store.applyHelioPAIBackfillIfNeeded(device: timeline, now: now)
        return store.helioFetchCursors(device: timeline)
    }

    /// Decision 28: the strap's current ownership start. If it doesn't own the present (switched
    /// away mid-sync), nothing older than now is fetched.
    func notBefore(timeline: SyncDeviceID, now: Date) -> Date? {
        LocalStore.ownershipLog().currentStart(of: DeviceOwnershipLog.Family(timeline: timeline)) ?? now
    }

    /// Only what the strap recorded for time it owned is stored (decision 28). Nothing is lost:
    /// the acks stay `03 09`, so the strap keeps the rest.
    private func owned(_ samples: [QuantitySample], _ timeline: SyncDeviceID) -> [QuantitySample] {
        let log = LocalStore.ownershipLog()
        return samples.filter { log.owns(timeline, at: $0.start) }
    }

    func beginSync(timeline: SyncDeviceID, now: Date) {
        activity = []
        sessions = []
        storedNights = []
        notOvernightLogged = []
        keptApartLogged = []
        latestStress = nil
        latestPAI = nil
    }

    func persist(_ round: ZeppFetchRound, timeline: SyncDeviceID, now: Date) -> Bool {
        do {
            switch round.parsed.records {
            case .activity(let minutes):
                activity += minutes
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
                try store.ingestHelioStepMinutes(ZeppMetricMapping.stepMinutes(from: round.parsed), device: timeline, now: now)
            case .sleepSession(let records):
                sessions += records
                try storeNights(timeline: timeline, now: now)
            case .temperature(let minutes):
                let windows = ownedNights(timeline: timeline, now: now).map(\.window)
                let gated = HelioSkinTemperatureGate.samples(temperatures: minutes, activity: activity, sleepWindows: windows)
                _ = try store.ingest(owned(gated, timeline), device: timeline)
                // Hold the watermark where a minute may still pass the gate later (no night yet, or
                // no wear record this sync), so it is fetched again instead of skipped for good.
                let previous = store.helioFetchCursors(device: timeline)[.temperature]
                let held = HelioFetchPlan.temperatureCursor(
                    proposed: HelioFetchPlan.advancedCursor(previous: previous, round: round, now: now),
                    previous: previous,
                    earliestWearUnknown: HelioSkinTemperatureGate.earliestWearUnknown(temperatures: minutes, activity: activity),
                    latestNightEnd: windows.map(\.end).max(), now: now)
                if let held, held != previous { try store.setHelioFetchCursor(.temperature, to: held, device: timeline) }
                return true
            case .autoStress(let minutes):
                if let last = minutes.last(where: { $0.level != nil }), let level = last.level {
                    latestStress = HelioReading(value: Double(level), at: last.time)
                }
                // #239: every minute is kept as `.stress` history, in the app only (no Health type).
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
            case .pai(let records):
                if let last = records.last { latestPAI = HelioReading(value: Double(last.totalPAI), at: last.time) }
                // Decision 45: every valid record is kept as one `.pai` row, in the app only (no
                // Health type). The card reads the newest of them, so it survives a sync with no PAI
                // record — `0x0d` arrives about daily — and every relaunch.
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
            default:
                _ = try store.ingest(owned(ZeppMetricMapping.storedSamples(from: round.parsed), timeline), device: timeline)
            }
            let previous = store.helioFetchCursors(device: timeline)[round.type]
            if let next = HelioFetchPlan.advancedCursor(previous: previous, round: round, now: now), next != previous {
                try store.setHelioFetchCursor(round.type, to: next, device: timeline)
            }
            return true
        } catch {
            helioLog.error("helio: storing a \(round.type.displayName, privacy: .public) round failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Store every staged night seen so far this sync that the person hasn't edited.
    /// The strap's own nights in this sync's sessions (review-224e S-1): each session's sleep, kept only
    /// when the strap owns its OWN window (decision 28/28a), and only then 28f's stitch. Stitching first
    /// let a doze from before a ring → strap switch drag the strap's own night into ring time, and then
    /// neither device kept it. Used by `storeNights` and the temperature gate. With an empty log (a
    /// ring-only install) nothing is the strap's, as before.
    private func ownedNights(timeline: SyncDeviceID, now: Date) -> [HelioSleepSelection.Night] {
        let log = LocalStore.ownershipLog()
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        let own = sessions.compactMap { HelioSleepSelection.night(from: $0, now: now) }
            .filter { log.owner(ofNightFrom: $0.window.start, to: $0.window.end) == family }
        return HelioSleepSelection.stitch(own)
    }

    private func storeNights(timeline: SyncDeviceID, now: Date) throws {
        let nights = ownedNights(timeline: timeline, now: now)
        guard let first = nights.first?.window.start, let last = nights.last?.window.end else { return }
        let edited = store.manuallyEditedSleepWindows(from: first, to: last)
        // Decision 28a: a night belongs to the device chosen when it began (saveSleepSummary also refuses
        // one the ring already keeps; only nights stored here reach the Health hand-off).
        let log = LocalStore.ownershipLog()
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        // Decision 28c (review-224c S-1): only an overnight strap sleep is a night. The ring's own gate,
        // with the ring's parameters (`SleepWindow.isOvernightBlock(start:end:)`, local calendar), so a
        // daytime session never takes a night key and can never make the ring's night unkeepable.
        // Decision 28d (review-224d S-1): it must also END in its key's wake window, the store's own rule
        // for "this is the night its key names" (`SleepNightKey.endsInWakeWindow`), so an evening doze
        // the overnight gate accepts (20:00–22:30) never takes a night key either.
        // Decision 28e (review-224d S-2): both judged in the zone the night was RECORDED in (the strap's
        // own local-midnight reference), never the phone's zone at sync time, so a normal night first
        // synced after a flight is still a night. Same functions, one explicit calendar.
        let overnight = nights.filter { night in
            let calendar = night.recordedCalendar
            let isOvernight = SleepWindow.isOvernightBlock(start: night.window.start, end: night.window.end, calendar: calendar)
            let endsInWakeWindow = SleepNightKey.endsInWakeWindow(night.window.end, calendar: calendar)
            if isOvernight, endsInWakeWindow { return true }
            if notOvernightLogged.insert(night.window).inserted {
                let span = Self.clockSpan(night.window, in: night.recordedTimeZone)
                if !isOvernight {
                    helioLog.notice("helio: sleep session \(span, privacy: .public) is not overnight; not stored as a night")
                } else {
                    helioLog.notice("helio: sleep session \(span, privacy: .public) doesn't end in its night's wake window; not stored as a night")
                }
            }
            return false
        }
        // The ownership check again, on the stitched window: a backstop (`ownedNights` already kept
        // only the strap's own sleeps).
        for night in HelioSleepSelection.nightsToWrite(overnight, manuallyEdited: edited)
        where log.owner(ofNightFrom: night.window.start, to: night.window.end) == family
            && !storedNights.contains(where: { $0.window == night.window }) {
            // Decision 28f stitches sessions 60 min or less apart into one night, so a night can grow
            // after it was written to Apple Health (back to bed within the hour, after the Sleep Focus
            // finalization or the settle margin let the first part through). The written night stands:
            // a different night for its key (the stitched one, or another sleep that would replace it)
            // is kept out, so Health gets no second write of the night and nothing written is silently
            // replaced. A night not yet written still stitches. The later session is not stored as a
            // row of its own in v1 (strap naps are 28c's follow-up): an open question for Juan.
            if let written = store.writtenNightSpan(for: night),
               abs(written.start.timeIntervalSince(night.window.start)) > 1 || abs(written.end.timeIntervalSince(night.window.end)) > 1 {
                if keptApartLogged.insert(night.window).inserted {
                    helioLog.notice("helio: sleep \(Self.clockSpan(night.window, in: night.recordedTimeZone), privacy: .public) would change a night already in Apple Health (\(Self.clockSpan(written, in: night.recordedTimeZone), privacy: .public)); the written night stands")
                }
                continue
            }
            let outcome = try store.saveHelioNight(night, device: timeline)
            if outcome == .inserted || outcome == .updated { storedNights.append(night) }
            // Review-224e S-2: a sleep more than 60 min from the night's other part is not stitched
            // (28f), and its key already holds the longer part, so it is stored nowhere until strap naps
            // (#231). Say so in the breadcrumbs, without its time or length.
            if outcome == .keptFullerStoredNight,
               (try? store.sleepSummaryOverlapping(start: night.window.start, end: night.window.end)) == nil {
                breadcrumbs?.strapSleepKeptOut(nightKey: SleepNightKey.night(inBedStart: night.window.start, inBedEnd: night.window.end))
            }
        }
    }

    /// `HH:mm–HH:mm` in the recorded zone, for the 28c log line: when a session ran, no health value.
    private static func clockSpan(_ window: DateInterval, in zone: TimeZone?) -> String {
        let f = DateFormatter()
        if let zone { f.timeZone = zone }
        f.dateFormat = "HH:mm"
        return "\(f.string(from: window.start))–\(f.string(from: window.end))"
    }

    func finishSync(timeline: SyncDeviceID, now: Date) -> HelioSyncResult {
        // Re-save the nights now that their skin temperatures are stored (temperature is fetched
        // after sleep sessions): the same staging, so the summary is updated in place.
        for night in storedNights {
            _ = try? store.saveHelioNight(night, device: timeline)
        }
        var result = HelioSyncResult()
        result.nights = storedNights
        result.todaySteps = try? store.todaySteps(day: now)
        result.latestStress = latestStress
        result.latestPAI = latestPAI
        return result
    }
}
