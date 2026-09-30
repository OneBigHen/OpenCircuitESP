import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for the Today metric tiles (#216): which day's value a tile shows, how it
/// labels freshness, that steps compare the last COMPLETE day, that the labelled usual range is the
/// same band the verdict uses, and that missing data reads as missing. No real health values.
final class TodayTilesTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-09-30 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_762_400)
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
    }

    private func tile(_ m: TodayTile.Metric, _ points: [TrendsEngine.DailyPoint],
                      restingHR: [RestingHR.DailyValue] = [], window: Int = 14) -> TodayTile {
        TodayTiles.build(m, points: points, restingHR: restingHR, tempUnit: .celsius,
                         windowDays: window, now: now, calendar: cal)
    }

    /// Nights keyed on their WAKE day (`SleepNightKey`), last night = today's key.
    private func nights(_ hrv: [Double], endingOffset: Int = 0) -> [TrendsEngine.DailyPoint] {
        hrv.enumerated().map { i, v in
            TrendsEngine.DailyPoint(date: day(endingOffset - (hrv.count - 1 - i)), sleepHRVAvg: v)
        }
    }

    func testNoDataSaysSo() {
        let t = tile(.hrv, [])
        XCTAssertNil(t.valueText)
        XCTAssertEqual(t.rangeText, "No data yet")
        XCTAssertNil(t.deltaText)
        XCTAssertNil(t.freshnessText(now: now, calendar: cal))
        XCTAssertEqual(t.values.count, 14)
        XCTAssertTrue(t.values.allSatisfy { $0 == nil })
    }

    func testLastNightIsFreshAndBandMatchesVerdict() {
        let t = tile(.hrv, nights([50, 50, 50, 50, 50, 58]))
        XCTAssertEqual(t.valueText, "58")
        XCTAssertEqual(t.freshnessText(now: now, calendar: cal), "last night")
        XCTAssertFalse(t.isStale(now: now, calendar: cal))
        XCTAssertEqual(t.trend?.direction, .above)
        XCTAssertEqual(t.deltaText, "+8 ms vs usual")
        // Floor 3 ms, flat baseline → the band is exactly 47–53, the range the label names.
        XCTAssertEqual(t.rangeText, "Usual 47–53 ms")
        XCTAssertEqual(t.values.last!, 58)
    }

    func testANightThatEndedYesterdayIsStale() {
        let t = tile(.hrv, nights([50, 50, 50, 50, 50], endingOffset: -1))
        XCTAssertTrue(t.isStale(now: now, calendar: cal))
        XCTAssertTrue(t.freshnessText(now: now, calendar: cal)?.hasPrefix("night to") == true)
        XCTAssertNil(t.values.last!, "no value for today's key")
    }

    func testThinBaselineIsLearning() {
        let t = tile(.hrv, nights([50, 52, 58]))
        XCTAssertNil(t.trend?.direction)
        XCTAssertNil(t.deltaText)
        XCTAssertEqual(t.rangeText, "Learning your usual · 2/4 days")
    }

    func testGapsStayGaps() {
        var pts = nights([50, 50, 50, 50, 50, 50])
        pts.remove(at: 2)
        let t = tile(.hrv, pts)
        XCTAssertEqual(t.values.suffix(6).filter { $0 == nil }.count, 1)
    }

    func testStepsHeadlineIsTodayButTrendIsYesterday() {
        let pts = (0..<8).map { i -> TrendsEngine.DailyPoint in
            let offset = i - 7   // −7 … 0 (today)
            return TrendsEngine.DailyPoint(date: day(offset), steps: offset == 0 ? 1_200 : (offset == -1 ? 12_000 : 8_000))
        }
        let t = tile(.steps, pts)
        XCTAssertEqual(t.valueText, 1_200.formatted(.number))
        XCTAssertEqual(t.freshnessText(now: now, calendar: cal), "today")
        XCTAssertTrue(t.trendIsYesterday)
        XCTAssertEqual(t.trend?.direction, .above)
        XCTAssertEqual(t.deltaText, "Yesterday +" + 4_000.formatted(.number) + " vs usual")
        XCTAssertNil(t.values.last!, "today's partial total is not plotted")
        XCTAssertEqual(t.values[t.values.count - 2], 12_000)
    }

    func testRestingHRUsesTheDerivedSeries() {
        let rhr = (0..<6).map { RestingHR.DailyValue(day: day($0 - 5), bpm: $0 == 5 ? 58 : 52) }
        let t = tile(.restingHR, [], restingHR: rhr)
        XCTAssertEqual(t.valueText, "58")
        XCTAssertEqual(t.freshnessText(now: now, calendar: cal), "today")
        XCTAssertEqual(t.trend?.direction, .above)
    }

    func testThirtyDayWindow() {
        let t = tile(.hrv, nights(Array(repeating: 50, count: 30)), window: 30)
        XCTAssertEqual(t.values.count, 30)
        XCTAssertEqual(t.values.compactMap { $0 }.count, 30)
        XCTAssertEqual(t.trend?.baselineDays, 29)
    }

    func testSynthesisIgnoresStaleTiles() {
        let tiles = [tile(.hrv, nights([50, 50, 50, 50, 50, 40], endingOffset: -2))]
        var trends = TrendsData()
        trends.newestSampleAt = now.addingTimeInterval(-3600)
        let input = TodaySynthesis.input(trends: trends, tiles: tiles, readiness: nil, lastSyncAt: nil, now: now)
        XCTAssertNil(input.hrv, "a two-day-old night must not be reported as today's HRV")
    }

    func testSynthesisNeverClaimsNoDataAfterASync() {
        let input = TodaySynthesis.input(trends: TrendsData(), tiles: [], readiness: nil,
                                         lastSyncAt: now.addingTimeInterval(-86_400 * 20), now: now)
        XCTAssertEqual(TodaySynthesis.sentence(input),
                       "Your newest ring data is more than two weeks old, so sync your ring to bring today's summary up to date.")
    }
}
