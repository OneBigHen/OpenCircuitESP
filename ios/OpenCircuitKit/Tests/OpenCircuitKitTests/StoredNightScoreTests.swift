import XCTest
@testable import OpenCircuitKit

// #246 / decision 48: scoring a night that is already stored, from stored-row inputs. The point of
// these is that the number is the RING's number — the same composite over the same factors — so a
// strap night and a ring night of identical shape are never scored on two different formulas.
// Every value here is synthetic.

final class StoredNightScoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_789_862_400)   // 2026-09-20T00:00:00Z

    /// A strap-shaped night: stage segments only, NO `.inBed` segment (the strap's record has none,
    /// `HelioSleepSelection.Night`). 6 h asleep from 23:00 the evening before.
    private func night() -> [SleepSegment] {
        let bed = t0.addingTimeInterval(-3600)
        return [
            SleepSegment(start: bed, end: bed.addingTimeInterval(2 * 3600), stage: .asleepCore),
            SleepSegment(start: bed.addingTimeInterval(2 * 3600), end: bed.addingTimeInterval(3 * 3600), stage: .asleepDeep),
            SleepSegment(start: bed.addingTimeInterval(3 * 3600), end: bed.addingTimeInterval(3.5 * 3600), stage: .awake),
            SleepSegment(start: bed.addingTimeInterval(3.5 * 3600), end: bed.addingTimeInterval(5 * 3600), stage: .asleepREM),
            SleepSegment(start: bed.addingTimeInterval(5 * 3600), end: bed.addingTimeInterval(6.5 * 3600), stage: .asleepCore),
        ]
    }

    /// One HR reading every 5 minutes across the night.
    private func heartRate(_ segments: [SleepSegment], bpm: Int = 54) -> [HRSample] {
        guard let from = segments.first?.start, let to = segments.last?.end else { return [] }
        return stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 300).map {
            let t = Date(timeIntervalSince1970: $0)
            return HRSample(bpm: bpm, start: t, end: t)
        }
    }

    private func priorNights(_ count: Int, celsius: Double) -> [SkinTempBaseline.NightlyTemp] {
        (1...max(count, 1)).prefix(count).map {
            SkinTempBaseline.NightlyTemp(night: t0.addingTimeInterval(TimeInterval(-86_400 * $0)), celsius: celsius)
        }
    }

    // MARK: It is the ring's own composite

    /// THE LOAD-BEARING TEST. The expected value is built by inlining exactly what
    /// `RingSession.computeSleepExtras` does, so if either side grows a factor or an argument this
    /// fails rather than letting the strap and the ring drift onto two formulas.
    func testItMatchesTheRingsCompositeForTheSameInputs() {
        let segments = night()
        let hr = heartRate(segments)
        let input = StoredNightScore.Input(
            segments: segments, heartRate: hr, rmssd: [42, 44, 46],
            skinTempC: 34.2, priorNights: priorNights(5, celsius: 33.6))

        let summary = SleepStaging.summary(segments)
        let expectedRestingHR = RestingHR.value(hr: hr, sleep: segments)
        let expectedBaseline = SkinTempBaseline.baseline(priorNights: priorNights(5, celsius: 33.6))
        let expectedOffset = 34.2 - XCTUnwrap_(expectedBaseline)
        let expected = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem,
            restingHR: expectedRestingHR, tempOffsetC: expectedOffset)).score

        let scores = StoredNightScore.scores(input)
        XCTAssertEqual(scores.sleepScore, expected)
        XCTAssertEqual(scores.restingHR, expectedRestingHR)
        XCTAssertEqual(scores.tempOffsetC!, expectedOffset, accuracy: 1e-9)
        XCTAssertEqual(scores.stressScore, SleepStress.overnightScore(rmssd: [42, 44, 46]))
    }

    /// A ring-shaped night (one `.inBed` segment around the stages) scores identically to the same
    /// staging handed to the composite directly — the strap's missing `.inBed` span is handled by
    /// `SleepStaging.summary`'s own fallback, not by a second rule here.
    func testARingShapedNightWithAnInBedSegmentScoresOnTheSameFormula() {
        var segments = night()
        segments.insert(SleepSegment(start: segments.first!.start, end: segments.last!.end, stage: .inBed), at: 0)
        let summary = SleepStaging.summary(segments)
        let expected = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem)).score
        XCTAssertEqual(StoredNightScore.scores(.init(segments: segments)).sleepScore, expected)
    }

    // MARK: The optional factors drop out rather than being invented

    func testTheTempOffsetIsNilWithoutABaseline() {
        let segments = night()
        // Below `minBaselineNights`: a mean exists, but there is no "usual" to compare it with yet.
        let tooFew = StoredNightScore.scores(.init(segments: segments, skinTempC: 34.2,
                                                   priorNights: priorNights(SkinTempBaseline.minBaselineNights - 1, celsius: 33.6)))
        XCTAssertNil(tooFew.tempOffsetC)
        XCTAssertNotNil(tooFew.sleepScore, "the night still scores on the factors it has")

        // No prior nights at all (a device's first night, decision 29).
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments, skinTempC: 34.2)).tempOffsetC)
        // A baseline but no nightly mean for this night.
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments, skinTempC: nil,
                                                   priorNights: priorNights(5, celsius: 33.6))).tempOffsetC)
        // A withheld/absent mean arrives as 0 on the stored row; 0 °C is not a temperature.
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments, skinTempC: 0,
                                                   priorNights: priorNights(5, celsius: 33.6))).tempOffsetC)
    }

    /// The temperature factor genuinely moves the score, so "the offset is nil" is a real
    /// difference and not an untested branch.
    func testTheOffsetChangesTheScore() {
        let segments = night()
        let without = StoredNightScore.scores(.init(segments: segments, skinTempC: 34.2))
        let with = StoredNightScore.scores(.init(segments: segments, skinTempC: 36.4,
                                                 priorNights: priorNights(5, celsius: 33.6)))
        XCTAssertNotNil(with.tempOffsetC)
        XCTAssertNotEqual(without.sleepScore, with.sleepScore)
    }

    func testTheStressScoreIsNilWithNoHRV() {
        let segments = night()
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments)).stressScore)
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments, rmssd: [])).stressScore)
        // Non-positive values are no reading, not a reading of 0 (`SleepStress.overnightScore`).
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments, rmssd: [0, 0])).stressScore)
        XCTAssertNotNil(StoredNightScore.scores(.init(segments: segments, rmssd: [40])).stressScore)
    }

    func testTheRestingHRIsNilWithNoUsableHeartRate() {
        let segments = night()
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments)).restingHR)
        // Physiologically impossible readings are dropped by `RestingHR.value`, so they can never
        // become the HR factor.
        XCTAssertNil(StoredNightScore.scores(.init(segments: segments, heartRate: heartRate(segments, bpm: 4))).restingHR)
    }

    // MARK: A computed 0, and a night that cannot be described

    func testAComputedZeroIsReportedAsNoScore() {
        // One second of core sleep inside an hour of awake-in-bed: time asleep rounds to nothing,
        // there is no deep or REM, efficiency is ~0 and a full hour awake floors the last factor, so
        // the composite is 0 — and 0 is the stored column's "never computed" sentinel, so it must be
        // reported as no score rather than written back.
        let s = [
            SleepSegment(start: t0, end: t0.addingTimeInterval(1), stage: .asleepCore),
            SleepSegment(start: t0.addingTimeInterval(1), end: t0.addingTimeInterval(3601), stage: .awake),
        ]
        let summary = SleepStaging.summary(s)
        XCTAssertEqual(SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem)).score, 0,
            "fixture no longer scores 0; the assertion below would stop testing anything")
        XCTAssertNil(StoredNightScore.scores(.init(segments: s)).sleepScore)
    }

    func testANightWithNoAsleepTimeHasNoScoreButKeepsItsRecovery() {
        let awakeOnly = [SleepSegment(start: t0, end: t0.addingTimeInterval(3600), stage: .awake)]
        let scores = StoredNightScore.scores(.init(segments: awakeOnly, rmssd: [50]))
        XCTAssertNil(scores.sleepScore, "no asleep time is not a night we can score")
        XCTAssertNotNil(scores.stressScore, "its HRV is still a recovery reading")
    }

    func testNoSegmentsAtAllScoresNothing() {
        let scores = StoredNightScore.scores(.init(segments: []))
        XCTAssertNil(scores.sleepScore)
        XCTAssertNil(scores.stressScore)
        XCTAssertNil(scores.restingHR)
        XCTAssertNil(scores.tempOffsetC)
    }

    /// Scoring the same night twice gives the same answer — the store-time path and the repair pass
    /// both go through here, and a drifting number would make the repair look like a restatement.
    func testItIsDeterministic() {
        let segments = night()
        let input = StoredNightScore.Input(segments: segments, heartRate: heartRate(segments),
                                           rmssd: [42, 44, 46], skinTempC: 34.2,
                                           priorNights: priorNights(5, celsius: 33.6))
        XCTAssertEqual(StoredNightScore.scores(input), StoredNightScore.scores(input))
    }

    /// Local `XCTUnwrap` substitute usable outside a `throws` test body.
    private func XCTUnwrap_(_ value: Double?) -> Double {
        guard let value else { XCTFail("expected a baseline"); return 0 }
        return value
    }
}
