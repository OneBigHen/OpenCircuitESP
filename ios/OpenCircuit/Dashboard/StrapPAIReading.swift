// The Helio Strap's PAI on its Your Numbers tile (decisions 45, 49), READ FROM THE STORE.
//
// Why from the store. The strap card used to show `HelioSession.lastSyncResult.latestPAI`, which the sink
// resets at the start of every sync and sets again only from that sync's own `0x0d` round. `0x0d`
// arrives about once a day (ZEPP_PROTOCOL.md §6.5), so almost every sync brought no record and the
// number was blank — as it was after every relaunch and background wake until the first sync. This
// is the same flaw #239 fixed for stress, and the same fix: each valid record is kept as a `.pai`
// row (`ZeppMetricMapping.paiSamples`), and the tile reads the newest of them.
//
// What this is NOT. There is no chart and no trend for PAI in v1: only the number, on its own tile
// in the Your Numbers grid (decision 49 moved it there from the strap card; tapping it explains PAI).
// PAI is Amazfit's own 7-day rolling score computed by firmware we can't inspect, so the app puts no
// band, no target and no "usual" on it — that would be fabricated precision (decision 25). It stays
// in the app: Apple Health has no PAI type (decision 15).
//
// A ring-only install never sees it: only a strap writes `.pai` rows, and the read below ignores the
// ring's timeline outright.

import Foundation
import OpenCircuitKit
import SwiftData
import ZeppKit

/// The strap's newest stored PAI reading, loaded off the main actor alongside the trends.
struct StrapPAIReading: Equatable {
    /// A reading older than this is not shown.
    ///
    /// 48 h, twice the stress tile's window, because PAI is a different shape of number. A `0x0d`
    /// record is written about once a day and holds a 7-day ROLLING total, so it barely moves between
    /// records — and the newest one is routinely most of a day old already (yesterday's, stamped near
    /// its end of day). With a 24 h bound one missed sync day would blank the tile, which is the
    /// exact bug this is fixing. Past 48 h the score has lost up to two of its seven days and the
    /// day-qualified label is the only thing saying so, so it is hidden rather than shown stale.
    static let maxAge: TimeInterval = 48 * 3600

    /// The newest stored `.pai` sample on a strap's timeline, with its own time.
    let latest: HelioReading

    /// Whether `latest` is recent enough to show at `now`. Checked at RENDER time too, not only at
    /// load, so an app left open past the window doesn't keep showing a stale number. A reading dated
    /// after `now` is never fresh: ingest accepts rows up to a day ahead (a strap clock running
    /// fast), and one of those must not be pinned as "latest" (review-242c NIT 3).
    func isFresh(now: Date) -> Bool {
        latest.at <= now && now.timeIntervalSince(latest.at) <= Self.maxAge
    }

    /// The reading shown at `now`, or nil once it is too old.
    func currentReading(now: Date) -> HelioReading? {
        isFresh(now: now) ? latest : nil
    }

    // MARK: Loading

    /// Off the main actor, like `StrapStressTile.loadAsync`: a detached task reads through a fresh
    /// `ModelContext`. `ModelContainer` is Sendable.
    static func loadAsync(container: ModelContainer, now: Date = Date()) async -> StrapPAIReading? {
        await Task.detached { load(container: container, now: now) }.value
    }

    /// The read itself. nil when no strap PAI reading exists in the last `maxAge`.
    nonisolated static func load(container: ModelContainer, now: Date) -> StrapPAIReading? {
        newestStrapPAI(context: ModelContext(container), now: now).map(StrapPAIReading.init(latest:))
    }

    /// The newest `.pai` row on any strap timeline (never the ring's) started within `maxAge` of
    /// `now` and not after it (a future-dated row is never "latest", review-242c NIT 3). One row:
    /// `fetchLimit` 1, newest first.
    ///
    /// Deliberately NO `value > 0` filter: a total PAI of 0 is a real reading (a week with no
    /// qualifying activity), not a missing one, and hiding it would make the tile lie about a real
    /// zero. There is no index on `StoredSample`, so this is a scan bounded by its predicate — but a
    /// far smaller one than the stress read's, because `0x0d` writes about one row a day; it runs off
    /// the main actor, once per trends load.
    nonisolated static func newestStrapPAI(context: ModelContext, now: Date) -> HelioReading? {
        let kindRaw = MetricKind.pai.rawValue
        let ring = SyncDeviceID.ringConn.rawValue
        let cutoff = now.addingTimeInterval(-maxAge)
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw && $0.deviceID != ring && $0.start >= cutoff && $0.start <= now
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let row = (try? context.fetch(descriptor))?.first else { return nil }
        return HelioReading(value: row.value, at: row.start)
    }
}
