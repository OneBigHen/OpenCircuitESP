import Foundation
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
    func setHelioFetchCursor(_ type: ZeppFetchType, to date: Date, device: SyncDeviceID) throws {
        stageHelioCursor(HelioFetchPlan.cursorName(for: type), to: date, device: device)
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
        let fresh = minutes
            .filter { $0.kind == .steps && $0.value > 0 && $0.start > last && $0.start <= ceiling }
            .sorted { $0.start < $1.start }
        guard let newest = fresh.last?.start else { return 0 }
        var dailies: [Date: StoredDaily] = [:]
        for minute in fresh {
            let delta = Int(minute.value)
            let day = Calendar.current.startOfDay(for: minute.start)
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
            context.insert(StoredStepSample(start: minute.start, end: minute.end, delta: delta))
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
                                    extras: extras)
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
    private var latestStress: HelioReading?
    private var latestPAI: HelioReading?

    init(store: LocalStore) {
        self.store = store
    }

    func fetchCursors(timeline: SyncDeviceID) -> [ZeppFetchType: Date] {
        store.helioFetchCursors(device: timeline)
    }

    func beginSync(timeline: SyncDeviceID, now: Date) {
        activity = []
        sessions = []
        storedNights = []
        latestStress = nil
        latestPAI = nil
    }

    func persist(_ round: ZeppFetchRound, timeline: SyncDeviceID, now: Date) -> Bool {
        do {
            switch round.parsed.records {
            case .activity(let minutes):
                activity += minutes
                _ = try store.ingest(ZeppMetricMapping.storedSamples(from: round.parsed), device: timeline)
                try store.ingestHelioStepMinutes(ZeppMetricMapping.stepMinutes(from: round.parsed), device: timeline, now: now)
            case .sleepSession(let records):
                sessions += records
                try storeNights(timeline: timeline, now: now)
            case .temperature(let minutes):
                let windows = HelioSleepSelection.nights(from: sessions, now: now).map(\.window)
                let gated = HelioSkinTemperatureGate.samples(temperatures: minutes, activity: activity, sleepWindows: windows)
                _ = try store.ingest(gated, device: timeline)
            case .autoStress(let minutes):
                if let last = minutes.last(where: { $0.level != nil }), let level = last.level {
                    latestStress = HelioReading(value: Double(level), at: last.time)
                }
            case .pai(let records):
                if let last = records.last { latestPAI = HelioReading(value: Double(last.totalPAI), at: last.time) }
            default:
                _ = try store.ingest(ZeppMetricMapping.storedSamples(from: round.parsed), device: timeline)
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
    private func storeNights(timeline: SyncDeviceID, now: Date) throws {
        let nights = HelioSleepSelection.nights(from: sessions, now: now)
        guard let first = nights.first?.window.start, let last = nights.last?.window.end else { return }
        let edited = store.manuallyEditedSleepWindows(from: first, to: last)
        for night in HelioSleepSelection.nightsToWrite(nights, manuallyEdited: edited)
        where !storedNights.contains(where: { $0.window == night.window }) {
            let outcome = try store.saveHelioNight(night, device: timeline)
            if outcome == .inserted || outcome == .updated { storedNights.append(night) }
        }
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
