import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// A strap workout's heart rate in `LocalStore` (#227). Rows on the strap's own timeline
// (`zeppos:<id>`, decision 10), inside time the strap owns (decision 28), so the Activity-minutes goal,
// Trends and exports see the workout exactly as they see the ring's (#121). No schema change.
//
// Two watermarks must never move for these rows:
//   • the timeline's INGEST watermark: `LocalStore.ingest` keeps only samples newer than it, so readings
//     ingested through it would drop the strap's own history from before the workout that hasn't synced
//     yet. The rows are inserted directly instead (deduplicated by start);
//   • its HEALTH watermark (`hk:`): the readings are already in Apple Health inside the workout's
//     HKWorkout, so they must not be offered again, but jumping the watermark to the workout's last
//     reading would skip strap rows from before it that a skipped flush left pending (the shape of
//     #241). So the workout's span is recorded (`StrapWorkoutHealthExclusions`) and
//     `pendingHealthSamples` leaves its readings out, and only them.

/// Where a strap workout's readings go.
@MainActor
protocol StrapWorkoutHRStore {
    /// Store readings as heart-rate rows on `timeline`, already in Health through their HKWorkout.
    /// Rows already present (same start) are skipped.
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws
}

extension LocalStore: StrapWorkoutHRStore {
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {
        guard let span = workoutHeartRateSpan(samples, timeline: timeline) else { return }
        // Recorded before the rows exist, so no flush can ever see them without it.
        WorkoutHealthExclusions().add(span, device: timeline)
        try insertWorkoutHeartRateRows(samples, timeline: timeline)
    }
}

// MARK: - The two halves, so the ring can use them too (#241, decision 46)
//
// The ring's End path writes the same shape, but in small chunks with a runloop turn between saves
// (the `0x8BADF00D` watchdog fix, `WorkoutSessionManager`). One exclusion span for the whole
// workout has to be recorded BEFORE the first chunk lands, so the two steps are separable here.
// `insertWorkoutHeartRate` above composes them exactly as #227 always did.

extension LocalStore {
    /// The readings of `samples` this store would keep on `timeline`: a plausible bpm, a real span
    /// (`end > start`, what marks a workout reading apart from a history instant) and inside time
    /// `timeline` owns (decision 28). Sorted by start.
    private func storableWorkoutReadings(_ samples: [HRSample], timeline: SyncDeviceID) -> [HRSample] {
        let log = Self.ownershipLog()
        return samples
            .filter { LiveHR.validBPM.contains($0.bpm) && $0.end > $0.start && log.owns(timeline, at: $0.start) }
            .sorted { $0.start < $1.start }
    }

    /// The span `samples` would occupy on `timeline`, or nil when none of them is storable.
    /// This is the Health exclusion to record before any row exists.
    func workoutHeartRateSpan(_ samples: [HRSample], timeline: SyncDeviceID) -> DateInterval? {
        let owned = storableWorkoutReadings(samples, timeline: timeline)
        guard let first = owned.first?.start, let lastEnd = owned.map(\.end).max() else { return nil }
        return DateInterval(start: first, end: lastEnd)
    }

    /// Insert workout readings as heart-rate rows on `timeline`, deduplicated by `start`, WITHOUT
    /// moving any watermark. Returns how many rows were inserted (0 on a replay).
    @discardableResult
    func insertWorkoutHeartRateRows(_ samples: [HRSample], timeline: SyncDeviceID) throws -> Int {
        let owned = storableWorkoutReadings(samples, timeline: timeline)
        guard let first = owned.first?.start, let last = owned.last?.start else { return 0 }
        let kindRaw = MetricKind.heartRate.rawValue
        let deviceID = timeline.rawValue
        let descriptor = FetchDescriptor<StoredSample>(predicate: #Predicate {
            $0.kindRaw == kindRaw && $0.deviceID == deviceID && $0.start >= first && $0.start <= last
        })
        var present = Set(try context.fetch(descriptor).map(\.start))
        var inserted = 0
        for sample in owned where present.insert(sample.start).inserted {
            context.insert(StoredSample(QuantitySample(kind: .heartRate, start: sample.start, end: sample.end,
                                                       value: Double(sample.bpm)), device: timeline))
            inserted += 1
        }
        do { try context.save() } catch { context.rollback(); throw error }
        return inserted
    }
}

/// Per timeline: the spans whose workout readings are in Apple Health through an HKWorkout
/// (review-238 SF1 for the strap; #241 / decision 46 for the ring). UserDefaults, not SwiftData
/// (no schema change).
///
/// What a span leaves out of the Health flush: heart-rate rows that start inside it AND last a moment
/// (`end > start`). Those are the workout's readings — the strap's each span the second before it
/// (`StrapWorkoutSampleLine`), the ring's the two seconds before the lock
/// (`WorkoutSessionManager.collectHRSnapshot`). Every history row either device stores is an INSTANT
/// (`ZeppMetricMapping`; `BulkSleep.samples`, `EpochSyncSession.placeholderQuantitySamples` and the
/// live-reading persist all use `QuantitySample(kind:start:value:)`, whose `end` defaults to `start`),
/// so all-day heart rate inside a workout still reaches Health. A span is dropped once the Health
/// watermark has passed its end: nothing inside it can be pending any more.
struct WorkoutHealthExclusions {
    nonisolated static let keyPrefix = "strapWorkout.inHealthThroughWorkout.v1."
    let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ device: SyncDeviceID) -> String { Self.keyPrefix + device.rawValue }

    func intervals(device: SyncDeviceID) -> [DateInterval] {
        guard let pairs = defaults.array(forKey: key(device)) as? [[Double]] else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2, pair[1] >= pair[0] else { return nil }
            return DateInterval(start: Date(timeIntervalSince1970: pair[0]), end: Date(timeIntervalSince1970: pair[1]))
        }
    }

    /// Record `interval`. Idempotent: re-running a workout's End path (which records the span
    /// before its rows, every time) must not grow this list.
    func add(_ interval: DateInterval, device: SyncDeviceID) {
        let existing = intervals(device: device)
        guard !existing.contains(interval) else { return }
        save(existing + [interval], device: device)
    }

    func clear(device: SyncDeviceID) { defaults.removeObject(forKey: key(device)) }

    /// A timeline that will never be flushed again: the strap was forgotten, or a new identity (a new
    /// `zeppos:<id>`) replaced it. Its spans can no longer be pruned by a flush, so they go now
    /// (review-238b N-1). Nothing else is removed: the rows themselves stay in the store.
    static func retire(timeline: SyncDeviceID, _ defaults: UserDefaults = .standard) {
        WorkoutHealthExclusions(defaults).clear(device: timeline)
    }

    private func save(_ intervals: [DateInterval], device: SyncDeviceID) {
        if intervals.isEmpty { return clear(device: device) }
        defaults.set(intervals.map { [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970] }, forKey: key(device))
    }

    /// `samples` without the workout readings Health already has. Prunes spans the watermark has passed.
    func filter(_ samples: [QuantitySample], device: SyncDeviceID, healthWatermark: Date?) -> [QuantitySample] {
        var spans = intervals(device: device)
        guard !spans.isEmpty else { return samples }
        if let mark = healthWatermark {
            let live = spans.filter { $0.end > mark }
            if live.count != spans.count { save(live, device: device); spans = live }
        }
        return samples.filter { s in
            !(s.kind == .heartRate && s.end > s.start && spans.contains { $0.contains(s.start) })
        }
    }
}

/// #227's name for `WorkoutHealthExclusions`, kept so the strap's own call sites and tests are
/// untouched by the ring reusing the mechanism (#241).
typealias StrapWorkoutHealthExclusions = WorkoutHealthExclusions
