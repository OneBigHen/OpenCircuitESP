// "A sync just finished" as an observable count (#239), so an open day chart reloads itself from the
// store when new rows land, instead of being handed a parent's snapshot (the #222 freeze, review S1).
// Bumped by ContentView's one sync-finished path (`loadTrends(.syncFinished)`), which both the ring's
// `session.syncing` hook and the strap's sync-end hook go through.

import Observation

@Observable
@MainActor
final class SyncRevision {
    static let shared = SyncRevision()

    /// Increases by one each time a sync finishes. Use it as a `.task(id:)`.
    private(set) var count = 0

    func syncFinished() { count += 1 }
}
