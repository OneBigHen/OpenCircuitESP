import XCTest
@testable import OpenCircuitKit

/// #241 / decision 46: once a ring workout stops moving the ingest watermark, the ring's OWN
/// history for the workout window reaches the store too, beside the workout's readings. Two series
/// then overlap there, and these pin what the day's readers do with them. Every value is synthetic.
///
/// The short answer, measured below: the readers UNION overlapping elevated time, so nothing is
/// counted twice — feeding the same series in twice changes nothing at all. What DOES change is
/// that the workout hour is now covered, instead of being represented by the 2-second stamps the
/// live path records. Those numbers are quoted exactly, because they are what a user sees move.
final class RingWorkoutOverlapTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_789_862_400)        // 2026-09-20T00:00:00Z
    private let profile = UserProfile(age: 35, weightKg: 70, heightCm: 175, sex: .male)
    private var maxHR: Int { 220 - profile.age }

    private func at(_ s: TimeInterval) -> Date { day.addingTimeInterval(s) }

    /// What `WorkoutSessionManager.collectHRSnapshot` records: one reading per ~10 s `0x4e` sport
    /// frame, each stamped over the two seconds leading up to the lock (`start: at-2, end: at`).
    private func workoutReadings(from: TimeInterval, to: TimeInterval, bpm: Int) -> [HRSample] {
        stride(from: from + 10, through: to, by: 10).map {
            HRSample(bpm: bpm, start: at($0 - 2), end: at($0))
        }
    }

    /// What the ring's own history drain stores: one INSTANT per 150-s epoch. `BulkSleep.samples`
    /// builds them with `QuantitySample(kind:start:value:)`, whose `end` defaults to `start`.
    private func historyInstants(from: TimeInterval, to: TimeInterval, bpm: Int) -> [HRSample] {
        stride(from: from, to: to, by: TimeInterval(BulkRecord.epochSeconds)).map {
            HRSample(bpm: bpm, start: at($0), end: at($0))
        }
    }

    private let workoutStart: TimeInterval = 9 * 3600
    private let workoutEnd: TimeInterval = 10 * 3600
    private var workoutMinutes: Double { (workoutEnd - workoutStart) / 60 }

    /// The ring's quiet all-day history either side of the workout — well below the 92 bpm bar.
    private var restOfDay: [HRSample] {
        historyInstants(from: 7 * 3600, to: workoutStart, bpm: 62)
            + historyInstants(from: workoutEnd, to: 11 * 3600, bpm: 64)
    }
    private var workout: [HRSample] { workoutReadings(from: workoutStart, to: workoutEnd, bpm: 150) }
    private var ringHistoryInsideTheWorkout: [HRSample] {
        historyInstants(from: workoutStart, to: workoutEnd, bpm: 150)
    }

    private func minutes(_ samples: [HRSample]) -> Double {
        ExerciseMinutes.estimate(hrSamples: samples, maxHR: maxHR)
    }
    private func dayKcal(_ samples: [HRSample]) -> Double {
        Calories.dailyEstimate(hrSamples: samples, steps: 0, profile: profile, dayStart: day).activeKcal
    }

    // MARK: Nothing is counted twice

    func testFeedingTheSameSeriesInTwiceChangesNothing() {
        let once = restOfDay + workout + ringHistoryInsideTheWorkout
        let twice = once + once
        XCTAssertEqual(minutes(twice), minutes(once), accuracy: 1e-9,
                       "elevatedPieces sweeps a cursor over the union — a repeated reading adds no time")
        XCTAssertEqual(dayKcal(twice), dayKcal(once), accuracy: 1e-6)
    }

    func testTheWorkoutWindowNeverCountsForMoreThanItsOwnLength() {
        let elevated = minutes(restOfDay + workout + ringHistoryInsideTheWorkout)
        XCTAssertEqual(elevated, workoutMinutes, accuracy: 1e-9,
                       "the hour at 150 bpm is one hour, whichever series covers it")
    }

    /// The readers' arithmetic, quoted. 12.0 min is NOT the workout being counted less than once —
    /// it is all the time the workout's own stamps actually assert: 360 readings × 2 s. The ring's
    /// history fills the rest of the hour in, which is why the number moves when #241 stops
    /// dropping it. Nothing here is a double count; `testFeedingTheSameSeriesInTwiceChangesNothing`
    /// is the proof.
    func testTheRingsHistoryFillsTheWorkoutWindowRatherThanDoublingIt() {
        let without = restOfDay + workout
        let with = without + ringHistoryInsideTheWorkout
        XCTAssertEqual(workout.count, 360)
        XCTAssertEqual(ringHistoryInsideTheWorkout.count, 24)
        XCTAssertEqual(minutes(without), 12.0, accuracy: 1e-9, "360 readings × 2 s")
        XCTAssertEqual(minutes(with), 60.0, accuracy: 1e-9, "the hour, covered once")
        XCTAssertLessThan(minutes(with), 2 * minutes(without) + workoutMinutes)
    }

    /// Why Apple Health's active energy does not move (the half of the hard constraint that is
    /// visible outside the app). The day's HR channel and the workout's own committed sample are
    /// the SAME Keytel number for the same hour at the same average bpm — `finalize` prices the
    /// workout over its true duration — so `netDailyActiveKcalEstimate` subtracts it exactly.
    /// Before #241 the day channel held only the 2-second stamps, so the subtraction clamped at 0
    /// and Health received the workout sample alone; now it nets to 0 and Health receives the same
    /// workout sample alone. The app-side half of this (through `HealthKitWriter`) is
    /// `RingWorkoutHeartRateTests.testActiveEnergyWrittenToHealthIsTheSameEitherWay`.
    func testTheDayChannelAndTheWorkoutsOwnKcalAreTheSameNumberForTheSameHour() {
        let credited = Calories.workoutActiveKcal(avgHR: 150, durationSeconds: workoutEnd - workoutStart,
                                                  profile: profile)
        let dayWithHistory = dayKcal(restOfDay + workout + ringHistoryInsideTheWorkout)
        XCTAssertEqual(dayWithHistory, credited, accuracy: 1e-6)
        XCTAssertEqual(max(0, dayWithHistory - credited), 0, accuracy: 1e-6)
        // …and before the history arrived the subtraction over-reached and clamped, which is the
        // same outcome for Health and a 0 for the day's own estimate.
        XCTAssertLessThan(dayKcal(restOfDay + workout), credited)
    }
}
