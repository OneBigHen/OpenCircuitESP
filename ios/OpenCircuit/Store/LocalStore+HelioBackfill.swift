import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

// The one-time fetch-watermark backfills: stress `0x13` (#239) and PAI `0x0d` (decision 45).
//
// Both have the same shape. An older build fetched the type on every sync, kept only its latest
// value for the strap card and still advanced the type's fetch watermark, so everything it walked
// past was never stored — stress on builds 59–60, PAI on builds 59–62. Rewinding that watermark once
// per such hole refetches it (the acks were always `03 09`, decision 8, so the strap still has it).
//
// The test is EXACT, not a heuristic: "did another build advance this type's watermark?"
// (review-242b SF-1). The LEDGER is that watermark as this code last left it, and it is written in
// the same `context.save()` as every advance or rewind this code makes:
//   • a sync's round save, through `setHelioFetchCursor(type, …)` — the only place any watermark is
//     written, so the pairing cannot be forgotten at a new call site;
//   • this file's rewind.
// A failed save therefore writes neither.
//
// So `watermark > ledger` can only mean a build that drops the type's bytes moved it on, and the
// hole is exactly `[ledger, watermark]`. Every ordinary reason the strap reports nothing — a wear
// gap, charging, stress monitoring off (#240), a day with no qualifying activity, records the strap
// rotated out — leaves `watermark == ledger` and is never a backfill. The previous gap heuristic
// could not tell those apart: `ff` minutes advance the watermark but store no row, so an hour off
// the wrist re-armed a 7-day refetch whose minutes the strictly-forward `.stress` ingest cursor
// then dropped.
//
// No migration: no build on any phone ever wrote the old `zepp.backfill.13` row (59 and 60 predate
// #242), no build ever wrote a PAI ledger, and a timeline with no ledger is exactly the first-run
// case the rule already handles. No schema change either: `StoredCursor` already holds named
// per-device rows (`zepp.steps`, `zepp.fetch.xx`).

extension LocalStore {

    /// The per-timeline ledger row name for `type`: the type's fetch watermark as this code last
    /// left it (`zepp.ledger.13` for stress, `zepp.ledger.0d` for PAI). Deliberately NOT a
    /// `zepp.fetch.` name, so `helioFetchCursors` can never read it as a watermark, and not a
    /// `MetricKind`, so no sample reader mistakes it for one.
    static func helioLedgerName(for type: ZeppFetchType) -> String {
        "zepp.ledger." + String(format: "%02x", type.rawValue)
    }

    /// The stress ledger's row name (`zepp.ledger.13`), unchanged from #239.
    static let helioStressLedgerName = LocalStore.helioLedgerName(for: .autoStress)

    /// The PAI ledger's row name (`zepp.ledger.0d`).
    static let helioPAILedgerName = LocalStore.helioLedgerName(for: .pai)

    /// The types this code backfills, each with its own ledger row and its own rewind target.
    /// Anything else has no ledger and is never rewound.
    static let helioBackfilledTypes: [ZeppFetchType] = [.autoStress, .pai]

    /// `type`'s watermark as this code last left it on `device`, or nil if it never wrote one.
    func helioLedger(_ type: ZeppFetchType, device: SyncDeviceID) -> Date? {
        helioCursor(Self.helioLedgerName(for: type), device: device)
    }

    /// The stress watermark as this code last left it on `device`, or nil if it never wrote one.
    func helioStressLedger(device: SyncDeviceID) -> Date? { helioLedger(.autoStress, device: device) }

    /// The PAI watermark as this code last left it on `device`, or nil if it never wrote one.
    func helioPAILedger(device: SyncDeviceID) -> Date? { helioLedger(.pai, device: device) }

    /// Stage `type`'s fetch watermark and its ledger together, for the caller's save. Always both:
    /// the ledger means "this code put the watermark here", so it is only ever true if they move as
    /// one. A type with no ledger (everything but `helioBackfilledTypes`) stages only its watermark.
    func stageHelioCursorWithLedger(_ type: ZeppFetchType, to date: Date, device: SyncDeviceID) {
        stageHelioCursor(HelioFetchPlan.cursorName(for: type), to: date, device: device)
        guard Self.helioBackfilledTypes.contains(type) else { return }
        stageHelioCursor(Self.helioLedgerName(for: type), to: date, device: device)
    }

    /// Stage the stress watermark and its ledger together, for the caller's save (#239).
    func stageHelioStressCursor(to date: Date, device: SyncDeviceID) {
        stageHelioCursorWithLedger(.autoStress, to: date, device: device)
    }

    /// Rewind the stress watermark if another build advanced it (`HelioFetchPlan.stressBackfillCursor`),
    /// never before the strap's current ownership start (decision 28). Returns the watermark it moved
    /// to, or nil when no backfill was due.
    @discardableResult
    func applyHelioStressBackfillIfNeeded(device: SyncDeviceID) -> Date? {
        applyHelioBackfillIfNeeded(.autoStress, device: device)
    }

    /// Rewind the PAI watermark if another build advanced it (`HelioFetchPlan.paiBackfillCursor`),
    /// bounded by the strap's ownership start and by the raw-sample retention. Returns the watermark
    /// it moved to, or nil when no backfill was due (decision 45).
    @discardableResult
    func applyHelioPAIBackfillIfNeeded(device: SyncDeviceID, now: Date = Date()) -> Date? {
        applyHelioBackfillIfNeeded(.pai, device: device, now: now)
    }

    /// The shared rewind. Nothing is staged or recorded while the strap doesn't own the present
    /// (switched away): the sink then fetches nothing older than now anyway, and the backfill waits
    /// for a sync it owns.
    @discardableResult
    func applyHelioBackfillIfNeeded(_ type: ZeppFetchType, device: SyncDeviceID,
                                    now: Date = Date()) -> Date? {
        guard Self.helioBackfilledTypes.contains(type) else { return nil }
        guard let ownedSince = Self.ownershipLog().currentStart(of: DeviceOwnershipLog.Family(timeline: device)) else {
            return nil
        }
        guard let target = Self.helioBackfillTarget(
            type, watermark: helioFetchCursors(device: device)[type],
            ledger: helioLedger(type, device: device),
            notBefore: Self.helioBackfillFloor(type, ownedSince: ownedSince, now: now)) else { return nil }
        // The rewind is itself this code moving the watermark, so it carries the ledger with it — in
        // one save, rolled back together on failure. The next sync then sees watermark == ledger and
        // is not due, even if this sync is interrupted before the refetched rounds land.
        stageHelioCursorWithLedger(type, to: target, device: device)
        do {
            try context.save()
        } catch {
            context.rollback()
            return nil
        }
        return target
    }

    /// `type`'s rewind target, or nil when no backfill is due. The same ledger rule for both, each
    /// with its own lookback.
    private static func helioBackfillTarget(_ type: ZeppFetchType, watermark: Date?, ledger: Date?,
                                            notBefore: Date?) -> Date? {
        switch type {
        case .autoStress:
            return HelioFetchPlan.stressBackfillCursor(watermark: watermark, ledger: ledger, notBefore: notBefore)
        case .pai:
            return HelioFetchPlan.paiBackfillCursor(watermark: watermark, ledger: ledger, notBefore: notBefore)
        default:
            return nil
        }
    }

    /// How far back `type`'s rewind may reach at the earliest.
    ///
    /// Stress keeps #239's floor exactly: the strap's current ownership start (decision 28).
    ///
    /// PAI adds the raw-sample retention (decision 45): a `.pai` row older than
    /// `sampleRetentionDays` is deleted by the next `pruneExpiredSamples`, so refetching records from
    /// before it is work whose rows can't survive. `HelioFetchPlan.maxLookback` already caps the
    /// FETCH there; this stops the stored watermark itself from being rewound past it.
    private static func helioBackfillFloor(_ type: ZeppFetchType, ownedSince: Date, now: Date) -> Date {
        guard type == .pai else { return ownedSince }
        return max(ownedSince, now.addingTimeInterval(-Double(sampleRetentionDays) * 86_400))
    }
}
