import Foundation
import OpenCircuitKit
import SwiftData

// Decision 50b (#253): the backstop that offers a stored strap night to Apple Health when no sync's
// flush carried it. A sync hands a night to its flush only through `HelioSyncResult.nights`, which
// covers that one sync (and is gone after a relaunch), so a night whose every re-delivery after its
// first store was kept as thinner, or that any other path left behind, was never offered again.
// Decision 57 (#262): the newest stored night too: once settled when it ended near the scheduled wake,
// else 3 hours after its end.

extension LocalStore {

    /// How far back the backstop looks: a stranded night older than a week stays in the app.
    static let strapNightHealthLookback: TimeInterval = 7 * 86_400

    /// Decision 57a (#262): how long after its end the NEWEST stored night must have stayed the newest
    /// before the backstop may claim it, when its end isn't near the sleep schedule's wake time (see
    /// `strapNewestNightWakeSlack`). Juan's choice (1 h / 3 h / 6 h). A night's first Health write is
    /// permanent (28f), so don't shorten it without asking Juan.
    static let strapNewestNightHealthBuffer: TimeInterval = 3 * 3600

    /// Decision 57 option B (#262, Juan): a newest night whose end is at least this close before the
    /// sleep schedule's wake time (or after it) reads as the morning's final wake, and is claimed as
    /// soon as its settle margin has passed.
    static let strapNewestNightWakeSlack: TimeInterval = 60 * 60

    /// The sleep schedule's wake time, in minutes after local midnight: the value
    /// `BackgroundRefreshScheduler.defaultWindow` reads (06:30 until the person sets one).
    static func scheduledWakeMinutes(_ defaults: UserDefaults = .standard) -> Int {
        SleepScheduleDefaults.register(defaults)
        return defaults.integer(forKey: SleepScheduleDefaults.wakeMinutes)
    }

    /// Whether a night that ended at `end` ended near the morning's final wake: at or after the
    /// schedule's wake time minus `strapNewestNightWakeSlack`, and before noon (28d's wake window,
    /// `SleepNightKey.wakeWindowEndHour`), in `calendar`'s zone. The noon bound keeps a time of day
    /// read in another zone than the night's (after travel; stored rows keep no zone) from passing as
    /// a morning. Wake times inside the slack of midnight make every morning end pass.
    static func strapNightEndsNearScheduledWake(_ end: Date, wakeMinutes: Int, calendar: Calendar = .current) -> Bool {
        let clock = calendar.dateComponents([.hour, .minute], from: end)
        let hour = clock.hour ?? 0
        guard hour < SleepNightKey.wakeWindowEndHour else { return false }
        return hour * 60 + (clock.minute ?? 0) >= wakeMinutes - Int(strapNewestNightWakeSlack / 60)
    }

    /// The stored hypnograms of the strap's nights that never reached Apple Health, for
    /// `HelioConnection.flushStrap` to offer next to its sync's own nights (decision 50b). A night
    /// qualifies when all of these hold:
    /// - the strap owns it (decision 28a, the rule it was stored under);
    /// - it isn't manually edited (the edit reconcile owns those);
    /// - it has a stored hypnogram;
    /// - it has no Health mirror record for its key;
    /// - it began within `strapNightHealthLookback` of `now`;
    /// - a LATER stored night (any device) exists, or, for the newest night itself (decision 57), one
    ///   of two paths holds. Its end is the later of the row's `inBedEnd` and its hypnogram's last
    ///   segment.
    ///   - Its end is near the morning's final wake (`strapNightEndsNearScheduledWake`, from the sleep
    ///     schedule's wake time, `wakeMinutes`), and its 20-minute settle margin has passed
    ///     (`SleepHealthGate.isSettled`, the margin every other write path uses).
    ///   - Otherwise, more than `strapNewestNightHealthBuffer` (3 h) has passed since its end.
    ///
    /// Why two paths: the strap delivers a sleep only once it has ended, and 28f stitches sessions up
    /// to an hour apart (a longer later sleep replaces the row). After a mid-night awakening (stored
    /// 23:00–02:00, back to bed at 02:30), the margin alone would let the 02:20 margin refresh write
    /// the first part, and "the written night stands" would keep the whole night out for good. A
    /// night that ends near the scheduled wake is the common morning case, and goes as soon as it has
    /// settled; one that ends far earlier waits the 3 hours.
    ///
    /// `now` must be the real wall clock at the check (`flushStrap`'s default), never a sync's start.
    ///
    /// Empty with an empty ownership log (a ring-only install): no query runs.
    func strapNightsAwaitingHealth(timeline: SyncDeviceID, now: Date,
                                   wakeMinutes: Int = LocalStore.scheduledWakeMinutes()) -> [[SleepSegment]] {
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
            if Self.strapNightEndsNearScheduledWake(end, wakeMinutes: wakeMinutes),
               SleepHealthGate.isSettled(latestSegmentEnd: end, now: now) {
                return segments
            }
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
