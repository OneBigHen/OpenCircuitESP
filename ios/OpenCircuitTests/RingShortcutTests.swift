import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The Shortcuts actions on a RingConn Gen 3 (#260, decision 52g): Vibrate through the ring's session
// seam (a `RingSession` needs a real `CBPeripheral`), Set and Clear on OpenCircuit's own ring wake-up
// alarm, and the one-shot that "Once" needs. No Gen 3 is available here: everything below runs against
// fakes, and the ring path is untested on hardware. Every time is synthetic.

@MainActor
private final class FakeRing: ShortcutRingSession, RingAlarmBuzzer {
    var ready = true
    var generationKnown = true
    var supportsVibration = true
    var isIdleForShortcut = true
    var lastVibrationBlock: RingAlarmBlock?
    /// While set, every buzz is refused with this block (`RingSession.vibrate`'s own guards).
    var refusal: RingAlarmBlock?
    private(set) var buzzes = 0
    private(set) var bursts: [Int] = []

    func vibrate(_ pattern: VibrationPattern) -> Bool {
        if let refusal { lastVibrationBlock = refusal; return false }
        lastVibrationBlock = nil
        buzzes += 1
        return true
    }

    func vibrateBurst(_ pattern: VibrationPattern, count: Int, spacing: TimeInterval) -> Bool {
        if let refusal { lastVibrationBlock = refusal; return false }
        bursts.append(count)
        return true
    }
}

@MainActor
private final class FakeRingLink: ShortcutRingLink {
    var ring: FakeRing?
    var shortcutSession: (any ShortcutRingSession)? { ring }
    var hasActiveRing = true
    /// What `reconnectKnownPeripheral()` returns: false while a fresh central isn't powered on yet.
    var connectIssued = true
    private(set) var connects = 0
    var onConnect: (() -> Void)?

    func connectForShortcut() -> Bool {
        connects += 1
        onConnect?()
        return connectIssued
    }
}

/// Stands in for `HelioConnection` where the strap may not be reached.
@MainActor
private final class UntouchedStrapLink: ShortcutStrapLink {
    var session: HelioSession? { nil }
    var endedBusy: Bool { false }
    func connectForShortcut() -> Bool { false }
}

@MainActor
final class RingShortcutTests: XCTestCase {
    private let suite = "test.RingShortcutTests"
    private var defaults: UserDefaults!
    private var controller: RingAlarmController!
    private var clock = Date()
    private var onPause: (() -> Void)?
    private var ringReads = 0
    private let calendar = Calendar.current

    /// Test days start two days from now: the controller stamps `lastHandled` with the real clock
    /// whenever it stores the alarm, so every synthetic occurrence must lie after the real now.
    private lazy var baseDay = calendar.startOfDay(for: Date().addingTimeInterval(2 * 86_400))
    /// Day 0 at 12:00: the moment each test's Shortcut runs, unless it says otherwise.
    private lazy var noon = at(0, 12, 0)

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: baseDay)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        controller = RingAlarmController(defaults: defaults)
        // The person's own settings, which Set must keep. Backup alert off, so no permission prompt.
        controller.alarm = RingAlarm(isEnabled: false, hour: 9, minute: 0, weekdays: [], pattern: .long,
                                     burstCount: 5, burstSpacing: 6, backupNotification: false)
        clock = noon
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func actions(_ given: FakeRingLink? = nil, device: ActiveDeviceChoice = .ringConn,
                         saved: Bool = true, generation: RingGeneration? = .gen3,
                         cancelled: @escaping () -> Bool = { false }) -> WearableShortcuts {
        let link = given ?? FakeRingLink()
        return WearableShortcuts(WearableShortcutEnvironment(
            device: { device },
            savedStrapID: { nil },
            strapKey: { .missing },
            strapLink: { UntouchedStrapLink() },
            ringSaved: { [unowned self] in self.ringReads += 1; return saved },
            ringGeneration: { [unowned self] in self.ringReads += 1; return generation },
            ringLink: { [unowned self] in self.ringReads += 1; return link },
            ringAlarm: { [unowned self] in self.ringReads += 1; return self.controller },
            ringShortcutStore: ShortcutRingAlarmStore(defaults: defaults),
            applier: StrapWakeAlarmApplier(store: StrapWakeAlarmStore(defaults: defaults)),
            now: { [unowned self] in self.clock },
            pause: { [unowned self] in
                self.clock = self.clock.addingTimeInterval(0.25)
                self.onPause?()
            },
            isCancelled: cancelled))
    }

    private var record: ShortcutRingAlarmRecord? { ShortcutRingAlarmStore(defaults: defaults).record }

    // MARK: Vibrate Wearable (52g)

    func testAReadyIdleGen3RingBuzzesTheTimesAskedTwoSecondsApart() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        link.ring = ring
        let result = await actions(link).vibrate(times: 3)
        XCTAssertEqual(result.outcome, "vibrated 3")
        XCTAssertEqual(result.dialog, "Vibrated your RingConn ring 3 times.")
        XCTAssertEqual(ring.buzzes, 3)
        XCTAssertEqual(clock.timeIntervalSince(noon), 2 * WearableShortcuts.ringBuzzGap, accuracy: 0.01)
        XCTAssertEqual(link.connects, 0, "a ready session is used as it is")
    }

    func testTheSavedRingIsBroughtUpAndWaitedForUntilItKnowsItsModel() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        ring.ready = false
        ring.generationKnown = false
        link.onConnect = { link.ring = ring }
        var pauses = 0
        onPause = {
            pauses += 1
            if pauses == 4 { ring.ready = true }          // the link comes up
            if pauses == 8 { ring.generationKnown = true } // the DIS read names the model
        }
        let result = await actions(link).vibrate(times: 1)
        XCTAssertEqual(link.connects, 1)
        XCTAssertEqual(result.outcome, "vibrated 1")
        XCTAssertEqual(ring.buzzes, 1)
        XCTAssertGreaterThanOrEqual(pauses, 8)
    }

    /// The measured case (see the report): a ring that drains history right after it reconnects holds
    /// the link; the action waits for it (15 s) and never forces a buzz past `RingSession`'s guards.
    func testARingThatStaysBusyForTheWholeWindowIsReportedAndNeverBuzzed() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        ring.isIdleForShortcut = false
        link.ring = ring
        let result = await actions(link).vibrate(times: 1)
        XCTAssertEqual(result.outcome, "unreachable: syncing")
        XCTAssertEqual(result.dialog, "Your RingConn ring stayed busy syncing for 15 seconds; try again in a minute. It didn't vibrate.")
        XCTAssertEqual(ring.buzzes, 0)
        XCTAssertEqual(clock.timeIntervalSince(noon), WearableShortcuts.reachTimeout, accuracy: 0.3)
    }

    func testABusyRefusalIsWaitedOutInsideTheWindow() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        ring.refusal = .ringBusy   // a drain the session's own guard sees (`syncTask`), before `syncing` latches
        link.ring = ring
        var pauses = 0
        onPause = { pauses += 1; if pauses == 6 { ring.refusal = nil } }
        let result = await actions(link).vibrate(times: 1)
        XCTAssertEqual(result.outcome, "vibrated 1")
        XCTAssertEqual(ring.buzzes, 1)
    }

    func testAChargingRingIsNotBuzzedAndSaysWhy() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        ring.refusal = .ringOnCharger
        link.ring = ring
        let result = await actions(link).vibrate(times: 2)
        XCTAssertEqual(result.outcome, "ring blocked: ringOnCharger")
        XCTAssertEqual(result.dialog, "Your RingConn ring is in its charging case, so it didn't vibrate.")
    }

    func testARingWithoutAMotorIsRefused() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        ring.supportsVibration = false   // a Gen 2 or Gen 2 Air
        link.ring = ring
        let result = await actions(link).vibrate(times: 1)
        XCTAssertEqual(result.outcome, "ring has no motor")
        XCTAssertEqual(result.dialog, "Your RingConn ring doesn't have a motor OpenCircuit can drive. Only the RingConn Gen 3 has one.")
        XCTAssertEqual(ring.buzzes, 0)
    }

    func testACancelledMultiBuzzStopsAndSaysHowManyRan() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        link.ring = ring
        var cancelled = false
        onPause = { cancelled = true }
        let result = await actions(link, cancelled: { cancelled }).vibrate(times: 3)
        XCTAssertEqual(ring.buzzes, 1)
        XCTAssertEqual(result.outcome, "cancelled after 1 of 3")
    }

    /// Review-261b S-C: a cold launch's ring central isn't powered on yet, so `reconnectKnownPeripheral()`
    /// returns false while the connect is armed for power-on. With an active ring the action waits.
    func testAConnectNotIssuedYetIsWaitedOutWhenARingIsActive() async {
        let link = FakeRingLink()
        link.connectIssued = false
        let ring = FakeRing()
        ring.ready = false
        var pauses = 0
        onPause = { pauses += 1; if pauses == 6 { link.ring = ring; ring.ready = true } }
        let result = await actions(link).vibrate(times: 1)
        XCTAssertEqual(result.outcome, "vibrated 1")
        XCTAssertEqual(ring.buzzes, 1)

        let none = FakeRingLink()
        none.connectIssued = false
        none.hasActiveRing = false
        let refused = await actions(none).vibrate(times: 1)
        XCTAssertEqual(refused.outcome, "unreachable: no connection", "no active ring: nothing to wait for")
    }

    /// Review-261b N-B (R8): a ready ring whose model is never named says so, not "busy syncing".
    func testARingThatNeverNamesItsModelSaysSo() async {
        let link = FakeRingLink()
        let ring = FakeRing()
        ring.generationKnown = false
        link.ring = ring
        let result = await actions(link).vibrate(times: 1)
        XCTAssertEqual(result.outcome, "unreachable: model unknown")
        XCTAssertEqual(result.dialog, "Your RingConn ring hasn't said which model it is yet. Open OpenCircuit with the ring connected once, then try again. It didn't vibrate.")
        XCTAssertEqual(ring.buzzes, 0)
    }

    func testWithNoSavedRingNothingIsReached() async {
        let link = FakeRingLink()
        let result = await actions(link, saved: false).vibrate(times: 1)
        XCTAssertEqual(result.dialog, "No RingConn ring is set up in OpenCircuit yet. Set it up in the app first.")
        XCTAssertEqual(link.connects, 0)
    }

    /// Decision 1: with the strap chosen no ring path runs, for any action.
    func testWithTheStrapChosenNoRingPathRuns() async {
        let strapChosen = actions(device: .helioStrap)
        _ = await strapChosen.vibrate(times: 1)
        _ = await strapChosen.setWakeAlarm(hour: 7, minute: 0, days: .once)
        _ = await strapChosen.clearWakeAlarm()
        XCTAssertEqual(ringReads, 0)
        XCTAssertNil(record)
    }

    // MARK: Set Wake Alarm (52g)

    func testSetOnceSetsTheAppsAlarmAsAOneShotKeepingThePersonsSettings() async throws {
        let result = await actions().setWakeAlarm(hour: 7, minute: 0, days: .once)
        XCTAssertEqual(result.outcome, "set")
        let alarm = controller.alarm
        let occurrence = at(1, 7, 0)
        XCTAssertTrue(alarm.isEnabled)
        XCTAssertEqual([alarm.hour, alarm.minute], [7, 0])
        XCTAssertEqual(alarm.weekdays, [calendar.component(.weekday, from: occurrence)], "the occurrence's weekday")
        XCTAssertEqual(controller.oneShotOccurrence, occurrence, "the first 07:00 at or after noon: tomorrow")
        XCTAssertEqual(alarm.pattern, .long, "the person's pattern kept")
        XCTAssertEqual(alarm.burstCount, 5)
        XCTAssertEqual(alarm.burstSpacing, 6)
        XCTAssertFalse(alarm.backupNotification)
        XCTAssertEqual(record, ShortcutRingAlarmRecord(hour: 7, minute: 0, weekdays: alarm.weekdays, oneShot: occurrence))
        // The dialog: the app's alarm, nothing on the ring, up to 15 minutes late, the backup alert's state.
        for fact in ["OpenCircuit's wake-up alarm for your RingConn ring", "nothing is stored on the ring",
                     "up to 15 minutes late", "The backup notification is off"] {
            XCTAssertTrue(result.dialog.contains(fact), "\(fact): \(result.dialog)")
        }
        XCTAssertFalse(result.dialog.contains("ring or strap"))
        XCTAssertEqual(ShortcutRingAlarmStore(defaults: defaults).note(alarm: alarm, oneShot: controller.oneShotOccurrence),
                       "Once · Set by Shortcuts")
    }

    func testRepeatMapsOntoTheAlarmsWeekdays() async {
        let cases: [(ZeppAlarmDays, Set<Int>)] = [(.everyDay, []), (.weekdays, [2, 3, 4, 5, 6]), (.weekend, [1, 7])]
        for (days, weekdays) in cases {
            let result = await actions().setWakeAlarm(hour: 6, minute: 15, days: days)
            XCTAssertEqual(result.outcome, "set", days.summary)
            XCTAssertEqual(controller.alarm.weekdays, weekdays, days.summary)
            XCTAssertNil(controller.oneShotOccurrence, "repeating")
            XCTAssertEqual(record?.weekdays, weekdays)
        }
    }

    func testTheSameAlarmAgainRewritesNothing() async {
        _ = await actions().setWakeAlarm(hour: 6, minute: 15, days: .everyDay)
        let handled = defaults.double(forKey: RingAlarmController.Key.lastHandled)
        let again = await actions().setWakeAlarm(hour: 6, minute: 15, days: .everyDay)
        XCTAssertEqual(again.outcome, "already set")
        XCTAssertEqual(defaults.double(forKey: RingAlarmController.Key.lastHandled), handled,
                       "rewriting would mark a due occurrence handled")
    }

    func testAnUnknownModelOrARingWithoutAMotorIsRefusedAndNothingChanges() async {
        let before = controller.alarm
        let unknown = await actions(generation: nil).setWakeAlarm(hour: 7, minute: 0, days: .once)
        XCTAssertEqual(unknown.outcome, "ring model unknown")
        XCTAssertEqual(unknown.dialog, "OpenCircuit doesn't know your RingConn ring's model yet. Open the app with the ring connected once, then try again.")
        let gen2 = await actions(generation: .gen2).setWakeAlarm(hour: 7, minute: 0, days: .once)
        XCTAssertEqual(gen2.outcome, "ring has no motor")
        XCTAssertEqual(gen2.dialog, "Your RingConn ring (Gen 2) doesn't have a motor OpenCircuit can drive, so it can't have a wake-up alarm. Only the RingConn Gen 3 has one.")
        let clear = await actions(generation: .gen2Air).clearWakeAlarm()
        XCTAssertEqual(clear.outcome, "ring has no motor")
        XCTAssertEqual(controller.alarm, before)
        XCTAssertNil(record)
    }

    // MARK: Clear Wake Alarm (52g, 52c's rule)

    func testClearTurnsOffOnlyTheAlarmShortcutsSet() async {
        let none = await actions().clearWakeAlarm()
        XCTAssertEqual(none.outcome, "nothing to clear")

        _ = await actions().setWakeAlarm(hour: 6, minute: 30, days: .weekdays)
        let cleared = await actions().clearWakeAlarm()
        XCTAssertEqual(cleared.outcome, "cleared")
        XCTAssertEqual(cleared.dialog, "Turned off the wake-up alarm Shortcuts set for your RingConn ring.")
        XCTAssertFalse(controller.alarm.isEnabled)
        XCTAssertEqual(controller.alarm.pattern, .long, "only switched off")
        XCTAssertNil(record)

        // Changed on the alarm screen since: left as it is.
        _ = await actions().setWakeAlarm(hour: 6, minute: 30, days: .weekdays)
        var edited = controller.alarm
        edited.minute = 45
        controller.alarm = edited
        XCTAssertNil(ShortcutRingAlarmStore(defaults: defaults).note(alarm: controller.alarm, oneShot: nil), "no longer Shortcuts'")
        let left = await actions().clearWakeAlarm()
        XCTAssertEqual(left.outcome, "changed in the app; left alone")
        XCTAssertTrue(controller.alarm.isEnabled)
        XCTAssertEqual(controller.alarm.minute, 45)
    }

    func testClearAfterAOneShotAlreadyTurnedItselfOff() async {
        _ = await actions().setWakeAlarm(hour: 7, minute: 0, days: .once)
        controller.evaluate(session: FakeRing(), now: at(1, 7, 2))
        let result = await actions().clearWakeAlarm()
        XCTAssertEqual(result.outcome, "already off")
    }

    // MARK: The one-shot (52g)

    private func setOnce() -> Date {
        controller.setFromShortcut(hour: 7, minute: 0, weekdays: [], once: true, now: noon)
        return at(1, 7, 0)
    }

    func testAOneShotFiresOnceInsideTheGraceThenTurnsOff() {
        XCTAssertEqual(setOnce(), controller.oneShotOccurrence)
        let ring = FakeRing()
        controller.evaluate(session: ring, now: at(1, 6, 59))
        XCTAssertEqual(ring.bursts, [], "not yet")
        controller.evaluate(session: ring, now: at(1, 7, 5))
        XCTAssertEqual(ring.bursts, [5], "once, with the person's burst count")
        XCTAssertFalse(controller.alarm.isEnabled, "then off")
        XCTAssertNil(controller.oneShotOccurrence)
        controller.evaluate(session: ring, now: at(1, 7, 6))
        controller.evaluate(session: ring, now: at(2, 7, 2))
        XCTAssertEqual(ring.bursts, [5], "never again")
    }

    func testAOneShotBlockedByABusyRingRetriesInsideTheGrace() {
        _ = setOnce()
        let ring = FakeRing()
        ring.refusal = .ringBusy
        controller.evaluate(session: ring, now: at(1, 7, 1))
        XCTAssertTrue(controller.alarm.isEnabled, "transient: still waiting")
        ring.refusal = nil
        controller.evaluate(session: ring, now: at(1, 7, 3))
        XCTAssertEqual(ring.bursts, [5])
        XCTAssertFalse(controller.alarm.isEnabled)
    }

    func testAOneShotMissedPastTheGraceTurnsOffWithoutABuzz() {
        _ = setOnce()
        let ring = FakeRing()
        controller.evaluate(session: ring, now: at(1, 7, 20))
        XCTAssertEqual(ring.bursts, [])
        XCTAssertFalse(controller.alarm.isEnabled)
        XCTAssertNil(controller.oneShotOccurrence)
        XCTAssertTrue(controller.lastOutcome?.hasPrefix("Missed") == true)
    }

    func testAOneShotWithNoRuntimeThatDayIsNotFiredInsideTheNextDaysGrace() {
        _ = setOnce()
        let ring = FakeRing()
        controller.evaluate(session: ring, now: at(2, 7, 5))
        XCTAssertEqual(ring.bursts, [], "a later occurrence never fires (52e's rule)")
        XCTAssertFalse(controller.alarm.isEnabled)
        // A week later, on the same weekday the one-shot's days name: still nothing.
        controller.evaluate(session: ring, now: at(8, 7, 5))
        XCTAssertEqual(ring.bursts, [])
    }

    /// Review-261b S-B: a Once set inside its own minute goes to the next day, as the strap's does
    /// (`nextDate(after:)`), so both devices agree; set before the minute, it is today's.
    func testAOnceSetInsideItsOwnMinuteGoesToTheNextDayLikeTheStrap() {
        let madeAt = at(1, 7, 0).addingTimeInterval(20)
        let ring = RingAlarmController.oneShotOccurrence(hour: 7, minute: 0, after: madeAt, calendar: calendar)
        let strap = calendar.nextDate(after: madeAt, matching: DateComponents(hour: 7, minute: 0), matchingPolicy: .nextTime)
        XCTAssertEqual(ring, at(2, 7, 0))
        XCTAssertEqual(ring, strap, "the ring and the strap agree")
        XCTAssertEqual(RingAlarmController.oneShotOccurrence(hour: 7, minute: 0, after: at(1, 6, 59), calendar: calendar),
                       at(1, 7, 0))

        // Through the controller: no buzz this minute, then it fires the next morning.
        controller.setFromShortcut(hour: 7, minute: 0, weekdays: [], once: true, now: madeAt)
        let buzzer = FakeRing()
        controller.evaluate(session: buzzer, now: at(1, 7, 1))
        XCTAssertEqual(buzzer.bursts, [])
        XCTAssertTrue(controller.alarm.isEnabled, "still waiting for tomorrow")
        controller.evaluate(session: buzzer, now: at(2, 7, 1))
        XCTAssertEqual(buzzer.bursts, [5])
        XCTAssertFalse(controller.alarm.isEnabled)
    }

    func testAOneShotWarmsUpOnlyForItsOwnOccurrence() {
        let occurrence = setOnce()
        XCTAssertEqual(controller.warmUpTarget(now: at(1, 6, 57)), occurrence)
        XCTAssertNil(controller.warmUpTarget(now: at(0, 6, 57)), "not before its day")
    }

    func testAScheduleEditMakesTheOneShotAnOrdinaryAlarmAndAPatternEditKeepsIt() {
        _ = setOnce()
        var patternOnly = controller.alarm
        patternOnly.pattern = .notification
        controller.alarm = patternOnly
        XCTAssertNotNil(controller.oneShotOccurrence, "a pattern edit keeps it")
        var moved = controller.alarm
        moved.minute = 30
        controller.alarm = moved
        XCTAssertNil(controller.oneShotOccurrence, "a schedule edit makes it the person's repeating alarm")
    }

    func testARepeatingAlarmDecidesExactlyAsTheKitDoes() {
        let alarms = [RingAlarm(isEnabled: true, hour: 7, minute: 0),
                      RingAlarm(isEnabled: true, hour: 6, minute: 30, weekdays: [2, 3, 4, 5, 6]),
                      RingAlarm(isEnabled: false, hour: 7, minute: 0)]
        for alarm in alarms {
            for minutes in stride(from: -60, through: 60 * 30, by: 7) {
                let now = at(1, 7, 0).addingTimeInterval(TimeInterval(minutes * 60))
                for handled in [nil, at(0, 7, 0), at(1, 7, 0)] {
                    let kit = RingAlarmSchedule.decide(alarm: alarm, now: now, lastHandledAt: handled)
                    let app = RingAlarmController.decide(alarm: alarm, oneShot: nil, now: now, lastHandledAt: handled)
                    switch kit {
                    case .idle: XCTAssertEqual(app, .idle)
                    case .fire(let scheduled, let lateBy): XCTAssertEqual(app, .fire(scheduled: scheduled, lateBy: lateBy))
                    case .missed(let scheduled): XCTAssertEqual(app, .missed(scheduled: scheduled))
                    }
                }
            }
        }
        // And through the controller: an every-day alarm fires every morning and stays on.
        controller.setFromShortcut(hour: 7, minute: 0, weekdays: [], once: false, now: noon)
        let ring = FakeRing()
        controller.evaluate(session: ring, now: at(1, 7, 5))
        controller.evaluate(session: ring, now: at(2, 7, 5))
        XCTAssertEqual(ring.bursts, [5, 5])
        XCTAssertTrue(controller.alarm.isEnabled)
    }

    func testAOneShotsBackupAlertIsOneNonRepeatingNotificationAtItsOccurrence() {
        let occurrence = at(1, 7, 0)
        let alarm = RingAlarm(isEnabled: true, hour: 7, minute: 0, weekdays: [2], backupNotification: true)
        let once = RingAlarmController.backupTriggers(alarm: alarm, oneShot: occurrence, calendar: calendar)
        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(once.first?.repeats, false)
        XCTAssertEqual(once.first?.components, calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence))
        // Repeating alarms: exactly today's shapes.
        let daily = RingAlarmController.backupTriggers(alarm: RingAlarm(isEnabled: true, hour: 7, minute: 0), oneShot: nil)
        XCTAssertEqual(daily.map(\.identifier), ["alarm.ring.backup"])
        XCTAssertEqual(daily.first?.components, DateComponents(hour: 7, minute: 0))
        XCTAssertEqual(daily.first?.repeats, true)
        let weekdays = RingAlarmController.backupTriggers(alarm: RingAlarm(isEnabled: true, hour: 6, minute: 30, weekdays: [6, 2]),
                                                          oneShot: nil)
        XCTAssertEqual(weekdays.map(\.identifier), ["alarm.ring.backup.2", "alarm.ring.backup.6"])
        XCTAssertEqual(weekdays.map(\.components), [DateComponents(hour: 6, minute: 30, weekday: 2),
                                                    DateComponents(hour: 6, minute: 30, weekday: 6)])
        XCTAssertEqual(Set(weekdays.map(\.repeats)), [true])
    }

    /// An alarm stored by today's builds decodes unchanged, as a repeating alarm (the Kit's `RingAlarm`
    /// is unchanged; the one-shot lives under its own key).
    func testAnAlarmInTodaysJSONShapeDecodesUnchanged() {
        let json = #"{"isEnabled":true,"hour":6,"minute":45,"weekdays":[2,3,4,5,6],"pattern":2,"burstCount":5,"burstSpacing":6,"backupNotification":false}"#
        let fresh = UserDefaults(suiteName: suite + ".json")!
        fresh.removePersistentDomain(forName: suite + ".json")
        defer { fresh.removePersistentDomain(forName: suite + ".json") }
        fresh.set(Data(json.utf8), forKey: RingAlarmController.Key.alarm)
        let stored = RingAlarmController(defaults: fresh)
        XCTAssertEqual(stored.alarm, RingAlarm(isEnabled: true, hour: 6, minute: 45, weekdays: [2, 3, 4, 5, 6], pattern: .long,
                                               burstCount: 5, burstSpacing: 6, backupNotification: false))
        XCTAssertNil(stored.oneShotOccurrence)
    }
}
