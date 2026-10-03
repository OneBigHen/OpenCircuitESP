import XCTest
@testable import OpenCircuitKit

// DailyStrain (#216): stored heart rate → a 1 Hz series → `Strain.calculate`. Pins the expansion
// rules (point readings hold until the next one, capped at one epoch; overlaps go to the earlier
// reading; the window clips) and the no-data / too-little-data states the Today tile shows.
final class DailyStrainTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var window: DateInterval { DateInterval(start: t0, duration: 24 * 3600) }

    /// Point readings every `step` seconds from `t0 + offset`.
    private func points(_ bpm: Int, count: Int, every step: TimeInterval, offset: TimeInterval = 0) -> [HRSample] {
        (0..<count).map { HRSample(bpm: bpm, start: t0.addingTimeInterval(offset + Double($0) * step)) }
    }

    // MARK: Expansion

    func testNoSamplesIsNoData() {
        let r = DailyStrain.reading(hr: [], window: window, age: 30, restingHR: 60)
        XCTAssertNil(r.strain)
        XCTAssertEqual(r.coveredSeconds, 0)
        XCTAssertTrue(r.hasNoData)
        XCTAssertNil(r.latestSampleAt)
        XCTAssertNil(r.gaugeFraction)
        XCTAssertNil(r.band)
    }

    func testRingEpochPointsHoldUntilTheNextReading() {
        // 24 readings 150 s apart = one hour; the last one holds for one epoch.
        let bpms = DailyStrain.perSecondBPMs(points(65, count: 24, every: 150), window: window)
        XCTAssertEqual(bpms.count, 3600)
    }

    func testStrapMinutePointsCoverOneMinuteEach() {
        let bpms = DailyStrain.perSecondBPMs(points(70, count: 10, every: 60), window: window)
        // 9 gaps of 60 s, then the last reading's one-epoch cap.
        XCTAssertEqual(bpms.count, 9 * 60 + 150)
    }

    func testAGapLongerThanAnEpochIsNotFilled() {
        let hr = [HRSample(bpm: 80, start: t0), HRSample(bpm: 80, start: t0.addingTimeInterval(3600))]
        XCTAssertEqual(DailyStrain.perSecondBPMs(hr, window: window).count, 300)
    }

    func testOverlapGoesToTheEarlierReading() {
        // A real 5-minute span, then a live spot read inside it: the spot read adds no time.
        let hr = [HRSample(bpm: 100, start: t0, end: t0.addingTimeInterval(300)),
                  HRSample(bpm: 150, start: t0.addingTimeInterval(60))]
        let bpms = DailyStrain.perSecondBPMs(hr, window: window)
        XCTAssertEqual(bpms.count, 300)
        XCTAssertEqual(Set(bpms), [100])
    }

    func testWindowClipsBothEnds() {
        let hr = [HRSample(bpm: 90, start: t0.addingTimeInterval(-100), end: t0.addingTimeInterval(100)),
                  HRSample(bpm: 90, start: window.end.addingTimeInterval(-50))]
        // 100 s after the start, and the last 50 s of the window (its cap runs past the end).
        XCTAssertEqual(DailyStrain.perSecondBPMs(hr, window: window).count, 150)
    }

    func testImplausibleReadingsAreDropped() {
        let hr = [HRSample(bpm: 4, start: t0), HRSample(bpm: 250, start: t0.addingTimeInterval(10))]
        XCTAssertEqual(DailyStrain.perSecondBPMs(hr, window: window).count, 0)
    }

    // MARK: Scoring

    func testTooLittleHeartRateHasNoScoreButKeepsCoverage() {
        // Three ring epochs = 450 s, under the 10-minute gate.
        let r = DailyStrain.reading(hr: points(120, count: 3, every: 150), window: window, age: 30, restingHR: 60)
        XCTAssertNil(r.strain)
        XCTAssertEqual(r.coveredSeconds, 450)
        XCTAssertFalse(r.hasNoData)
        XCTAssertLessThan(r.coveredSeconds, DailyStrain.minCoveredSeconds)
    }

    func testNoRestingHRHasNoScore() {
        let r = DailyStrain.reading(hr: points(120, count: 30, every: 60), window: window, age: 30, restingHR: nil)
        XCTAssertNil(r.strain)
        XCTAssertNil(r.restingHR)
        XCTAssertGreaterThan(r.coveredSeconds, DailyStrain.minCoveredSeconds)
    }

    func testRestingDayScoresZero() {
        let r = DailyStrain.reading(hr: points(62, count: 96, every: 150), window: window, age: 30, restingHR: 60)
        XCTAssertEqual(r.strain, 0.0)
        XCTAssertEqual(r.gaugeFraction, 0.0)
        XCTAssertEqual(r.band, .light)
    }

    func testMatchesStrainCalculateOnTheSameOneHertzSeries() {
        // 30 strap minutes at 170 bpm: 29 × 60 s + the last reading's 150 s cap.
        let hr = points(170, count: 30, every: 60)
        let r = DailyStrain.reading(hr: hr, window: window, age: 30, restingHR: 60)
        let expected = Strain(maxHR: 190, restingHR: 60)
            .calculate(bpms: Array(repeating: 170, count: 29 * 60 + 150), sampleSeconds: 1)
        XCTAssertNotNil(expected)
        XCTAssertEqual(r.strain, expected)
        XCTAssertEqual(r.maxHR, 190)
        XCTAssertEqual(r.restingHR, 60)
        XCTAssertEqual(r.latestSampleAt, t0.addingTimeInterval(29 * 60))
    }

    func testMaxHRUsesTheAgeFormula() {
        XCTAssertEqual(DailyStrain.reading(hr: [], window: window, age: 45, restingHR: 60).maxHR, 175)
    }

    // MARK: Gauge and bands

    func testBands() {
        XCTAssertEqual(DailyStrain.Band(strain: 0), .light)
        XCTAssertEqual(DailyStrain.Band(strain: 9.99), .light)
        XCTAssertEqual(DailyStrain.Band(strain: 10), .moderate)
        XCTAssertEqual(DailyStrain.Band(strain: 14), .high)
        XCTAssertEqual(DailyStrain.Band(strain: 18), .allOut)
        XCTAssertEqual(DailyStrain.Band(strain: 21), .allOut)
    }

    func testGaugeFractionIsOnTheTwentyOneScale() {
        let r = DailyStrain.Reading(strain: 10.5, coveredSeconds: 3600, latestSampleAt: t0, maxHR: 190, restingHR: 60)
        XCTAssertEqual(r.gaugeFraction ?? -1, 0.5, accuracy: 1e-9)
    }
}
