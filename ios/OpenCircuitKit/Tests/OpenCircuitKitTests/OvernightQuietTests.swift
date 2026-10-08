import XCTest
@testable import OpenCircuitKit

/// #280 / decision 60: the wall-clock floor under the overnight-quiet drain gate, and the three ways
/// the session's own sleep window read "awake" mid-sleep and let an automatic drain walk the ring's
/// resume pointer. Every fixture is synthetic: rounded clock times, invented windows and walks.
final class OvernightQuietTests: XCTestCase {

    /// Fixed UTC calendar so local time of day is deterministic on any CI machine.
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// `"MM-dd HH:mm"` in October 2026, UTC.
    private func at(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "2026-\(s)")!
    }

    private func quiet(_ now: String, walk: String? = nil) -> Bool {
        OvernightQuiet.suppressAutomaticHistoryOpen(now: at(now), morningWalkAt: walk.map(at), calendar: utc)
    }

    // MARK: - Clock boundaries

    func testEveningBeforeNineIsLeftToTheSessionWindow() {
        XCTAssertFalse(quiet("10-06 20:59"))
    }

    func testHardQuietStartsAtNine() {
        XCTAssertTrue(quiet("10-06 21:00"))
        XCTAssertTrue(quiet("10-06 23:59"))
        XCTAssertTrue(quiet("10-07 00:00"))
        XCTAssertTrue(quiet("10-07 03:30"))
        XCTAssertTrue(quiet("10-07 06:59"))
    }

    func testAWalkDoesNotReleaseHardQuiet() {
        // A bathroom trip, or a walk from the evening before, is not a morning.
        XCTAssertTrue(quiet("10-06 22:00", walk: "10-06 21:30"))
        XCTAssertTrue(quiet("10-07 03:40", walk: "10-07 03:30"))
        XCTAssertTrue(quiet("10-07 06:59", walk: "10-07 06:50"))
    }

    func testLieInHoldsFromSevenWithoutAWalk() {
        XCTAssertTrue(quiet("10-07 07:00"))
        XCTAssertTrue(quiet("10-07 09:00"))
        XCTAssertTrue(quiet("10-07 10:59"))
    }

    func testAMorningWalkReleasesTheLieIn() {
        XCTAssertFalse(quiet("10-07 07:00", walk: "10-07 07:00"))
        XCTAssertFalse(quiet("10-07 08:30", walk: "10-07 08:00"))
        XCTAssertFalse(quiet("10-07 10:59", walk: "10-07 07:15"))
    }

    func testOnlyAWalkAtOrAfterSevenTodayCounts() {
        XCTAssertTrue(quiet("10-07 07:30", walk: "10-07 06:59"), "a walk before 07:00 is still the night")
        XCTAssertTrue(quiet("10-07 08:30", walk: "10-06 08:00"), "yesterday's morning walk is stale")
        XCTAssertTrue(quiet("10-07 08:30", walk: "10-07 09:00"), "a walk after now is not yet seen")
    }

    func testFromElevenTheFloorHasNoOpinion() {
        XCTAssertFalse(quiet("10-07 11:00"))
        XCTAssertFalse(quiet("10-07 15:00"))
        XCTAssertFalse(quiet("10-07 11:00", walk: "10-06 08:00"))
    }

    func testIsLieInBoundaries() {
        XCTAssertFalse(OvernightQuiet.isLieIn(at("10-07 06:59"), calendar: utc))
        XCTAssertTrue(OvernightQuiet.isLieIn(at("10-07 07:00"), calendar: utc))
        XCTAssertTrue(OvernightQuiet.isLieIn(at("10-07 10:59"), calendar: utc))
        XCTAssertFalse(OvernightQuiet.isLieIn(at("10-07 11:00"), calendar: utc))
    }

    // MARK: - The drain gate with the floor folded in

    func testManualAlwaysDrains() {
        for inWindow in [true, false] {
            for clock in [true, false] {
                for due in [true, false] {
                    XCTAssertTrue(HistoryDrainCadence.shouldDrain(.manual, inSleepWindow: inWindow,
                                                                  clockQuiet: clock, isDue: due))
                }
            }
        }
    }

    func testFloorOnlyAddsQuiet() {
        // Wherever the session window holds a drain, the floor never opens one.
        var t = at("10-06 12:00")
        while t < at("10-07 12:00") {
            let clock = OvernightQuiet.suppressAutomaticHistoryOpen(now: t, morningWalkAt: nil, calendar: utc)
            XCTAssertFalse(HistoryDrainCadence.shouldDrain(.automatic, inSleepWindow: true,
                                                           clockQuiet: clock, isDue: true))
            t = t.addingTimeInterval(15 * 60)
        }
    }

    func testDaytimeCadenceUnchanged() {
        // 11:00–20:59, session window open: the automatic gate is exactly `isDue`, as before.
        for now in ["10-07 11:00", "10-07 14:30", "10-07 20:59"] {
            let clock = quiet(now)
            for due in [true, false] {
                XCTAssertEqual(HistoryDrainCadence.shouldDrain(.automatic, inSleepWindow: false,
                                                               clockQuiet: clock, isDue: due),
                               HistoryDrainCadence.shouldDrain(manual: false, inSleepWindow: false, isDue: due))
            }
        }
    }

    // MARK: - #280 fail-open path 1: a fresh background session, nightWindow still nil

    /// The stored schedule default (22:30→06:30) — what `isInSleepWindow` falls back to before
    /// `refreshNightWindowIfNeeded` has resolved a window on a cold background session.
    private func defaultSchedule(_ now: Date) -> DateInterval? {
        SleepWindow.interval(bedMinutes: 22 * 60 + 30, wakeMinutes: 6 * 60 + 30, nightEndingNear: now, calendar: utc)
    }

    func testNilNightWindowBeforeTheDefaultBedtimeNoLongerDrains() {
        let now = at("10-06 22:15")   // asleep since 22:00, before the 22:30 default bedtime
        let inWindow = SleepWindowGate.isInSleepWindow(now: now, nightWindow: nil, isExplicit: false,
                                                       morningWakeConfirmedAt: nil, fallback: { defaultSchedule(now) })
        XCTAssertFalse(inWindow, "precondition: the fallback reads awake")
        XCTAssertTrue(HistoryDrainCadence.shouldDrain(manual: false, inSleepWindow: inWindow, isDue: true),
                      "precondition: the session window alone fails open")
        XCTAssertFalse(automaticDrain(now: now, inWindow: inWindow))
    }

    func testNilNightWindowPastTheDefaultWakeNoLongerDrains() {
        let now = at("10-07 06:45")   // still asleep past the 06:30 default wake
        let inWindow = SleepWindowGate.isInSleepWindow(now: now, nightWindow: nil, isExplicit: false,
                                                       morningWakeConfirmedAt: nil, fallback: { defaultSchedule(now) })
        XCTAssertFalse(inWindow, "precondition: the fallback reads awake")
        XCTAssertFalse(automaticDrain(now: now, inWindow: inWindow))
        XCTAssertFalse(automaticDrain(now: at("10-07 08:00"), inWindow: false), "lie-in, no walk seen")
        XCTAssertTrue(automaticDrain(now: at("10-07 08:00"), inWindow: false, walk: at("10-07 07:45")))
    }

    func testNilNightWindowWithNoFallbackStillHoldsOvernight() {
        let now = at("10-07 03:00")
        let inWindow = SleepWindowGate.isInSleepWindow(now: now, nightWindow: nil, isExplicit: false,
                                                       morningWakeConfirmedAt: nil, fallback: { nil })
        XCTAssertFalse(inWindow)
        XCTAssertFalse(automaticDrain(now: now, inWindow: inWindow))
    }

    // MARK: - #280 fail-open path 2: the learner, poisoned by a mis-staged night's RECORDED wake

    /// Three mis-staged nights whose sync hole read as an early wake: recorded 20:20 → `wake`.
    private func poisonedWindow(wake: String, near now: Date) -> DateInterval? {
        let days = ["10-03", "10-04", "10-05"]
        let onsets = days.map { at("\($0) 20:20") }
        let wakes = days.map { at("\($0) \(wake)").addingTimeInterval(86_400) }
        return SleepWindow.habitualInterval(onsets: onsets, wakes: wakes, nightEndingNear: now, calendar: utc)
    }

    func testPoisonedLearnerCeilingNoLongerForcesAnEarlyMorningDrain() {
        // Learned wake 00:30 → earliest wake 00:30, +6 h ceiling 06:30: before the fix the ceiling
        // alone opened a drain while the wearer slept on.
        let now = at("10-07 06:45")
        let w = poisonedWindow(wake: "00:30", near: now)
        XCTAssertNotNil(w)
        let inWindow = SleepWindowGate.isInSleepWindow(now: now, nightWindow: w, isExplicit: false,
                                                       morningWakeConfirmedAt: nil, fallback: { nil })
        XCTAssertFalse(inWindow, "precondition: past the poisoned ceiling the session window reads awake")
        XCTAssertFalse(automaticDrain(now: now, inWindow: inWindow))
        XCTAssertFalse(automaticDrain(now: at("10-07 09:30"), inWindow: false), "lie-in, no walk seen")
    }

    func testPoisonedLearnerNightLatchNoLongerOpensMidSleep() {
        // Learned wake 03:30: a bathroom walk at 04:10 is past the poisoned earliest wake, so the
        // session's walking latch fires and the window reads awake from then on.
        let now = at("10-07 04:15")
        let w = poisonedWindow(wake: "03:30", near: now)
        let latch = at("10-07 04:10")
        let inWindow = SleepWindowGate.isInSleepWindow(now: now, nightWindow: w, isExplicit: false,
                                                       morningWakeConfirmedAt: latch, fallback: { nil })
        XCTAssertFalse(inWindow, "precondition: the night latch opened the session window")
        XCTAssertFalse(automaticDrain(now: now, inWindow: inWindow))
        // The same 04:10 latch is not a morning walk, so it does not release the lie-in either.
        XCTAssertFalse(automaticDrain(now: at("10-07 08:00"), inWindow: false, walk: latch))
    }

    // MARK: - #280 fail-open path 3: Sleep Focus ending drained as if it were manual

    func testSleepFocusEndingWhileAsleepNoLongerDrains() {
        for now in ["10-07 02:00", "10-07 05:00", "10-07 06:59"] {
            XCTAssertTrue(HistoryDrainCadence.shouldDrain(manual: true, inSleepWindow: true, isDue: true),
                          "precondition: Focus-off used to drain as manual")
            XCTAssertFalse(HistoryDrainCadence.shouldDrain(.sleepFocusEnded, inSleepWindow: false,
                                                           clockQuiet: quiet(now), isDue: true), now)
        }
    }

    func testSleepFocusEndingInTheLieInNeedsAMorningWalk() {
        XCTAssertFalse(HistoryDrainCadence.shouldDrain(.sleepFocusEnded, inSleepWindow: false,
                                                       clockQuiet: quiet("10-07 07:30"), isDue: true))
        XCTAssertTrue(HistoryDrainCadence.shouldDrain(.sleepFocusEnded, inSleepWindow: false,
                                                      clockQuiet: quiet("10-07 07:30", walk: "10-07 07:20"),
                                                      isDue: true))
    }

    func testSleepFocusEndingStillBypassesTheLearnedWindow() {
        // Past the floor, Focus-off is still the "sleep is over" signal: a learned window that runs
        // late does not hold it (the reason it bypassed the gate in the first place).
        XCTAssertTrue(HistoryDrainCadence.shouldDrain(.sleepFocusEnded, inSleepWindow: true,
                                                      clockQuiet: quiet("10-07 11:15"), isDue: false))
        XCTAssertTrue(HistoryDrainCadence.shouldDrain(.sleepFocusEnded, inSleepWindow: true,
                                                      clockQuiet: quiet("10-07 08:00", walk: "10-07 07:40"),
                                                      isDue: false))
    }

    // MARK: - Helpers

    private func automaticDrain(now: Date, inWindow: Bool, walk: Date? = nil) -> Bool {
        let clock = OvernightQuiet.suppressAutomaticHistoryOpen(now: now, morningWalkAt: walk, calendar: utc)
        return HistoryDrainCadence.shouldDrain(.automatic, inSleepWindow: inWindow, clockQuiet: clock, isDue: true)
    }
}
