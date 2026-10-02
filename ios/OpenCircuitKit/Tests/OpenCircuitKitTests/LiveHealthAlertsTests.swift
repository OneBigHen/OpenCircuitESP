import XCTest
@testable import OpenCircuitKit

/// Unit tests for the pieces of decision 32 (#234). The end-to-end behaviour is pinned in
/// `LiveHealthAlertsScenarioTests`. SYNTHETIC-ONLY.
final class LiveHealthAlertsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func at(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: h, minute: m))!
    }
    private func hr(_ bpm: Int, _ h: Int, _ m: Int) -> HRSample { HRSample(bpm: bpm, start: at(h, m)) }

    /// Decision 37: 90 minutes, inclusive.
    func testTheFreshnessLimitIsNinetyMinutesInclusive() {
        XCTAssertEqual(LiveHealthAlerts.maxReadingAge, 90 * 60)
        XCTAssertTrue(LiveHealthAlerts.isFresh(end: at(10, 30), now: at(12, 0)))
        XCTAssertFalse(LiveHealthAlerts.isFresh(end: at(10, 30), now: at(12, 0).addingTimeInterval(1)))
        XCTAssertFalse(LiveHealthAlerts.isFresh(end: at(10, 29), now: at(12, 0)))
        XCTAssertTrue(LiveHealthAlerts.isFresh(end: at(13, 0), now: at(12, 0)), "a future end is clamped")
        XCTAssertEqual(LiveHealthAlerts.readingTime(end: at(13, 0), now: at(12, 0)), at(12, 0))
    }

    /// The fetch must reach back far enough to rebuild the run of the OLDEST fresh reading. If a
    /// later edit widens the freshness limit or a rule window without widening the context window,
    /// this fails here instead of silently dropping a run's early readings.
    func testTheContextWindowCoversTheFreshnessLimitPlusTheLongestRuleWindow() {
        let t = HealthAlertThresholds()
        let longestRuleWindow = [t.lowSpO2Window, t.lowSpO2MaxGap, t.elevatedSustained, t.elevatedMaxGap].max()!
        XCTAssertGreaterThanOrEqual(LiveHealthAlerts.contextWindow,
                                    LiveHealthAlerts.maxReadingAge + longestRuleWindow)
    }

    /// The rule governs exactly the three instant alerts, and none of the night-level, reminder or
    /// battery notifications.
    func testTheRuleCoversOnlyTheInstantAlerts() {
        XCTAssertEqual(LiveHealthAlerts.notificationSet, [.highHR, .lowSpO2, .elevatedHRInactive])
        XCTAssertTrue(LiveHealthAlerts.notificationSet.isDisjoint(with: TempFeverNotifications.notificationSet))
        XCTAssertTrue(LiveHealthAlerts.notificationSet.isDisjoint(with: HeadacheSignsNotifications.notificationSet))
        XCTAssertTrue(LiveHealthAlerts.notificationSet.isDisjoint(with: [
            .sedentaryReminder, .wearReminder, .bedtimeReminder, .chargingComplete]))
    }

    /// Only alerts the gate let through claim a watermark.
    func testOnlyFiredAlertsClaimAWatermark() {
        let live = [
            LiveHealthAlert(hit: HealthAlertHit(notification: .highHR, value: 140, time: at(11, 50)),
                            watermark: at(11, 51)),
            LiveHealthAlert(hit: HealthAlertHit(notification: .lowSpO2, value: 88, time: at(11, 40)),
                            watermark: at(11, 45)),
        ]
        XCTAssertEqual(LiveHealthAlerts.watermarks(fired: [.lowSpO2], from: live), [.lowSpO2: at(11, 45)])
        XCTAssertEqual(LiveHealthAlerts.watermarks(fired: [], from: live), [:])
    }

    /// The watermark covers EVERY reading a hit drew on, not just the one it names: the worst
    /// reading is named, the latest one is the mark.
    func testTheWatermarkIsTheLatestEligibleReadingNotTheNamedOne() {
        let alerts = LiveHealthAlerts.evaluate(
            hr: [hr(150, 11, 40), hr(125, 11, 50)], spo2: [], inactiveHR: [],
            thresholds: HealthAlertThresholds(lowSpO2Enabled: false, elevatedHREnabled: false),
            watermark: [:], quietHours: QuietHours(), now: at(12, 0), calendar: cal)
        XCTAssertEqual(alerts.first?.hit.value, 150)
        XCTAssertEqual(alerts.first?.watermark, at(11, 50))
    }

    /// A reading at or before the watermark is not new; one after it is.
    func testTheWatermarkCutsReadingsThatAlreadyNotified() {
        let thresholds = HealthAlertThresholds(lowSpO2Enabled: false, elevatedHREnabled: false)
        let none = LiveHealthAlerts.evaluate(
            hr: [hr(150, 11, 50)], spo2: [], inactiveHR: [], thresholds: thresholds,
            watermark: [.highHR: at(11, 50)], quietHours: QuietHours(), now: at(12, 0), calendar: cal)
        XCTAssertTrue(none.isEmpty)
        let fresh = LiveHealthAlerts.evaluate(
            hr: [hr(150, 11, 50), hr(130, 11, 55)], spo2: [], inactiveHR: [], thresholds: thresholds,
            watermark: [.highHR: at(11, 50)], quietHours: QuietHours(), now: at(12, 0), calendar: cal)
        XCTAssertEqual(fresh.first?.hit.value, 130)
    }

    // MARK: The evaluator refactors are behaviour-preserving

    /// `elevatedHRInactive` is the first of `elevatedHRInactiveReadings`, on every shape the
    /// existing tests use plus a long run.
    func testElevatedHRInactiveIsTheFirstQualifyingReading() {
        let shapes: [[HRSample]] = [
            [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6), hr(106, 1, 9), hr(112, 1, 12)],
            [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6)],
            [hr(105, 1, 0), hr(95, 1, 3), hr(110, 1, 6), hr(106, 1, 9), hr(112, 1, 12)],
            [hr(105, 1, 0), hr(108, 1, 9), hr(110, 1, 12), hr(106, 1, 15), hr(112, 1, 21)],
            (0..<30).map { hr(110, 2, $0 * 2) },
            [],
        ]
        for s in shapes {
            let all = HealthAlertEvaluator.elevatedHRInactiveReadings(
                s, thresholdBpm: 100, minDuration: 10 * 60, maxGap: 5 * 60)
            XCTAssertEqual(HealthAlertEvaluator.elevatedHRInactive(
                s, thresholdBpm: 100, minDuration: 10 * 60, maxGap: 5 * 60), all.first)
        }
        XCTAssertEqual(HealthAlertEvaluator.elevatedHRInactiveReadings(
            (0..<30).map { hr(110, 2, $0 * 2) }, thresholdBpm: 100, minDuration: 10 * 60).count, 25)
    }
}
