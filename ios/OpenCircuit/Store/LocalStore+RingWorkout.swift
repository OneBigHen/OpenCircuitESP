import Foundation
import OpenCircuitKit
import SwiftData

// A RING workout's heart rate in `LocalStore` (#241, decision 46) — the mechanism the strap has
// used since #227 (`LocalStore+StrapWorkout.swift`), now on the ring's own timeline.
//
// WHAT WAS WRONG. The End path used to hand the workout's readings to `LocalStore.ingest`, the
// ring's own `(ringconn, heartRate)` ingest cursor. `SyncCursor.selectNew` keeps only `start > last`,
// so the cursor was left sitting at the workout's final reading. The history channel is shut for the
// whole workout (`RingSession.evaluatePeriodicDrain`, `!workoutHolding`), so the drain that re-arms
// at End carries everything the ring buffered since the last sync — and every one of those readings
// is OLDER than the cursor the workout just moved. They were dropped in silence. A workout started
// before the morning sync cost the whole night's heart rate.
//
// The second watermark had the same shape: a Health flush landing between End and the next drain
// wrote the workout's rows and moved `hk:heartRate` to the workout's end, so back-filled older rows
// could never be offered to Apple Health again even once the store side was fixed.
//
// WHAT HAPPENS NOW. Neither watermark moves:
//   • the rows go in directly, deduplicated by `start`, so the ingest cursor stays where the last
//     drain left it and the backlog from before and during the workout still lands;
//   • the workout's span is recorded in `WorkoutHealthExclusions` before the first row exists, so
//     `pendingHealthSamples` leaves those readings out of the flush without `hk:heartRate` moving.
//     They are already in Apple Health, inside the HKWorkout `writeWorkout` committed.
//
// Dedupe-by-start is what makes re-running the End path a no-op — the job the cursor gate used to do.
//
// The ring's OWN history inside the workout window is kept and mirrored like any other history
// (decision 46), exactly as the strap's is. The two series overlap there and do not double count:
// `ExerciseMinutes.elevatedPieces` sweeps a cursor over the union, so an instant inside a workout
// reading's span adds no time, and the active-energy flush nets the workout's committed kcal out of
// the day (`HealthKitWriter.netDailyActiveKcalEstimate`). Both are pinned in
// `RingWorkoutHeartRateTests`.

extension LocalStore {
    /// Land a finished ring workout's readings in the store (#241).
    ///
    /// Chunked, with `betweenChunks` awaited after each save: each `insertWorkoutHeartRateRows` is one
    /// `context.save()`, and a single save of a long workout invalidated every `@Query[StoredSample]`
    /// at once — the dashboard `List` then re-fetched and re-laid-out all of it on the main thread,
    /// which is the `0x8BADF00D` scene-update watchdog SIGKILL a user hit when backgrounding right
    /// after a long workout summary. The call site passes a short sleep so the runloop gets a real
    /// turn between saves; `Task.yield()` is NOT enough (it resumes on the same executor).
    ///
    /// Chunking is now purely that watchdog concern: deduplication is by `start` against the rows
    /// already in the store, so the result is chunk-size-invariant. (Under the old cursor gate it was
    /// not — a boundary splitting an equal-`start` run dropped the tail — hence the boundary-extending
    /// loop this replaces.)
    ///
    /// The exclusion span is recorded ONCE, for the whole workout, before the first chunk is saved:
    /// a flush racing the chunk loop must never see a row this span does not cover.
    func landRingWorkoutHeartRate(_ samples: [HRSample],
                                  chunkSize: Int = 64,
                                  betweenChunks: () async -> Void = {}) async throws {
        guard chunkSize > 0, let span = workoutHeartRateSpan(samples, timeline: .ringConn) else { return }
        WorkoutHealthExclusions().add(span, device: .ringConn)
        let sorted = samples.sorted { $0.start < $1.start }
        var i = 0
        var firstError: Error?
        while i < sorted.count {
            let end = min(i + chunkSize, sorted.count)
            // A failed chunk does not abandon the rest, which is what the per-chunk `try?` this
            // replaces gave us: the readings are already in Health inside the HKWorkout, so every
            // chunk that CAN land should, and only the local estimate is short if one cannot.
            do { try insertWorkoutHeartRateRows(Array(sorted[i..<end]), timeline: .ringConn) }
            catch { if firstError == nil { firstError = error } }
            i = end
            await betweenChunks()
        }
        if let firstError { throw firstError }
    }
}
