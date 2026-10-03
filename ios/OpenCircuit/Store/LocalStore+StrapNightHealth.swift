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
    /// - a LATER stored night (any device) exists, keyed no later than `now` (#259).
    ///
    /// The last rule is the guard, and it must stay a stored-night rule, not a clock rule: the newest
    /// row can be a stale partial copy of a night still in progress (a sync whose sleep round ran out
    /// of time). Mirrored, 28f's "the written night stands" would keep the full night out for good. A
    /// night with a later night after it can't still be growing.
    ///
    /// Empty with an empty ownership log (a ring-only install): no query runs.
    func strapNightsAwaitingHealth(timeline: SyncDeviceID, now: Date) -> [[SleepSegment]] {
        let log = Self.ownershipLog()
        guard !log.isEmpty, let newest = newestSleepNightKey(notAfter: now) else { return [] }
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
                  !MirroredNightOverlay.hasRecord(storedNight: row.night),
                  // The writer declined this exact stored night before (#259): it would again.
                  StrapNightDeclinedOverlay.load(storedNight: row.night) != row.hypnogramData else { return nil }
            let segments = SleepHypnogramCodec.decode(row.hypnogramData)
            return segments.isEmpty ? nil : segments
        }
    }

    /// The newest stored night key that is not after `now`, from any device: the backstop's guard.
    ///
    /// #259: it was `latestSleepSummary()`, the newest key of all. A key is the start of the day the
    /// night ended on, so a real night's key is never after the moment it is read: its wake has
    /// passed. A key after `now` can only come from a future-dated night (a device clock set ahead),
    /// and as the newest key it would hold back every night before it until real time caught up.
    /// Such a row is not judged here; it is just not allowed to be the guard.
    private func newestSleepNightKey(notAfter now: Date) -> Date? {
        var descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night <= now },
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.night
    }

    /// Note that the writer declined `segments` (`HealthKitWriter.MirrorOutcome.declined`) when they
    /// are a stored night's hypnogram exactly, so the backstop stops offering that night (#259).
    ///
    /// Without this, a night the writer refuses without leaving a mirror record — another device
    /// keeps it, or it is thinner than its card — was offered on every strap flush for 7 days, each
    /// offer costing a full-table overlap query on the main actor, to the same refusal each time.
    ///
    /// What is noted is the stored HYPNOGRAM, not just the night: a night whose stored hypnogram
    /// changes is a different offer, and is offered again. A `failed` write is never noted (it may
    /// pass next time), and nor is a night with a mirror record. Nothing with an empty ownership log.
    func noteStrapNightDeclined(_ segments: [SleepSegment]) {
        guard !Self.ownershipLog().isEmpty,
              let start = segments.map(\.start).min(), let end = segments.map(\.end).max(), end > start,
              let row = try? sleepSummaryOverlapping(start: start, end: end),
              !row.hypnogramData.isEmpty,
              !MirroredNightOverlay.hasRecord(storedNight: row.night),
              SleepHypnogramCodec.decode(row.hypnogramData) == segments else { return }
        StrapNightDeclinedOverlay.save(row.hypnogramData, storedNight: row.night)
    }
}

/// The stored hypnogram of a strap night the writer declined, by its stored night key (#259).
/// Keyed by the key's exact instant rather than the current zone's start of day, so a time-zone
/// change can't lose it. A night re-keyed by a migration loses its note and is offered once more,
/// which is the behaviour before this existed.
enum StrapNightDeclinedOverlay {
    private static func key(_ night: Date) -> String {
        "sleep.strap.declined.night.\(night.timeIntervalSince1970)"
    }

    static func load(storedNight night: Date) -> Data? {
        UserDefaults.standard.data(forKey: key(night))
    }

    static func save(_ hypnogram: Data, storedNight night: Date) {
        UserDefaults.standard.set(hypnogram, forKey: key(night))
    }

    static func clear(storedNight night: Date) {
        UserDefaults.standard.removeObject(forKey: key(night))
    }
}
