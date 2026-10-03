import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for the Today Strain tile's words (#216): a score reads as a number on the
/// 0–21 scale with its band, and every can't-score state says why in words, never as a 0. Wording is
/// device-neutral: ring and Helio Strap wearers both see it.
final class StrainTileTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ strain: Double?, covered: Int, rhr: Int? = 60) -> DailyStrain.Reading {
        DailyStrain.Reading(strain: strain, coveredSeconds: covered,
                            latestSampleAt: covered > 0 ? at : nil, maxHR: 190, restingHR: rhr)
    }

    func testScoreShowsValueBandAndScale() {
        let r = reading(11.26, covered: 7200)
        XCTAssertEqual(StrainTileText.value(r), "11.3")
        XCTAssertEqual(StrainTileText.bandLine(r), "Moderate · so far today")
        XCTAssertEqual(StrainTileText.status(r), "Heart-rate effort · 0–21 scale")
        XCTAssertNotNil(StrainTileText.freshness(r))
    }

    func testBeforeTheFirstLoadAndWithNoHeartRate() {
        for r in [nil, reading(nil, covered: 0)] {
            XCTAssertNil(StrainTileText.value(r))
            XCTAssertNil(StrainTileText.bandLine(r))
            XCTAssertEqual(StrainTileText.status(r), "No heart rate yet today")
        }
    }

    func testTooLittleHeartRateSaysHowMuchMore() {
        let r = reading(nil, covered: 450)
        XCTAssertNil(StrainTileText.value(r))
        XCTAssertEqual(StrainTileText.status(r), "Needs 10 min of heart rate · 7 min so far")
    }

    func testNoRestingHeartRate() {
        XCTAssertEqual(StrainTileText.status(reading(nil, covered: 3600, rhr: nil)),
                       "Needs a resting heart rate first")
    }

    func testWordingNeverNamesADevice() {
        let states: [DailyStrain.Reading?] = [nil, reading(nil, covered: 0), reading(nil, covered: 450),
                                              reading(nil, covered: 3600, rhr: nil), reading(19, covered: 9000)]
        let words = states.flatMap { [StrainTileText.status($0), StrainTileText.accessibilityLabel($0)] }
            + StrainInfoSheet.bullets
        for w in words {
            XCTAssertFalse(w.lowercased().contains("ring"), w)
            XCTAssertFalse(w.lowercased().contains("strap"), w)
        }
    }
}
