import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// A strap workout's heart rate in `LocalStore` (#227). Rows on the strap's own timeline
// (`zeppos:<id>`, decision 10), inside time the strap owns (decision 28), so the Activity-minutes goal,
// Trends and exports see the workout exactly as they see the ring's (#121). No schema change.
//
// Inserted WITHOUT `ingest` and without touching any watermark: see `StrapWorkoutHRLanding` for why
// (the strap's own history, synced later, must not be dropped behind a workout's readings).

/// Where a strap workout's readings go once they may land.
@MainActor
protocol StrapWorkoutHRStore {
    /// The strap's activity fetch watermark: its history (with per-minute heart rate) is stored up to here.
    func activityCoveredThrough(timeline: SyncDeviceID) -> Date?
    /// Store readings as heart-rate rows on `timeline`. Rows already present (same start) are skipped.
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws
}

extension LocalStore: StrapWorkoutHRStore {
    func activityCoveredThrough(timeline: SyncDeviceID) -> Date? {
        helioFetchCursors(device: timeline)[.activity]
    }

    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {
        let log = Self.ownershipLog()
        let owned = samples
            .filter { LiveHR.validBPM.contains($0.bpm) && log.owns(timeline, at: $0.start) }
            .sorted { $0.start < $1.start }
        guard let first = owned.first?.start, let last = owned.last?.start else { return }
        let kindRaw = MetricKind.heartRate.rawValue
        let deviceID = timeline.rawValue
        let descriptor = FetchDescriptor<StoredSample>(predicate: #Predicate {
            $0.kindRaw == kindRaw && $0.deviceID == deviceID && $0.start >= first && $0.start <= last
        })
        var present = Set(try context.fetch(descriptor).map(\.start))
        for sample in owned where present.insert(sample.start).inserted {
            context.insert(StoredSample(QuantitySample(kind: .heartRate, start: sample.start, end: sample.end,
                                                       value: Double(sample.bpm)), device: timeline))
        }
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
