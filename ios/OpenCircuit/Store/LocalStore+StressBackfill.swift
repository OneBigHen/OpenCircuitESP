import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// The stress backfill (#239). Builds 59 and 60 fetch the strap's all-day stress (`0x13`), keep only
// its latest value and still advance the type's fetch watermark, so the minutes they walked past are
// never stored. This rewinds that watermark once per such hole, so the chart fills in.
//
// The test is EXACT, not a heuristic: "did another build advance the stress watermark?"
// (review-242b SF-1). The LEDGER is the stress watermark as this code last left it, and it is written
// in the same `context.save()` as every advance or rewind this code makes:
//   • a sync's round save, through `setHelioFetchCursor(.autoStress, …)` — the only place any
//     watermark is written, so the pairing cannot be forgotten at a new call site;
//   • this file's rewind.
// A failed save therefore writes neither.
//
// So `watermark > ledger` can only mean a build that drops `0x13` moved it on, and the hole is
// exactly `[ledger, watermark]`. Every ordinary reason the strap reports no stress — a wear gap,
// charging, stress monitoring off (#240), minutes the strap rotated out — leaves `watermark == ledger`
// and is never a backfill. The previous gap heuristic could not tell those apart: `ff` minutes advance
// the watermark but store no row, so an hour off the wrist re-armed a 7-day refetch whose minutes the
// strictly-forward `.stress` ingest cursor then dropped.
//
// No migration: no build on any phone ever wrote the old `zepp.backfill.13` row (59 and 60 predate
// #242), and a timeline with no ledger is exactly the first-run case the rule already handles.
// No schema change either: `StoredCursor` already holds named per-device rows (`zepp.steps`,
// `zepp.fetch.xx`).

extension LocalStore {

    /// The per-timeline ledger row: the stress fetch watermark as this code last left it. Deliberately
    /// NOT a `zepp.fetch.` name, so `helioFetchCursors` can never read it as a watermark, and not a
    /// `MetricKind`, so no sample reader mistakes it for one.
    static let helioStressLedgerName = "zepp.ledger.13"

    /// The stress watermark as this code last left it on `device`, or nil if it never wrote one.
    func helioStressLedger(device: SyncDeviceID) -> Date? {
        helioCursor(Self.helioStressLedgerName, device: device)
    }

    /// Stage the stress watermark and its ledger together, for the caller's save. Always both: the
    /// ledger means "this code put the watermark here", so it is only ever true if they move as one.
    func stageHelioStressCursor(to date: Date, device: SyncDeviceID) {
        stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: date, device: device)
        stageHelioCursor(Self.helioStressLedgerName, to: date, device: device)
    }

    /// Rewind the stress watermark if another build advanced it (`HelioFetchPlan.stressBackfillCursor`),
    /// never before the strap's current ownership start (decision 28). Returns the watermark it moved
    /// to, or nil when no backfill was due.
    ///
    /// Nothing is staged or recorded while the strap doesn't own the present (switched away): the sink
    /// then fetches nothing older than now anyway, and the backfill waits for a sync it owns.
    @discardableResult
    func applyHelioStressBackfillIfNeeded(device: SyncDeviceID) -> Date? {
        guard let ownedSince = Self.ownershipLog().currentStart(of: DeviceOwnershipLog.Family(timeline: device)) else {
            return nil
        }
        guard let target = HelioFetchPlan.stressBackfillCursor(
            watermark: helioFetchCursors(device: device)[.autoStress],
            ledger: helioStressLedger(device: device),
            notBefore: ownedSince) else { return nil }
        // The rewind is itself this code moving the watermark, so it carries the ledger with it — in
        // one save, rolled back together on failure. The next sync then sees watermark == ledger and
        // is not due, even if this sync is interrupted before the refetched rounds land.
        stageHelioStressCursor(to: target, device: device)
        do {
            try context.save()
        } catch {
            context.rollback()
            return nil
        }
        return target
    }
}
