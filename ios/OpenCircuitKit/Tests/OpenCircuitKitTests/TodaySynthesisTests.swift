import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the Today synthesis line (#216). Asserts the exact sentences, because
/// the copy IS the behaviour: each rule, the rule precedence, and the honest degradations when
/// data is missing, stale, or readiness can't be scored.
final class TodaySynthesisTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var fresh: Date { now.addingTimeInterval(-2 * 3600) }

    private func say(_ readiness: TodaySynthesis.Readiness = .pending,
                     hrv: BaselineTrend.Direction? = nil,
                     rhr: BaselineTrend.Direction? = nil,
                     temp: BaselineTrend.Direction? = nil,
                     sleep: Int? = nil, usualSleep: Double? = nil,
                     newest: Date?? = .none) -> String {
        TodaySynthesis.sentence(.init(readiness: readiness, hrv: hrv, restingHR: rhr, skinTemp: temp,
                                      lastNightSleepMinutes: sleep, usualSleepMinutes: usualSleep,
                                      newestDataAt: newest ?? fresh, now: now))
    }

    // MARK: Missing / stale data

    func testNoDataAtAll() {
        XCTAssertEqual(say(.scored(score: 90, tier: .excellent, factorCount: 3), newest: .some(nil)),
                       "There's no ring data yet, so connect and sync your ring to see today's summary.")
    }

    func testStaleDataOverridesEverything() {
        XCTAssertEqual(say(.scored(score: 90, tier: .excellent, factorCount: 3), hrv: .above,
                           newest: now.addingTimeInterval(-40 * 3600)),
                       "Your newest ring data is over a day old, so sync your ring to bring today's summary up to date.")
        XCTAssertEqual(say(newest: now.addingTimeInterval(-3.5 * 86_400)),
                       "Your newest ring data is 3 days old, so sync your ring to bring today's summary up to date.")
    }

    func testThirtyFiveHoursIsNotStale() {
        XCTAssertEqual(say(newest: now.addingTimeInterval(-35 * 3600)), "Working out today's readiness.")
    }

    // MARK: Scored readiness

    func testExcellentWithPositive() {
        XCTAssertEqual(say(.scored(score: 88, tier: .excellent, factorCount: 3), hrv: .above, rhr: .within),
                       "Readiness is excellent at 88, and HRV is above your usual.")
    }

    func testGoodWithConcernUsesThough() {
        XCTAssertEqual(say(.scored(score: 74, tier: .good, factorCount: 3), hrv: .above, sleep: 320),
                       "Readiness is good at 74, though last night's sleep was short.")
    }

    func testGoodSteady() {
        XCTAssertEqual(say(.scored(score: 74, tier: .good, factorCount: 2), hrv: .within, rhr: .within),
                       "Readiness is good at 74, with HRV and resting heart rate in your usual range.")
        XCTAssertEqual(say(.scored(score: 74, tier: .good, factorCount: 2), rhr: .within),
                       "Readiness is good at 74, with resting heart rate in your usual range.")
    }

    func testGoodWithNothingElseKnown() {
        XCTAssertEqual(say(.scored(score: 70, tier: .good, factorCount: 3)), "Readiness is good at 70.")
    }

    func testSleepAloneIsDisclosed() {
        XCTAssertEqual(say(.scored(score: 81, tier: .good, factorCount: 1)),
                       "Readiness is good at 81 based on last night's sleep alone.")
    }

    func testNeedsImprovement() {
        XCTAssertEqual(say(.scored(score: 52, tier: .needsImprovement, factorCount: 3), hrv: .below),
                       "Readiness needs improvement at 52, and HRV is below your usual, so an easier day may help.")
        XCTAssertEqual(say(.scored(score: 52, tier: .needsImprovement, factorCount: 3), hrv: .above),
                       "Readiness needs improvement at 52, so an easier day may help.")
    }

    func testShortNightRelativeToUsual() {
        // 400 min is over 6 h, but 80 min under a 480-min usual → short.
        XCTAssertEqual(say(.scored(score: 75, tier: .good, factorCount: 3), sleep: 400, usualSleep: 480),
                       "Readiness is good at 75, though last night's sleep was short.")
        // 440 vs 480 is within the 60-min allowance → not short.
        XCTAssertEqual(say(.scored(score: 75, tier: .good, factorCount: 3), sleep: 440, usualSleep: 480),
                       "Readiness is good at 75.")
    }

    func testFeverPairTakesPrecedence() {
        XCTAssertEqual(say(.scored(score: 80, tier: .good, factorCount: 3), hrv: .above, rhr: .above, temp: .above),
                       "Readiness is good at 80, but skin temperature and resting heart rate are both above your usual, so take today gently.")
        XCTAssertEqual(say(rhr: .above, temp: .above),
                       "Skin temperature and resting heart rate are both above your usual, so take today gently.")
    }

    // MARK: No readiness

    func testNoNightSaysSyncHasntHappened() {
        XCTAssertEqual(say(.noNight), "Last night's sleep hasn't synced yet, so there's no readiness score.")
        XCTAssertEqual(say(.noNight, hrv: .below),
                       "Last night's sleep hasn't synced yet, so there's no readiness score, but HRV is below your usual.")
    }

    func testNoScoreNeverSuggestsSync() {
        let s = say(.noScore, hrv: .within)
        XCTAssertEqual(s, "Last night has no sleep score, so there's no readiness today, but HRV is in your usual range.")
        XCTAssertFalse(s.localizedCaseInsensitiveContains("sync"))
    }

    func testPendingFallsBackToVitals() {
        XCTAssertEqual(say(hrv: .above), "HRV is above your usual.")
        XCTAssertEqual(say(hrv: .within, rhr: .within), "HRV and resting heart rate are in your usual range.")
        XCTAssertEqual(say(), "Working out today's readiness.")
    }

    func testEverySentenceIsOneSentence() {
        let readinesses: [TodaySynthesis.Readiness] = [
            .pending, .noNight, .noScore,
            .scored(score: 90, tier: .excellent, factorCount: 3),
            .scored(score: 70, tier: .good, factorCount: 1),
            .scored(score: 40, tier: .needsImprovement, factorCount: 2),
        ]
        let dirs: [BaselineTrend.Direction?] = [nil, .above, .within, .below]
        for r in readinesses { for h in dirs { for rh in dirs { for t in dirs {
            let s = say(r, hrv: h, rhr: rh, temp: t, sleep: 300)
            XCTAssertTrue(s.hasSuffix("."), s)
            XCTAssertEqual(s.filter { $0 == "." }.count, 1, s)
            XCTAssertEqual(s.first.map { String($0) }, s.first.map { String($0).uppercased() }, s)
        } } } }
    }
}
