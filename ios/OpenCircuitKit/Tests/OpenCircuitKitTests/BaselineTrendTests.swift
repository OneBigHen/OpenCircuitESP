import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the Today tiles' baseline comparison (#216): the latest daily value vs
/// the mean of the prior days, with a deadband, and an honest nil direction while the baseline is thin.
final class BaselineTrendTests: XCTestCase {

    private let day0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func series(_ values: [Double]) -> [BaselineTrend.Point] {
        values.enumerated().map { i, v in .init(date: day0.addingTimeInterval(Double(i) * 86_400), value: v) }
    }

    func testEmptySeriesIsNil() {
        XCTAssertNil(BaselineTrend.evaluate([], minAbsoluteDelta: 1))
    }

    func testSinglePointHasNoBaseline() {
        let r = BaselineTrend.evaluate(series([50]), minAbsoluteDelta: 1)
        XCTAssertEqual(r?.latest.value, 50)
        XCTAssertNil(r?.baselineMean)
        XCTAssertEqual(r?.baselineDays, 0)
        XCTAssertNil(r?.direction)
        XCTAssertNil(r?.delta)
    }

    func testThinBaselineReportsMeanButNoDirection() {
        // 3 prior days < default 4: the mean is shown, the direction is withheld.
        let r = BaselineTrend.evaluate(series([40, 42, 44, 80]), minAbsoluteDelta: 1)
        XCTAssertEqual(r?.baselineDays, 3)
        XCTAssertEqual(r?.baselineMean ?? 0, 42, accuracy: 1e-9)
        XCTAssertNil(r?.direction)
    }

    func testAboveBelowWithin() {
        let flat: [Double] = [50, 50, 50, 50, 50]
        XCTAssertEqual(BaselineTrend.evaluate(series(flat + [55]), minAbsoluteDelta: 3)?.direction, .above)
        XCTAssertEqual(BaselineTrend.evaluate(series(flat + [45]), minAbsoluteDelta: 3)?.direction, .below)
        XCTAssertEqual(BaselineTrend.evaluate(series(flat + [52]), minAbsoluteDelta: 3)?.direction, .within)
        // Exactly on the band edge is still within.
        XCTAssertEqual(BaselineTrend.evaluate(series(flat + [53]), minAbsoluteDelta: 3)?.direction, .within)
    }

    func testUsualRangeIsTheDeadband() {
        let r = BaselineTrend.evaluate(series([50, 50, 50, 50, 52]), minAbsoluteDelta: 3)
        XCTAssertEqual(r?.bandHalfWidth, 3)
        XCTAssertEqual(r?.usualRange, 47...53)
        XCTAssertTrue(r?.usualRange?.contains(52) == true)
        XCTAssertEqual(r?.direction, .within)
        // Thin baseline: no band claimed.
        XCTAssertNil(BaselineTrend.evaluate(series([50, 50, 52]), minAbsoluteDelta: 3)?.usualRange)
    }

    func testNoisyBaselineWidensTheBand() {
        // Mean 50, population SD 10 → band = max(1, 5) = 5. A +4 move is within; +6 is above.
        let noisy: [Double] = [40, 60, 40, 60]
        XCTAssertEqual(BaselineTrend.evaluate(series(noisy + [54]), minAbsoluteDelta: 1)?.direction, .within)
        XCTAssertEqual(BaselineTrend.evaluate(series(noisy + [56]), minAbsoluteDelta: 1)?.direction, .above)
        XCTAssertEqual(BaselineTrend.evaluate(series(noisy + [56]), minAbsoluteDelta: 1)?.bandHalfWidth ?? 0, 5, accuracy: 1e-9)
    }

    func testOrderIndependentAndNonFiniteDropped() {
        var pts = series([50, 50, 50, 50, 60])
        pts.reverse()
        pts.append(.init(date: day0.addingTimeInterval(10 * 86_400), value: .nan))
        let r = BaselineTrend.evaluate(pts, minAbsoluteDelta: 2)
        XCTAssertEqual(r?.latest.value, 60)
        XCTAssertEqual(r?.direction, .above)
        XCTAssertEqual(r?.delta ?? 0, 10, accuracy: 1e-9)
    }
}
