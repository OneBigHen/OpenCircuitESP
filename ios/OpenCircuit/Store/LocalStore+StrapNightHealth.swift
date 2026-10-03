import Foundation
import OpenCircuitKit
import SwiftData

// Decision 50b (#253): the backstop that offers a stored strap night to Apple Health when no sync's
// flush carried it. A sync hands a night to its flush only through `HelioSyncResult.nights`, which
// covers that one sync (and is gone after a relaunch), so a night whose every re-delivery after its
// first store was kept as thinner, or that any other path left behind, was never offered again.
// Decision 57 (#262): the newest stored night too, once it has clearly stopped growing.

extension LocalStore {

    /// How far back the backstop looks: a stranded night older than a week stays in the app.
    static let strapNightHealthLookback: TimeInterval = 7 * 86_400

    /// Decision 57a (#262): how long after its end the NEWEST stored night must have stayed the newest
    /// before the backstop may claim it. Juan's choice (1 h / 3 h / 6 h). Well past the 20-minute
    /// settle margin and any plausible same-day doze; a night's first Health write is permanent (28f),
    /// so don't shorten it without asking Juan.
    static let strapNewestNightHealthBuffer: TimeInterval = 3 * 3600

    /// The stored hypnograms of the strap's nights that never reached Apple Health, for
    /// `HelioConnection.flushStrap` to offer next to its sync's own nights (decision 50b). A night
    /// qualifies when all of these hold:
    /// - the strap owns it (decision 28a, the rule it was stored under);
    /// - it isn't manually edited (the edit reconcile owns those);
    /// - it has a stored hypnogram;
    /// - it has no Health mirror record for its key;
    /// - it began within `strapNightHealthLookback` of `now`;
    /// - a LATER stored night (any device) exists, or, for the newest night itself (decision 57),
    ///   more than `strapNewestNightHealthBuffer` has passed since its end.
    ///
    /// The last rule is the guard. The newest row can be a stale partial copy of a night still in
    /// progress (a sync whose sleep round ran out of time), and mirrored, 28f's "the written night
    /// stands" would keep the full night out for good. A night with a later night after it can't
    /// still be growing. Without one, only real time can say so: 50a offers the newest night only
    /// while the strap keeps re-delivering it, and once it stops, nothing else would until the next
    /// night is stored, up to a day later (#262). The end it is judged on is the later of the row's
    /// `inBedEnd` and its hypnogram's last segment.
    ///
    /// `now` must be the real wall clock at the check (`flushStrap`'s default), never a sync's start:
    /// the buffer is the only thing standing between a night in progress and a permanent write.
    ///
    /// Empty with an empty ownership log (a ring-only install): no query runs.
    func strapNightsAwaitingHealth(timeline: SyncDeviceID, now: Date) -> [[SleepSegment]] {
        let log = Self.ownershipLog()
        guard !log.isEmpty, let newest = try? latestSleepSummary()?.night else { return [] }
        let family = DeviceOwnershipLog.Family(timeline: timeline)
        let since = now.addingTimeInterval(-Self.strapNightHealthLookback)
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.inBedStart >= since },
            sortBy: [SortDescriptor(\.night, order: .forward)])
        return ((try? context.fetch(descriptor)) ?? []).compactMap { row in
            guard let segments = strapSegmentsAwaitingHealth(row, log: log, family: family) else { return nil }
            if row.night < newest { return segments }
            let end = max(row.inBedEnd, segments.map(\.end).max() ?? row.inBedEnd)
            return now.timeIntervalSince(end) > Self.strapNewestNightHealthBuffer ? segments : nil
        }
    }

    /// Decision 57b (#262): when the newest stored strap night that hasn't reached Apple Health leaves
    /// its 20-minute settle margin (`SleepHealthGate`), while it is still inside it; nil otherwise. A
    /// strap flush whose own sync no longer carries that night (the strap stopped re-delivering it)
    /// still asks for the margin refresh with this (`StrapNightRefresh.aim`), so opening the app
    /// doesn't drop a refresh a background wake had asked for. Same qualifying rules as
    /// `strapNightsAwaitingHealth`, on the newest row only. nil with an empty ownership log.
    func newestStrapNightSettles(timeline: SyncDeviceID, now: Date) -> Date? {
        let log = Self.ownershipLog()
        guard !log.isEmpty, let row = try? latestSleepSummary(),
              row.inBedStart >= now.addingTimeInterval(-Self.strapNightHealthLookback),
              let segments = strapSegmentsAwaitingHealth(row, log: log, family: DeviceOwnershipLog.Family(timeline: timeline))
        else { return nil }
        let end = max(row.inBedEnd, segments.map(\.end).max() ?? row.inBedEnd)
        return SleepHealthGate.isSettled(latestSegmentEnd: end, now: now) ? nil : end.addingTimeInterval(SleepHealthGate.settleMargin)
    }

    /// `row`'s stored hypnogram when the row is a strap night that may still go to Apple Health: the
    /// strap owns it, it isn't manually edited, it has no mirror record and its hypnogram isn't empty.
    private func strapSegmentsAwaitingHealth(_ row: StoredSleepSummary, log: DeviceOwnershipLog,
                                             family: DeviceOwnershipLog.Family) -> [SleepSegment]? {
        guard row.inBedEnd > row.inBedStart, !row.isManuallyEdited,
              log.owner(ofNightFrom: row.inBedStart, to: row.inBedEnd) == family,
              mirroredNight(night: row.night) == nil else { return nil }
        let segments = SleepHypnogramCodec.decode(row.hypnogramData)
        return segments.isEmpty ? nil : segments
    }
}
