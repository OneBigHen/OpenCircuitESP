import XCTest
@testable import OpenCircuitKit

/// Decision 32 (#234): the instant alerts are live or not at all. Each scenario runs whole evaluate
/// passes through `InstantAlertHarness`. SYNTHETIC-ONLY readings.
///
/// The boundary is INCLUSIVE: a reading that ended exactly 30 minutes before the pass notifies,
/// because the decision says "at most 30 minutes".
final class LiveHealthAlertsScenarioTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func at(_ h: Int, _ m: Int = 0, _ s: Int = 0, day: Int = 17) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: h, minute: m, second: s))!
    }
    private func hr(_ bpm: Int, _ start: Date, end: Date? = nil) -> HRSample {
        HRSample(bpm: bpm, start: start, end: end)
    }
    private func spo2(_ pct: Int, _ time: Date) -> SpO2Reading { SpO2Reading(percent: pct, time: time) }

    private func harness(_ thresholds: HealthAlertThresholds) -> InstantAlertHarness {
        let h = InstantAlertHarness(calendar: cal)
        h.thresholds = thresholds
        return h
    }
    private var highHROnly: HealthAlertThresholds {
        HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
    }
    private var lowSpO2Only: HealthAlertThresholds {
        HealthAlertThresholds(highHREnabled: false, lowSpO2Percent: 90, elevatedHREnabled: false)
    }
    private var elevatedOnly: HealthAlertThresholds {
        HealthAlertThresholds(highHREnabled: false, lowSpO2Enabled: false,
                              elevatedHRBpm: 100, elevatedSustained: 10 * 60)
    }
    /// 22:00–07:00, the shipped default.
    private var nightQuiet: QuietHours { QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60) }

    /// An elevated run: one reading every 3 minutes from `from` through `to`.
    private func run(_ bpm: Int, from: Date, to: Date) -> [HRSample] {
        stride(from: 0, through: to.timeIntervalSince(from), by: 180)
            .map { hr(bpm, from.addingTimeInterval($0)) }
    }

    // MARK: Fresh vs stale

    /// The 2026-10-01 report: last evening's crossings, synced on the first sync of the morning.
    func testASixHourOldCrossingSyncedNowDoesNotNotify() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(6, 0))]
        XCTAssertEqual(h.pass(now: at(12, 0)), [])
    }

    func testATwentyNineMinuteOldCrossingNotifies() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(11, 31))]
        XCTAssertEqual(h.pass(now: at(12, 0)).map(\.notification), [.highHR])
        XCTAssertEqual(h.delivered.first?.value, 145)
    }

    func testAThirtyOneMinuteOldCrossingDoesNotNotify() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(11, 29))]
        XCTAssertEqual(h.pass(now: at(12, 0)), [])
    }

    /// INCLUSIVE: exactly 30 minutes old still notifies.
    func testACrossingExactlyThirtyMinutesOldNotifies() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(11, 30))]
        XCTAssertEqual(h.pass(now: at(12, 0)).map(\.notification), [.highHR])
        // …and one second past the boundary does not.
        let late = harness(highHROnly)
        late.hr = [hr(145, at(11, 30))]
        XCTAssertEqual(late.pass(now: at(12, 0, 1)), [])
    }

    /// Freshness runs from when the reading ENDED, not when it started.
    func testFreshnessIsMeasuredFromTheReadingsEnd() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(11, 20), end: at(11, 35))]   // started 40 min ago, ended 25 min ago
        XCTAssertEqual(h.pass(now: at(12, 0)).map(\.notification), [.highHR])
    }

    // MARK: Quiet hours

    /// A crossing inside quiet hours, evaluated 1 minute after they end and 2 h after the crossing.
    func testAQuietHoursCrossingIsNotDeliveredWhenTheWindowEnds() {
        let h = harness(highHROnly)
        h.quiet = nightQuiet
        h.hr = [hr(145, at(5, 1))]
        XCTAssertEqual(h.pass(now: at(5, 10)), [], "held while quiet hours are on")
        XCTAssertEqual(h.pass(now: at(7, 1)), [], "and never delivered later")
        XCTAssertTrue(h.delivered.isEmpty)
    }

    /// Still fresh when the window ends, but it happened inside it: suppressed, never delivered later.
    func testAQuietHoursCrossingThatIsStillFreshAtTheEndIsNotDeliveredLater() {
        let h = harness(highHROnly)
        h.quiet = nightQuiet
        h.hr = [hr(145, at(6, 45))]
        XCTAssertEqual(h.pass(now: at(6, 50)), [])
        XCTAssertEqual(h.pass(now: at(7, 5)), [])
    }

    func testACrossingAfterQuietHoursEndNotifies() {
        let h = harness(highHROnly)
        h.quiet = nightQuiet
        h.hr = [hr(145, at(7, 10))]
        XCTAssertEqual(h.pass(now: at(7, 15)).map(\.notification), [.highHR])
    }

    // MARK: At most once

    /// The same crossing evaluated twice, 3 h apart, with the backoff expired: one notification.
    func testTheSameCrossingNotifiesOnceAcrossAnExpiredBackoff() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(11, 50))]
        XCTAssertEqual(h.pass(now: at(12, 0)).count, 1)
        XCTAssertEqual(h.pass(now: at(15, 0)), [])
        XCTAssertEqual(h.delivered.count, 1)
    }

    /// A crossing the backoff held back is not released, hours late, when the backoff expires.
    func testACrossingHeldByTheBackoffIsNotReleasedWhenItExpires() {
        let h = harness(highHROnly)
        h.hr = [hr(140, at(8, 55))]
        XCTAssertEqual(h.pass(now: at(9, 0)).count, 1)
        h.hr.append(hr(150, at(10, 0)))
        XCTAssertEqual(h.pass(now: at(10, 5)), [], "inside the 2 h backoff")
        XCTAssertEqual(h.pass(now: at(13, 5)), [], "backoff expired, but the crossing is 3 h old")
        XCTAssertEqual(h.delivered.count, 1)
    }

    /// The sync-complete pass and the foreground pass race; the app's main actor runs each pass's
    /// synchronous part to completion before the other's, which is what this models.
    func testTwoRacingPassesNotifyOnce() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(11, 55))]
        h.pass(now: at(12, 0, 0))     // sync-complete
        // The foreground pass also sees the same reading twice (store + the just-synced batch).
        h.hr.append(hr(145, at(11, 55)))
        h.pass(now: at(12, 0, 1))     // foreground
        XCTAssertEqual(h.delivered.count, 1)
    }

    /// A genuinely new crossing after the backoff still notifies.
    func testANewCrossingAfterTheBackoffNotifies() {
        let h = harness(highHROnly)
        h.hr = [hr(140, at(11, 55))]
        XCTAssertEqual(h.pass(now: at(12, 0)).count, 1)
        h.hr.append(hr(150, at(14, 10)))
        XCTAssertEqual(h.pass(now: at(14, 15)).map(\.value), [150])
        XCTAssertEqual(h.delivered.count, 2)
    }

    // MARK: The reading's own time

    /// Clock skew: an end in the future is clamped to now. It notifies once and cannot stay fresh.
    func testAFutureEndIsClampedAndNotifiesOnce() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(11, 59), end: at(18, 0))]
        XCTAssertEqual(h.pass(now: at(12, 0)).count, 1)
        XCTAssertEqual(h.pass(now: at(15, 0)), [])
        XCTAssertEqual(h.delivered.count, 1)
    }

    func testAReadingThatHasNotStartedYetNeverNotifies() {
        let h = harness(highHROnly)
        h.hr = [hr(145, at(12, 30))]
        XCTAssertEqual(h.pass(now: at(12, 0)), [])
    }

    // MARK: Low SpO2 follows the same rule

    func testAStaleLowSpO2RunDoesNotNotify() {
        let h = harness(lowSpO2Only)
        h.spo2 = [spo2(88, at(5, 0)), spo2(86, at(5, 5))]
        XCTAssertEqual(h.pass(now: at(12, 0)), [])
        // Within the context window but past 30 minutes: still stale.
        let recent = harness(lowSpO2Only)
        recent.spo2 = [spo2(88, at(11, 0)), spo2(86, at(11, 5))]
        XCTAssertEqual(recent.pass(now: at(12, 0)), [])
    }

    func testAFreshLowSpO2RunNotifiesOnce() {
        let h = harness(lowSpO2Only)
        h.spo2 = [spo2(88, at(11, 40)), spo2(86, at(11, 45))]
        XCTAssertEqual(h.pass(now: at(11, 50)).map(\.value), [86])
        XCTAssertEqual(h.pass(now: at(14, 50)), [])
        XCTAssertEqual(h.delivered.count, 1)
    }

    /// The depth and time named are a FRESH reading's. A deeper reading earlier in the same run is
    /// older than 30 minutes, so it is in the charts, not in the notification.
    func testALowSpO2AlertNamesTheLowestFreshReading() {
        let h = harness(lowSpO2Only)
        h.spo2 = [spo2(84, at(11, 0)), spo2(89, at(11, 15)), spo2(88, at(11, 35)), spo2(89, at(11, 50))]
        let posted = h.pass(now: at(12, 0))
        XCTAssertEqual(posted.map(\.value), [88])
        XCTAssertEqual(posted.first?.time, at(11, 35))
    }

    func testALowSpO2RunInsideQuietHoursIsNotDeliveredLater() {
        let h = harness(lowSpO2Only)
        h.quiet = nightQuiet
        h.spo2 = [spo2(88, at(6, 40)), spo2(86, at(6, 45))]
        XCTAssertEqual(h.pass(now: at(6, 50)), [])
        XCTAssertEqual(h.pass(now: at(7, 5)), [])
    }

    // MARK: Elevated heart rate while inactive follows the same rule

    func testAStaleElevatedRunDoesNotNotify() {
        let h = harness(elevatedOnly)
        h.hr = run(110, from: at(5, 0), to: at(5, 12))
        XCTAssertEqual(h.pass(now: at(12, 0)), [])
        let recent = harness(elevatedOnly)
        recent.hr = run(110, from: at(11, 0), to: at(11, 21))
        XCTAssertEqual(recent.pass(now: at(12, 0)), [], "ended 39 minutes ago")
    }

    func testAFreshElevatedRunNotifiesOnce() {
        let h = harness(elevatedOnly)
        h.hr = run(110, from: at(11, 40), to: at(11, 52))
        XCTAssertEqual(h.pass(now: at(11, 55)).map(\.notification), [.elevatedHRInactive])
        XCTAssertEqual(h.pass(now: at(14, 55)), [])
        XCTAssertEqual(h.delivered.count, 1)
    }

    /// A run that became sustained over 30 minutes ago but is still going is live now.
    func testAnOngoingElevatedRunIsLive() {
        let h = harness(elevatedOnly)
        h.hr = run(110, from: at(11, 0), to: at(11, 57))
        XCTAssertEqual(h.pass(now: at(12, 0)).map(\.notification), [.elevatedHRInactive])
    }

    func testAnElevatedRunInsideQuietHoursIsNotDeliveredLater() {
        let h = harness(elevatedOnly)
        h.quiet = nightQuiet
        h.hr = run(110, from: at(6, 40), to: at(6, 58))
        XCTAssertEqual(h.pass(now: at(7, 5)), [])
    }

    // MARK: Night-level notifications are unchanged

    /// Skin temperature and fever describe a night, so they still fire on the first morning sync
    /// after it — hours after the night's readings, and after quiet hours held them.
    func testTemperatureAndFeverStillFireOnAMorningSyncOfTheNight() {
        var flags = SkinTempBaseline.AnomalyFlags()
        flags.abnormalRise = true
        let night = TempFeverNotifications.dayKey(for: cal.startOfDay(for: at(0, day: 17)), calendar: cal)
        let candidates = TempFeverNotifications.freshForNight(
            TempFeverNotifications.notifications(flags: flags, feverSuspected: true),
            night: night, lastNotifiedNight: [:])
        let gate = NotificationGate()
        XCTAssertEqual(gate.filter(candidates, now: at(6, 30), lastFired: [:], quietHours: nightQuiet,
                                   calendar: cal), [], "held during quiet hours")
        XCTAssertEqual(gate.filter(candidates, now: at(7, 30), lastFired: [:], quietHours: nightQuiet,
                                   calendar: cal), [.skinTempRise, .fever],
                       "delivered on the morning sync, with no freshness cut")
    }

    /// The morning overnight-signals verdict is still a morning notification about a night.
    func testTheHeadacheVerdictStillFiresInTheMorning() {
        let c = HeadacheSignsNotifications.candidates(
            enabled: true, band: .flagged, suppressedBy: nil, frozenDayCount: 30, retired: false,
            now: at(9, 0), lastNotifiedDay: [:], calendar: cal)
        XCTAssertEqual(c, [.headacheSigns])
    }

    /// The resting-HR, fever and headache paths read their own windows. Pinned so this change (or a
    /// later one in its name) cannot move them.
    func testTheNightLevelWindowsAreUnchanged() {
        XCTAssertEqual(VitalsBaseline.Config().minBaselineDays, 7)
        XCTAssertEqual(VitalsBaseline.Config().maxBaselineDays, 30)
        XCTAssertEqual(HeadacheSignals.Tuning().bandWindowDays, 60)
        XCTAssertEqual(HeadacheSignals.Tuning().minDaysForBanding, 21)
        XCTAssertEqual(NotificationGate().renotifyInterval, 2 * 3600)
    }
}
