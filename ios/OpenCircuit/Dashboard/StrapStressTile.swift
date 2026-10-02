// The Helio Strap's stress on Today (#239, steer 3): the number on the strap card and the Stress tile
// next to the other Today metrics, both read FROM THE STORE.
//
// Why from the store. The card used to show `HelioSession.lastSyncResult.latestStress`, which the sink
// resets at the start of every sync and sets again only from that sync's own auto-stress round. So
// the number — and since #242 the button into the stress chart — vanished after any sync that brought
// no new stress minute, and after every relaunch or background wake until the first sync. The full
// per-minute history is already stored as `.stress` rows (#242); this reads the newest of them, so it
// survives all of those.
//
// What the tile is NOT. It has no "usual range" and no baseline, deliberately: the strap's stress is
// its own 0–100 scale, scored by firmware we can't inspect, and nothing in this app has established
// what a person's usual on it is. Inventing a band would be fabricated precision (decision 25). The
// only words on it are Amazfit's own four (`HelioStressBand`, ZEPP_PROTOCOL.md §6.5). It is labelled
// the way the day chart labels its card ("Stress · Helio Strap"), so it is never mistaken for the
// ring's Overnight Stress score, which is a different number from a different device.
//
// A ring-only install never sees it: only a strap writes `.stress` rows (ring all-day stress is not
// decoded, #94), and the read below ignores the ring's timeline outright.

import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

/// The strap's newest stored stress reading and today's readings, as one value loaded off the main
/// actor. The model behind both the strap card's number and the Today Stress tile.
struct StrapStressTile: Equatable {
    /// A reading older than this is not shown, on the card or as a tile.
    static let maxAge: TimeInterval = 24 * 3600

    /// The newest stored `.stress` sample on a strap's timeline, with its own time.
    let latest: HelioReading
    /// Today's (local day's) strap stress, bucketed like the day chart, for the tile's sparkline.
    let today: IntradaySeries.Day
    /// Today's window, the sparkline's x-domain.
    let day: DateInterval

    /// Amazfit's word for the latest level; nil only for a value outside 0–100, which ingest never stores.
    var band: HelioStressBand? { HelioStressBand(level: Int(latest.value.rounded())) }

    /// Whether `latest` is recent enough to show at `now`. Checked at RENDER time too, not only at
    /// load, so an app left open past the 24 hours doesn't keep showing a stale number.
    func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(latest.at) <= Self.maxAge
    }

    /// The reading the card shows at `now`, or nil once it is too old.
    func currentReading(now: Date) -> HelioReading? {
        isFresh(now: now) ? latest : nil
    }

    // MARK: Loading

    /// Off the main actor, like `TrendsData.loadAsync` and `DayTimeline.loadAsync`: the ownership log is
    /// snapshotted on the main actor and a detached task reads through a fresh `ModelContext`.
    static func loadAsync(container: ModelContainer, now: Date = Date(),
                          calendar: Calendar = .current) async -> StrapStressTile? {
        let log = await MainActor.run { LocalStore.ownershipLog() }
        return await Task.detached {
            load(container: container, log: log, now: now, calendar: calendar)
        }.value
    }

    /// The read itself. nil when no strap stress reading exists in the last `maxAge`.
    nonisolated static func load(container: ModelContainer, log: DeviceOwnershipLog, now: Date,
                                 calendar: Calendar) -> StrapStressTile? {
        let context = ModelContext(container)
        guard let latest = newestStrapStress(context: context, now: now) else { return nil }
        let day = DayTimeline.dayInterval(now, calendar: calendar)
        // The strap's own readings in the strap's own time (`ownSamples(of: .zeppOS)`, the decision-29
        // read the baselines use), through the same nonisolated core as the main-actor store.
        let samples = (try? LocalStore.ownSamples(in: context, kind: .stress, from: day.start, to: day.end,
                                                   of: .zeppOS, log: log)) ?? []
        let points = samples.map { IntradaySeries.Point(time: $0.start, value: $0.value) }
        return StrapStressTile(latest: latest, today: IntradaySeries.day(points, day: day, log: log), day: day)
    }

    /// The newest `.stress` row on any strap timeline (never the ring's) started within `maxAge` of
    /// `now`. One row: `fetchLimit` 1, newest first. There is no index on `StoredSample`, so this is a
    /// scan bounded by its predicate (review-242b NIT 2 measured the same shape at ~8–12 ms warm and
    /// ~32 ms cold on 86 k rows); it runs off the main actor, once per trends load.
    nonisolated static func newestStrapStress(context: ModelContext, now: Date) -> HelioReading? {
        let kindRaw = MetricKind.stress.rawValue
        let ring = SyncDeviceID.ringConn.rawValue
        let cutoff = now.addingTimeInterval(-maxAge)
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.deviceID != ring && $0.start >= cutoff },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let row = (try? context.fetch(descriptor))?.first else { return nil }
        return HelioReading(value: row.value, at: row.start)
    }
}
