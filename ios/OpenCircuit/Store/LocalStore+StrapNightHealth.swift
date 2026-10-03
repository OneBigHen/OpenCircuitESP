import Foundation
import OpenCircuitKit
import SwiftData

// Decision 50b (#253): the backstop that offers a stored strap night to Apple Health when no sync's
// flush carried it. A sync hands a night to its flush only through `HelioSyncResult.nights`, which
// covers that one sync (and is gone after a relaunch), so a night whose every re-delivery after its
// first store was kept as thinner, or that any other path left behind, was never offered again.

extension LocalStore {

    /// How far back the backstop looks: a stranded night older than a week stays in the app.
    static let strapNightHealthLookback: TimeInterval = 7 * 86_400

    /// The stored hypnograms of the strap's nights that never reached Apple Health, for
    /// `HelioConnection.flushStrap` to offer next to its sync's own nights (decision 50b). A night
    /// qualifies when all of these hold:
    /// - the strap owns it (decision 28a, the rule it was stored under);
    /// - it isn't manually edited (the edit reconcile owns those);
    /// - it has a stored hypnogram;
    /// - it has no Health mirror record for its key, in the zone it was stored in or the current one;
    /// - it began within `strapNightHealthLookback` of `now`;
    /// - a LATER stored night (any device) exists.
    ///
    /// The last rule is the guard, and it must stay a stored-night rule, not a clock rule: the newest
    /// row can be a stale partial copy of a night still in progress (a sync whose sleep round ran out
    /// of time). Mirrored, 28f's "the written night stands" would keep the full night out for good. A
    /// night with a later night after it can't still be growing.
    ///
    /// Empty with an empty ownership log (a ring-only install): no query runs.
    func strapNightsAwaitingHealth(timeline: SyncDeviceID, now: Date) -> [[SleepSegment]] {
        let log = Self.ownershipLog()
        guard !log.isEmpty, let newest = try? latestSleepSummary()?.night else { return [] }
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        let since = now.addingTimeInterval(-Self.strapNightHealthLookback)
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.inBedStart >= since && $0.night < newest },
            sortBy: [SortDescriptor(\.night, order: .forward)])
        return ((try? context.fetch(descriptor)) ?? []).compactMap { row in
            guard row.inBedEnd > row.inBedStart, !row.isManuallyEdited,
                  log.owner(ofNightFrom: row.inBedStart, to: row.inBedEnd) == family,
                  // Under its stored key's own zone too (#259): a time-zone change must not re-offer
                  // a week of nights Apple Health already holds.
                  !MirroredNightOverlay.hasRecord(storedNight: row.night) else { return nil }
            let segments = SleepHypnogramCodec.decode(row.hypnogramData)
            return segments.isEmpty ? nil : segments
        }
    }
}
