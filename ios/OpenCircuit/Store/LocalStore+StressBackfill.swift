import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// The stress backfill (#239). Build 59 fetched the strap's all-day stress (`0x13`) on every sync but
// kept only its latest value, while the type's fetch watermark advanced. Now that every minute is
// stored as `.stress`, a sync that finds a HOLE — the watermark well ahead of the newest stored
// `.stress` row — moves ONLY that watermark back a week (`HelioFetchPlan.stressBackfillCursor`), so
// the chart fills in instead of staying empty. The acks are untouched (`03 09`, decision 8): the
// strap kept the data.
//
// A CONDITION, not a one-shot flag (review-242 NIT 1). Build 60 still fetches `0x13`, drops it and
// advances the watermark, so 61 → 60 → 61 leaves exactly such a hole; a one-shot flag would have left
// those days blank forever. `HelioFetchPlan.stressBackfillIsDue` carries the rule, including what
// stops it looping: every attempt records the watermark it tried to fill up to, and a new attempt
// needs rows stored PAST that ceiling. A hole the strap can no longer serve is therefore attempted
// once and never again.
//
// The attempt record is a `StoredCursor` row under the strap's timeline, saved in the SAME save as the
// moved watermark, so the two can never disagree: either both landed or neither did. No schema change:
// `StoredCursor` already holds named per-device rows (`zepp.steps`, `zepp.fetch.xx`).

extension LocalStore {

    /// The per-strap attempt record: the stress watermark the last backfill tried to fill up to. Not a
    /// `zepp.fetch.` name, so `helioFetchCursors` never reads it as a fetch watermark, and not a
    /// `MetricKind`, so no sample reader mistakes it for one.
    static let helioStressBackfillDoneName = "zepp.backfill.13"

    /// The watermark the last backfill for `device` attempted to fill up to, or nil if it never ran.
    func helioStressBackfillAttemptedThrough(device: SyncDeviceID) -> Date? {
        helioCursor(Self.helioStressBackfillDoneName, device: device)
    }

    /// Whether a backfill has ever run for `device`.
    func helioStressBackfillDone(device: SyncDeviceID) -> Bool {
        helioStressBackfillAttemptedThrough(device: device) != nil
    }

    /// The newest stored `.stress` row for `device`, or nil. One row, index-ordered: this runs on the
    /// sync path, so it must never become a scan.
    func newestStoredStress(device: SyncDeviceID) -> Date? {
        let kindRaw = MetricKind.stress.rawValue
        let deviceID = device.rawValue
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.deviceID == deviceID },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.start
    }

    /// Run a stress backfill for `device` if one is due (`HelioFetchPlan.stressBackfillIsDue`): move the
    /// stress watermark back (never before the strap's current ownership start, decision 28) and record
    /// the watermark this attempt covered. Returns the watermark it moved to, or nil when nothing moved.
    ///
    /// Not run, and nothing recorded, while the strap doesn't own the present (switched away): the sink
    /// then fetches nothing older than now anyway, and the backfill waits for a sync it owns.
    @discardableResult
    func applyHelioStressBackfillIfNeeded(device: SyncDeviceID, now: Date = Date()) -> Date? {
        guard let ownedSince = Self.ownershipLog().currentStart(of: DeviceOwnershipLog.Family(timeline: device)) else {
            return nil
        }
        let watermark = helioFetchCursors(device: device)[.autoStress]
        guard HelioFetchPlan.stressBackfillIsDue(watermark: watermark,
                                                 newestStoredStress: newestStoredStress(device: device),
                                                 lastAttemptThrough: helioStressBackfillAttemptedThrough(device: device))
        else { return nil }
        let target = HelioFetchPlan.stressBackfillCursor(current: watermark, now: now, notBefore: ownedSince)
        if let target { stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: target, device: device) }
        // The ceiling this attempt covers, so the same hole is never attempted twice. The watermark at
        // this moment, not `now`: it is what "filled up to" means, and it is what the next sync's
        // newest-row check is compared against.
        if let watermark { stageHelioCursor(Self.helioStressBackfillDoneName, to: watermark, device: device) }
        do {
            try context.save()
        } catch {
            context.rollback()
            return nil
        }
        return target
    }
}
