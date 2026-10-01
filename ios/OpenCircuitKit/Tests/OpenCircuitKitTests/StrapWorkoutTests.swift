import XCTest
@testable import OpenCircuitKit

// The strap workout's pure rules (#227). Every time and reading is synthetic.
final class StrapWorkoutTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// One reading per second over `[from, to)`, each spanning the second before it.
    private func readings(_ from: TimeInterval, _ to: TimeInterval, bpm: Int) -> [HRSample] {
        stride(from: from + 1, through: to, by: 1).map { HRSample(bpm: bpm, start: at($0 - 1), end: at($0)) }
    }

    // MARK: Ledger

    func testActiveDurationLeavesPausesOut() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(600))
        ledger.resume(at: at(900))
        XCTAssertEqual(ledger.activeSeconds(until: at(1500)), 1200)
        XCTAssertEqual(ledger.activeSegments(until: at(1500)),
                       [DateInterval(start: t0, end: at(600)), DateInterval(start: at(900), end: at(1500))])
        ledger.pause(at: at(1500))
        XCTAssertTrue(ledger.isPaused)
        XCTAssertEqual(ledger.activeSeconds(until: at(2000)), 1200, "an open pause counts nothing")
        XCTAssertEqual(ledger.pauses(until: at(2000)).count, 2)
    }

    func testRepeatedOrBackwardPauseEventsAreIgnored() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.resume(at: at(10))                      // not paused: nothing
        ledger.pause(at: at(100))
        ledger.pause(at: at(200))                      // already paused
        ledger.resume(at: at(300))
        ledger.pause(at: at(250))                      // before the last event
        XCTAssertFalse(ledger.isPaused)
        XCTAssertEqual(ledger.pauses, [DateInterval(start: at(100), end: at(300))])
    }

    func testGapsAreRecordedAndCloseAtTheQueryEnd() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.beginGap(at: at(100))
        ledger.beginGap(at: at(110))                   // already open
        ledger.endGap(at: at(160))
        ledger.beginGap(at: at(400))
        XCTAssertEqual(ledger.gaps(until: at(450)),
                       [DateInterval(start: at(100), end: at(160)), DateInterval(start: at(400), end: at(450))])
        XCTAssertEqual(ledger.activeSeconds(until: at(450)), 450, "a gap is not a pause: the workout keeps running")
    }

    // MARK: Summary

    func testStartPauseResumeEndGivesTheActiveDurationAndZonesWithoutThePause() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(300))
        ledger.resume(at: at(420))
        // 152 bpm is 84 % of 180 (anaerobic). Readings during the pause must not count.
        let samples = readings(0, 300, bpm: 152) + readings(300, 420, bpm: 100) + readings(420, 600, bpm: 152)
        let result = StrapWorkoutSummaryBuilder.summarize(sport: .runningIndoor, ledger: ledger, samples: samples,
                                                          end: at(600), distanceMeters: nil, hasRoute: false, profile: profile)
        XCTAssertEqual(result.activeSeconds, 480)
        XCTAssertEqual(result.summary.hrSampleCount, 480, "the 120 readings inside the pause are not workout readings")
        XCTAssertEqual(result.summary.avgHR, 152)
        XCTAssertEqual(result.summary.zoneBreakdown.anaerobicSeconds, 480, accuracy: 0.001,
                       "each running stretch is held to its own end, never across the pause")
        XCTAssertEqual(result.summary.zoneBreakdown.totalZoneSeconds, result.summary.zoneBreakdown.anaerobicSeconds)
        XCTAssertEqual(result.pauses, [DateInterval(start: at(300), end: at(420))])
        let kcal = Calories.workoutActiveKcal(avgHR: 152, durationSeconds: 480, profile: profile)
        XCTAssertEqual(result.summary.estimatedActiveKcal ?? -1, kcal, accuracy: 0.0001, "energy over the active time")
    }

    func testALinkGapGetsNoZoneTimeAndIsReported() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.beginGap(at: at(200))
        ledger.endGap(at: at(320))
        let samples = readings(0, 200, bpm: 152) + readings(320, 600, bpm: 152)
        let result = StrapWorkoutSummaryBuilder.summarize(sport: .runningIndoor, ledger: ledger, samples: samples,
                                                          end: at(600), distanceMeters: nil, hasRoute: false, profile: profile)
        XCTAssertEqual(result.activeSeconds, 600, "the workout kept running through the drop")
        // The last reading before the drop is held for the 30 s cap, never across the whole gap.
        // 200 readings before (199 one-second holds + the last held to the 30 s cap), 280 after.
        XCTAssertEqual(result.summary.zoneBreakdown.anaerobicSeconds, 199 + 30 + 280, accuracy: 0.001)
        XCTAssertEqual(result.gaps, [DateInterval(start: at(200), end: at(320))])
        XCTAssertEqual(result.gapSeconds, 120)
    }

    func testNoReadingsMeansNoHeartRateNumbers() {
        let result = StrapWorkoutSummaryBuilder.summarize(sport: .yoga, ledger: WorkoutActivityLedger(start: t0), samples: [],
                                                          end: at(600), distanceMeters: nil, hasRoute: false, profile: profile)
        XCTAssertNil(result.summary.avgHR)
        XCTAssertNil(result.summary.maxHR)
        XCTAssertNil(result.summary.estimatedActiveKcal)
        XCTAssertEqual(result.summary.zoneBreakdown.totalZoneSeconds, 0)
    }

    func testGapSecondsLeaveOutTheTimeAlsoPaused() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.beginGap(at: at(100))
        ledger.pause(at: at(150))
        ledger.resume(at: at(250))
        ledger.endGap(at: at(300))
        let result = StrapWorkoutSummaryBuilder.summarize(sport: .yoga, ledger: ledger, samples: [], end: at(400),
                                                          distanceMeters: nil, hasRoute: false, profile: profile)
        XCTAssertEqual(result.gapSeconds, 100)
    }

    // MARK: Journal

    func testTheJournalAndSampleLinesRoundTrip() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(10))
        let journal = StrapWorkoutJournal(sport: .hiking, ledger: ledger, lastAliveAt: at(20), timelineRaw: "zeppos:A")
        XCTAssertEqual(StrapWorkoutJournal.decoded(from: journal.encoded()), journal)
        XCTAssertNil(StrapWorkoutJournal.decoded(from: Data("garbage".utf8)))

        let samples = readings(0, 3, bpm: 120)
        let text = samples.map(StrapWorkoutSampleLine.encode).joined() + "1790000004.0"   // a torn last line
        XCTAssertEqual(StrapWorkoutSampleLine.decode(text), samples)
        XCTAssertEqual(StrapWorkoutSampleLine.decode("1790000001.000,250\n"), [], "an impossible reading is dropped")
    }

    // MARK: Recovery

    func testARecoveredWorkoutClosesAtItsLastSample() {
        let ledger = WorkoutActivityLedger(start: t0)
        let journal = StrapWorkoutJournal(sport: .runningOutdoor, ledger: ledger, lastAliveAt: at(1210), timelineRaw: "zeppos:A")
        let samples = readings(0, 1200, bpm: 140)
        guard case .offer(let recovered) = StrapWorkoutRecovery.decide(journal: journal, samples: samples, now: at(5000)) else {
            return XCTFail("expected an offer")
        }
        XCTAssertEqual(recovered.end, at(1200), "the last reading, not the heartbeat and never now")
        XCTAssertEqual(recovered.activeSeconds, 1200)
        XCTAssertEqual(recovered.samples.count, 1200)
    }

    func testARecoveredWorkoutWithoutReadingsClosesAtTheLastHeartbeat() {
        let journal = StrapWorkoutJournal(sport: .yoga, ledger: WorkoutActivityLedger(start: t0), lastAliveAt: at(300), timelineRaw: "zeppos:A")
        guard case .offer(let recovered) = StrapWorkoutRecovery.decide(journal: journal, samples: [], now: at(5000)) else {
            return XCTFail("expected an offer")
        }
        XCTAssertEqual(recovered.end, at(300))
    }

    func testARecoveredWorkoutPausedAtDeathClosesAtThePause() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(500))
        let journal = StrapWorkoutJournal(sport: .yoga, ledger: ledger, lastAliveAt: at(900), timelineRaw: "zeppos:A")
        let samples = readings(0, 800, bpm: 90)   // the stream kept running while paused
        guard case .offer(let recovered) = StrapWorkoutRecovery.decide(journal: journal, samples: samples, now: at(5000)) else {
            return XCTFail("expected an offer")
        }
        XCTAssertEqual(recovered.end, at(500))
        XCTAssertEqual(recovered.activeSeconds, 500)
        XCTAssertEqual(recovered.samples.count, 500)
    }

    func testRecoveryRefusesNothingObservedAndTheFuture() {
        let empty = StrapWorkoutJournal(sport: .yoga, ledger: WorkoutActivityLedger(start: t0), lastAliveAt: t0, timelineRaw: "zeppos:A")
        XCTAssertEqual(StrapWorkoutRecovery.decide(journal: empty, samples: [], now: at(10)), .discard(.noObservedSpan))
        let future = StrapWorkoutJournal(sport: .yoga, ledger: WorkoutActivityLedger(start: t0), lastAliveAt: at(100), timelineRaw: "zeppos:A")
        XCTAssertEqual(StrapWorkoutRecovery.decide(journal: future, samples: [], now: at(50)), .discard(.endsInTheFuture))
        XCTAssertEqual(StrapWorkoutRecovery.decide(journal: nil, samples: [], now: at(50)), .nothingToRecover)
    }

    // MARK: Landing

    func testReadingsLandOnlyOnceTheStrapsHistoryCoversThem() {
        let pending = readings(0, 120, bpm: 130)
        let none = StrapWorkoutHRLanding.split(pending, coveredThrough: nil, now: at(200))
        XCTAssertEqual(none.land.count, 0)
        XCTAssertEqual(none.keep.count, 120)

        let half = StrapWorkoutHRLanding.split(pending, coveredThrough: at(60), now: at(200))
        XCTAssertEqual(half.land.count, 60)
        XCTAssertEqual(half.keep.first?.start, at(60))

        let stale = StrapWorkoutHRLanding.split(pending, coveredThrough: nil, now: at(120 + StrapWorkoutHRLanding.maxWait))
        XCTAssertEqual(stale.land.count, 120, "never held forever")
    }
}
