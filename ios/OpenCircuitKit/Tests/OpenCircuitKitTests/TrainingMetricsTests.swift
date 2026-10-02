import XCTest
@testable import OpenCircuitKit

// Worked examples for #232's training metrics, each built by hand from the published formula and
// checked against the code. The arithmetic is in the comments so a reviewer can redo it on paper.
// Methods and citations: docs/TRAINING_METRICS.md.
//
// All inputs are synthetic (no capture, no real person's data).
final class TrainingLoadTests: XCTestCase {

    // MARK: Edwards TRIMP from a zone breakdown

    func testEdwardsTRIMPSumsMinutesTimesZoneNumber() {
        // 10 min z1, 15 min z2, 20 min z3, 8 min z4, 2 min z5
        // = 10×1 + 15×2 + 20×3 + 8×4 + 2×5 = 10 + 30 + 60 + 32 + 10 = 142
        let zones = WorkoutZoneBreakdown(warmUpSeconds: 600, fatBurnSeconds: 900,
                                         aerobicSeconds: 1200, anaerobicSeconds: 480,
                                         extremeSeconds: 120)
        XCTAssertEqual(TrainingLoad.edwardsTRIMP(zones), 142, accuracy: 1e-9)
    }

    func testPartialMinutesCountPartially() {
        // 90 s in z3 = 1.5 min × 3 = 4.5
        let zones = WorkoutZoneBreakdown(aerobicSeconds: 90)
        XCTAssertEqual(TrainingLoad.edwardsTRIMP(zones), 4.5, accuracy: 1e-9)
    }

    func testNoHeartRateIsNilButEasyHeartRateIsZero() {
        // No readings at all → nothing to score (nil), not a measured 0.
        XCTAssertNil(TrainingLoad.workoutLoad(zones: WorkoutZoneBreakdown(), hrSampleCount: 0))
        // Readings that all sat under 50 % of max → no zone time → Edwards gives 0. A real 0.
        XCTAssertEqual(TrainingLoad.workoutLoad(zones: WorkoutZoneBreakdown(), hrSampleCount: 40), 0)
    }

    func testZoneMaxHRMatchesTheWorkoutAggregator() {
        // 220 − 40 = 180, the max the zone bars are drawn with.
        XCTAssertEqual(TrainingLoad.zoneMaxHR(age: 40), 180)
        // The aggregator clamps age to ≥ 1 and max to ≥ 1; so does this.
        XCTAssertEqual(TrainingLoad.zoneMaxHR(age: 0), 219)
        XCTAssertEqual(TrainingLoad.zoneMaxHR(age: 400), 1)
    }

    func testLoadFromStoredHeartRateMatchesTheSummaryLoad() {
        // Age 40 → max 180. 150 bpm = 83.3 % → zone 4 (81–90 %). Readings every 10 s for 10 min,
        // the last held to the session end: 60 × 10 s = 600 s = 10 min × 4 = 40.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0 ..< 60).map { HRSample(bpm: 150, start: t0.addingTimeInterval(Double($0) * 10)) }
        let end = t0.addingTimeInterval(600)
        XCTAssertEqual(TrainingLoad.workoutLoad(hrSamples: samples, age: 40, sessionEnd: end) ?? -1,
                       40, accuracy: 1e-9)

        // And the same samples through the live aggregator give the same number on the summary.
        let agg = WorkoutSessionAggregator(startDate: t0, userAge: 40)
        samples.forEach { agg.add(sample: $0) }
        let summary = agg.finalize(sport: .runningOutdoor, endDate: end, distanceMeters: nil,
                                   hasRoute: false,
                                   profile: UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .female))
        XCTAssertEqual(TrainingLoad.workoutLoad(zones: summary.zoneBreakdown,
                                                hrSampleCount: summary.hrSampleCount) ?? -1,
                       40, accuracy: 1e-9)
        XCTAssertNil(TrainingLoad.workoutLoad(hrSamples: [], age: 40, sessionEnd: end))
    }

    // MARK: Weekly trend

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    func testWeeklyLoadAgainstFourWeekAverage() {
        // This week (last 7 days): 100 + 50 = 150, plus one workout with no heart rate (not counted).
        // Previous 4 weeks (7–35 days ago): 80 + 120 + 200 = 400 → 400 ÷ 4 = 100 per week.
        // 36 days ago is outside both windows. 150 ÷ 100 − 1 = +50 % → higher.
        let loads: [TrainingLoad.DatedLoad] = [
            .init(end: daysAgo(1), load: nil),
            .init(end: daysAgo(2), load: 100),
            .init(end: daysAgo(6), load: 50),
            .init(end: daysAgo(10), load: 80),
            .init(end: daysAgo(20), load: 120),
            .init(end: daysAgo(30), load: 200),
            .init(end: daysAgo(36), load: 999),
        ]
        let trend = TrainingLoad.weeklyTrend(loads, now: now)
        XCTAssertEqual(trend.thisWeek, 150, accuracy: 1e-9)
        XCTAssertEqual(trend.unscoredThisWeek, 1)
        XCTAssertEqual(trend.previousWeeklyAverage ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(trend.change ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(trend.direction, .higher)
    }

    func testWindowEdges() {
        // Exactly 7 days ago belongs to the PREVIOUS weeks (this week is (now − 7 d, now]);
        // exactly 35 days ago is outside the history (it is (now − 35 d, now − 7 d]).
        let trend = TrainingLoad.weeklyTrend([
            .init(end: daysAgo(7), load: 40),
            .init(end: daysAgo(35), load: 1000),
            .init(end: now, load: 42),
        ], now: now)
        // this week = 42; previous = 40 ÷ 4 = 10; 42 ÷ 10 − 1 = 3.2
        XCTAssertEqual(trend.thisWeek, 42, accuracy: 1e-9)
        XCTAssertEqual(trend.previousWeeklyAverage ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(trend.change ?? -1, 3.2, accuracy: 1e-9)
    }

    func testWithinTenPercentIsSimilarAndBelowIsLower() {
        // 105 vs 400 ÷ 4 = 100 → +5 % → similar. 85 vs 100 → −15 % → lower.
        let history: [TrainingLoad.DatedLoad] = [.init(end: daysAgo(14), load: 400)]
        let similar = TrainingLoad.weeklyTrend(history + [.init(end: daysAgo(1), load: 105)], now: now)
        XCTAssertEqual(similar.direction, .similar)
        let lower = TrainingLoad.weeklyTrend(history + [.init(end: daysAgo(1), load: 85)], now: now)
        XCTAssertEqual(lower.direction, .lower)
    }

    func testNoHistoryMeansNoComparisonNotAZeroAverage() {
        // Nothing scored in the previous 4 weeks: the app can't tell rest from "not installed yet".
        let trend = TrainingLoad.weeklyTrend([.init(end: daysAgo(1), load: 60),
                                              .init(end: daysAgo(12), load: nil)], now: now)
        XCTAssertEqual(trend.thisWeek, 60, accuracy: 1e-9)
        XCTAssertNil(trend.previousWeeklyAverage)
        XCTAssertNil(trend.change)
        XCTAssertNil(trend.direction)
    }
}

final class VO2MaxEstimateTests: XCTestCase {

    // MARK: Published formulas

    func testACSMRunningCostOnTheFlat() {
        // 12 km/h = 200 m/min, level: 0.2 × 200 + 0.9 × 200 × 0 + 3.5 = 40 + 0 + 3.5 = 43.5
        XCTAssertEqual(VO2MaxEstimate.acsmRunningVO2(speedMetersPerMinute: 200, grade: 0),
                       43.5, accuracy: 1e-9)
    }

    func testACSMRunningCostUphill() {
        // 200 m/min at 5 %: 0.2 × 200 + 0.9 × 200 × 0.05 + 3.5 = 40 + 9 + 3.5 = 52.5
        XCTAssertEqual(VO2MaxEstimate.acsmRunningVO2(speedMetersPerMinute: 200, grade: 0.05),
                       52.5, accuracy: 1e-9)
        // 150 m/min at 2 %: 30 + 0.9 × 150 × 0.02 + 3.5 = 30 + 2.7 + 3.5 = 36.2
        XCTAssertEqual(VO2MaxEstimate.acsmRunningVO2(speedMetersPerMinute: 150, grade: 0.02),
                       36.2, accuracy: 1e-9)
    }

    func testTanakaMaxHR() {
        // 208 − 0.7 × 40 = 208 − 28 = 180;  208 − 0.7 × 25 = 208 − 17.5 = 190.5
        XCTAssertEqual(VO2MaxEstimate.tanakaMaxHR(age: 40), 180, accuracy: 1e-9)
        XCTAssertEqual(VO2MaxEstimate.tanakaMaxHR(age: 25), 190.5, accuracy: 1e-9)
    }

    func testSwainExtrapolation() {
        // VO₂ 43.5 at 160 bpm, rest 60, max 180:
        //   %HRR = (160 − 60) / (180 − 60) = 100 / 120
        //   VO₂max = 3.5 + (43.5 − 3.5) × 120 / 100 = 3.5 + 40 × 1.2 = 3.5 + 48 = 51.5
        XCTAssertEqual(VO2MaxEstimate.extrapolate(vo2: 43.5, heartRate: 160, restingHR: 60, maxHR: 180) ?? -1,
                       51.5, accuracy: 1e-9)
        // At max heart rate the extrapolation is the measured cost itself: 3.5 + 40 × 1 = 43.5
        XCTAssertEqual(VO2MaxEstimate.extrapolate(vo2: 43.5, heartRate: 180, restingHR: 60, maxHR: 180) ?? -1,
                       43.5, accuracy: 1e-9)
        // Undefined ratios refuse rather than divide by zero.
        XCTAssertNil(VO2MaxEstimate.extrapolate(vo2: 43.5, heartRate: 60, restingHR: 60, maxHR: 180))
        XCTAssertNil(VO2MaxEstimate.extrapolate(vo2: 43.5, heartRate: 160, restingHR: 60, maxHR: 60))
    }

    // MARK: Whole-run worked examples

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A synthetic run: GPS fix every 5 s, heart-rate reading every 10 s.
    private func syntheticRun(minutes: Double = 20,
                     sport: WorkoutSportType = .runningOutdoor,
                     speed: (Double) -> Double = { _ in 200 },        // m/min at minute t
                     heartRate: (Double) -> Int = { _ in 160 },       // bpm at minute t
                     altitude: ((Double) -> Double)? = nil,           // metres at distance d
                     verticalAccuracy: Double = 5,
                     gpsGap: ClosedRange<Double>? = nil,              // minutes with no fixes
                     age: Int? = 40,
                     restingHR: Double? = 60) -> VO2MaxEstimate.Input {
        let seconds = Int(minutes * 60)
        var route: [VO2MaxEstimate.RoutePoint] = []
        var distance = 0.0
        for s in stride(from: 0, through: seconds, by: 5) {
            let minute = Double(s) / 60
            if s > 0 { distance += speed(minute - 5.0 / 120) * 5 / 60 }
            if let gpsGap, gpsGap.contains(minute) { continue }
            route.append(.init(time: t0.addingTimeInterval(Double(s)), distance: distance,
                               altitude: altitude.map { $0(distance) },
                               verticalAccuracy: altitude == nil ? nil : verticalAccuracy))
        }
        let hr = stride(from: 0, to: seconds, by: 10).map {
            HRSample(bpm: heartRate(Double($0) / 60), start: t0.addingTimeInterval(Double($0)))
        }
        return .init(sport: sport, start: t0, end: t0.addingTimeInterval(Double(seconds)),
                     heartRate: hr, route: route, age: age, restingHR: restingHR)
    }

    private func estimate(_ input: VO2MaxEstimate.Input,
                          file: StaticString = #filePath, line: UInt = #line) -> VO2MaxEstimate.Estimate? {
        guard case .estimate(let e) = VO2MaxEstimate.estimate(input) else {
            XCTFail("expected an estimate, got \(VO2MaxEstimate.estimate(input))", file: file, line: line)
            return nil
        }
        return e
    }

    func testSteadyFlatRun() {
        // 20 min at 200 m/min and 160 bpm, age 40, resting 60, no altitude (⇒ flat):
        //   ACSM: 0.2 × 200 + 3.5 = 43.5
        //   max HR: Tanaka 180 (observed 160 is lower)
        //   VO₂max = 3.5 + 40 × (180 − 60) / (160 − 60) = 3.5 + 48 = 51.5
        //   The first steady 5-min segment after the 4-min warm-up: minutes 4–9.
        guard let e = estimate(syntheticRun()) else { return }
        XCTAssertEqual(e.vo2Max, 51.5, accuracy: 1e-6)
        XCTAssertEqual(e.segmentVO2, 43.5, accuracy: 1e-6)
        XCTAssertEqual(e.speed, 200, accuracy: 1e-6)
        XCTAssertEqual(e.grade, 0)
        XCTAssertFalse(e.gradeFromElevation)
        XCTAssertEqual(e.maxHR, 180, accuracy: 1e-9)
        XCTAssertEqual(e.maxHRSource, .ageFormula)
        XCTAssertEqual(e.segmentStart, t0.addingTimeInterval(4 * 60))
        XCTAssertEqual(e.segmentEnd, t0.addingTimeInterval(9 * 60))
    }

    func testReliableUphillUsesTheGrade() {
        // Altitude rises 5 m per 100 m with 5 m vertical accuracy ⇒ grade 0.05.
        //   ACSM: 0.2 × 200 + 0.9 × 200 × 0.05 + 3.5 = 40 + 9 + 3.5 = 52.5
        //   VO₂max = 3.5 + (52.5 − 3.5) × 120 / 100 = 3.5 + 49 × 1.2 = 3.5 + 58.8 = 62.3
        guard let e = estimate(syntheticRun(altitude: { 100 + 0.05 * $0 })) else { return }
        XCTAssertTrue(e.gradeFromElevation)
        XCTAssertEqual(e.grade, 0.05, accuracy: 1e-9)
        XCTAssertEqual(e.vo2Max, 62.3, accuracy: 1e-6)
    }

    func testUnreliableElevationIsTreatedAsFlat() {
        // Same 5 % slope, but 30 m vertical accuracy (> 10 m) ⇒ grade ignored ⇒ 51.5 as on the flat.
        guard let e = estimate(syntheticRun(altitude: { 100 + 0.05 * $0 }, verticalAccuracy: 30)) else { return }
        XCTAssertFalse(e.gradeFromElevation)
        XCTAssertEqual(e.vo2Max, 51.5, accuracy: 1e-6)
    }

    func testAHigherObservedMaxReplacesTheAgeFormula() {
        // Steady 160 bpm, but the last 2 minutes reach 190 (> Tanaka's 180). Those minutes are not
        // steady (spread 30 bpm), so the segment is still minutes 4–9 at 160; max becomes 190.
        //   VO₂max = 3.5 + 40 × (190 − 60) / (160 − 60) = 3.5 + 40 × 1.3 = 3.5 + 52 = 55.5
        guard let e = estimate(syntheticRun(heartRate: { $0 >= 18 ? 190 : 160 })) else { return }
        XCTAssertEqual(e.maxHRSource, .observed)
        XCTAssertEqual(e.maxHR, 190, accuracy: 1e-9)
        XCTAssertEqual(e.heartRate, 160, accuracy: 1e-9)
        XCTAssertEqual(e.vo2Max, 55.5, accuracy: 1e-6)
    }

    func testTheEvenestSegmentWins() {
        // Minutes 0–10 alternate 190/210 m/min (CV = 10/200 = 5 %, steady enough); from minute 10 a
        // dead-even 180 m/min (CV 0) — the even stretch is chosen.
        //   ACSM: 0.2 × 180 + 3.5 = 39.5;  VO₂max = 3.5 + 36 × 1.2 = 3.5 + 43.2 = 46.7
        let speed: (Double) -> Double = { t in t < 10 ? (Int(t) % 2 == 0 ? 190 : 210) : 180 }
        guard let e = estimate(syntheticRun(speed: speed)) else { return }
        XCTAssertEqual(e.speed, 180, accuracy: 1e-6)
        XCTAssertEqual(e.vo2Max, 46.7, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(e.segmentStart, t0.addingTimeInterval(10 * 60))
    }

    // MARK: Skip rules

    private func skipReason(_ input: VO2MaxEstimate.Input) -> VO2MaxEstimate.SkipReason? {
        if case .skipped(let reason) = VO2MaxEstimate.estimate(input) { return reason }
        return nil
    }

    func testOnlyOutdoorRunsQualify() {
        XCTAssertEqual(skipReason(syntheticRun(sport: .runningIndoor)), .notAnOutdoorRun)
        XCTAssertEqual(skipReason(syntheticRun(sport: .walkingOutdoor)), .notAnOutdoorRun)
        XCTAssertEqual(skipReason(syntheticRun(sport: .cyclingOutdoor)), .notAnOutdoorRun)
    }

    func testRunsUnderTenMinutesAreSkipped() {
        // 9 min 55 s < 10 min.
        XCTAssertEqual(skipReason(syntheticRun(minutes: 9 + 55.0 / 60)), .tooShort)
        // Exactly 10 min qualifies on duration (4 warm-up + 5 segment fits).
        XCTAssertNotNil(estimate(syntheticRun(minutes: 10)))
    }

    func testMissingInputsAreSkippedNotDefaulted() {
        var noGPS = syntheticRun()
        noGPS = .init(sport: noGPS.sport, start: noGPS.start, end: noGPS.end,
                      heartRate: noGPS.heartRate, route: [], age: 40, restingHR: 60)
        XCTAssertEqual(skipReason(noGPS), .noGPS)

        var noHR = syntheticRun()
        noHR = .init(sport: noHR.sport, start: noHR.start, end: noHR.end,
                     heartRate: [], route: noHR.route, age: 40, restingHR: 60)
        XCTAssertEqual(skipReason(noHR), .noHeartRate)

        XCTAssertEqual(skipReason(syntheticRun(age: nil)), .noAge)
        XCTAssertEqual(skipReason(syntheticRun(restingHR: nil)), .noRestingHR)
    }

    func testUnevenPaceHasNoSteadySegment() {
        // Alternating 150 / 250 m/min: mean 200, SD 50 ⇒ CV 25 % > 10 % in every window.
        XCTAssertEqual(skipReason(syntheticRun(speed: { Int($0) % 2 == 0 ? 150 : 250 })), .noSteadySegment)
    }

    func testUnsteadyHeartRateHasNoSteadySegment() {
        // Heart rate alternating 140 / 160 by minute: spread 20 bpm > 10 in every window.
        XCTAssertEqual(skipReason(syntheticRun(heartRate: { Int($0) % 2 == 0 ? 140 : 160 })), .noSteadySegment)
    }

    func testAGPSGapIsNeverBridged() {
        // 12-minute run with no fixes from minute 3 to minute 11: no window after the warm-up has
        // GPS on every minute edge.
        XCTAssertEqual(skipReason(syntheticRun(minutes: 12, gpsGap: 3 ... 11)), .noSteadySegment)
    }

    func testDownhillIsNotEstimated() {
        // Reliable −5 % grade: the ACSM running equation is for level and uphill running only.
        XCTAssertEqual(skipReason(syntheticRun(altitude: { 500 - 0.05 * $0 })), .noSteadySegment)
    }

    func testTooSlowForTheRunningEquation() {
        // 70 m/min is a walk, below the 80 m/min floor of the running equation.
        XCTAssertEqual(skipReason(syntheticRun(speed: { _ in 70 })), .noSteadySegment)
    }

    func testEasyRunIsTooLowToExtrapolate() {
        // 95 bpm with rest 60, max 180: %HRR = 35 / 120 = 29 % < 50 %.
        XCTAssertEqual(skipReason(syntheticRun(heartRate: { _ in 95 })), .intensityTooLow)
    }

    func testImplausibleResultIsDiscarded() {
        // 400 m/min at exactly 50 % HRR (120 bpm): ACSM 0.2 × 400 + 3.5 = 83.5;
        //   VO₂max = 3.5 + 80 × 120 / 60 = 3.5 + 160 = 163.5 > 90 ⇒ discarded.
        XCTAssertEqual(skipReason(syntheticRun(speed: { _ in 400 }, heartRate: { _ in 120 })), .implausible)
    }

    // MARK: Resting HR input

    func testRestingHRIsTheMedianOfTheLastSevenNights() {
        let cal = Calendar(identifier: .gregorian)
        let runDay = cal.startOfDay(for: t0)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: runDay)! }
        // Eight nights 50…57 bpm (oldest first), the run on the last one, one night AFTER the run.
        // The last seven on or before the run day are 51…57 → median 54. The later night is ignored.
        var daily = (0 ..< 8).map { RestingHR.DailyValue(day: day($0 - 7), bpm: Double(50 + $0)) }
        daily.append(RestingHR.DailyValue(day: day(1), bpm: 99))
        XCTAssertEqual(VO2MaxEstimate.restingHR(daily: daily, runStart: t0, calendar: cal) ?? -1,
                       54, accuracy: 1e-9)

        // Four nights 50, 52, 58, 60 → median (52 + 58) ÷ 2 = 55.
        let four = [50.0, 52, 58, 60].enumerated().map {
            RestingHR.DailyValue(day: day(-$0.offset), bpm: $0.element)
        }
        XCTAssertEqual(VO2MaxEstimate.restingHR(daily: four, runStart: t0, calendar: cal) ?? -1,
                       55, accuracy: 1e-9)

        // Two nights is not enough.
        XCTAssertNil(VO2MaxEstimate.restingHR(daily: Array(four.prefix(2)), runStart: t0, calendar: cal))
    }
}
