import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// The one-time stress backfill (#239). Build 59 fetched the strap's all-day stress (`0x13`) on every
// sync but kept only its latest value, while the type's fetch watermark advanced. Now that every
// minute is stored as `.stress`, the first sync after the update moves ONLY that watermark back a
// week (`HelioFetchPlan.stressBackfillCursor`), once per strap, so the stress chart starts with the
// last week instead of empty. The acks are untouched (`03 09`, decision 8): the strap kept the data.
//
// The "done" flag is a `StoredCursor` row under the strap's timeline, saved in the SAME save as the
// moved watermark, so the two can never disagree: either both landed or neither did. No schema
// change: `StoredCursor` already holds named per-device rows (`zepp.steps`, `zepp.fetch.xx`).

extension LocalStore {

    /// The per-strap flag row. Not a `zepp.fetch.` name, so `helioFetchCursors` never reads it as a
    /// fetch watermark, and not a `MetricKind`, so no sample reader mistakes it for one.
    static let helioStressBackfillDoneName = "zepp.backfill.13"

    /// Whether the backfill already ran for `device`.
    func helioStressBackfillDone(device: SyncDeviceID) -> Bool {
        helioCursor(Self.helioStressBackfillDoneName, device: device) != nil
    }

    /// Run the backfill for `device` if it hasn't run: move the stress watermark back (never before the
    /// strap's current ownership start, decision 28) and record that it ran. Returns the watermark it
    /// moved to, or nil when nothing moved.
    ///
    /// Not run, and not marked done, while the strap doesn't own the present (switched away): the
    /// sink then fetches nothing older than now anyway, and the backfill waits for a sync it owns.
    @discardableResult
    func applyHelioStressBackfillIfNeeded(device: SyncDeviceID, now: Date = Date()) -> Date? {
        guard !helioStressBackfillDone(device: device),
              let ownedSince = Self.ownershipLog().currentStart(of: DeviceOwnershipLog.Family(timeline: device)) else {
            return nil
        }
        let target = HelioFetchPlan.stressBackfillCursor(current: helioFetchCursors(device: device)[.autoStress],
                                                         done: false, now: now, notBefore: ownedSince)
        if let target { stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: target, device: device) }
        stageHelioCursor(Self.helioStressBackfillDoneName, to: now, device: device)
        do {
            try context.save()
        } catch {
            context.rollback()
            return nil
        }
        return target
    }
}
