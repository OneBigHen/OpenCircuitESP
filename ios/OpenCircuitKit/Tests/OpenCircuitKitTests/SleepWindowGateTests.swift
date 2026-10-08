import XCTest
@testable import OpenCircuitKit

/// `SleepWindowGate` is `RingSession.isInSleepWindow`'s decision moved into the kit unchanged (#280).
/// These pin each rule it had there, so the move itself is not a behavior change.
final class SleepWindowGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func h(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    /// A learned window 0 h → 9.5 h: earliest wake at 8 h (9.5 − 1.5), ceiling at 14 h.
    private var learned: DateInterval { DateInterval(start: h(0), end: h(9.5)) }

    private func gate(_ now: Date, window: DateInterval?, explicit: Bool = false, latch: Date? = nil,
                      fallback: DateInterval? = nil) -> Bool {
        SleepWindowGate.isInSleepWindow(now: now, nightWindow: window, isExplicit: explicit,
                                        morningWakeConfirmedAt: latch, fallback: { fallback })
    }

    func testExplicitScheduleIsTrustedAsIs() {
        let w = DateInterval(start: h(0), end: h(8))
        XCTAssertFalse(gate(h(-0.1), window: w, explicit: true))
        XCTAssertTrue(gate(h(7.9), window: w, explicit: true))
        XCTAssertTrue(gate(h(8), window: w, explicit: true), "DateInterval.contains includes its end")
        XCTAssertFalse(gate(h(8.1), window: w, explicit: true))
        XCTAssertTrue(gate(h(7.9), window: w, explicit: true, latch: h(6)), "a latch never shortens an explicit schedule")
    }

    func testLearnedWindowHoldsUntilTheEarliestWake() {
        XCTAssertFalse(gate(h(-0.1), window: learned), "before tonight's bedtime")
        XCTAssertTrue(gate(h(0), window: learned))
        XCTAssertTrue(gate(h(7.9), window: learned))
    }

    func testPastTheEarliestWakeAWalkThisNightOpens() {
        XCTAssertTrue(gate(h(9), window: learned), "no walk seen yet")
        XCTAssertFalse(gate(h(9), window: learned, latch: h(8.5)))
        XCTAssertTrue(gate(h(9), window: learned, latch: h(-1)), "a latch from before tonight's start is stale")
        XCTAssertTrue(gate(h(9), window: learned, latch: h(9.5)), "a latch after now is not yet seen")
    }

    func testCeilingForcesTheMorningDrain() {
        XCTAssertTrue(gate(h(13.9), window: learned))
        XCTAssertFalse(gate(h(14), window: learned))
    }

    func testAWindowTrimmedAwayReadsAwake() {
        XCTAssertFalse(gate(h(0.5), window: DateInterval(start: h(0), end: h(1.5))))
    }

    func testFallbackOnlyWhenNoWindowResolved() {
        let fallback = DateInterval(start: h(0), end: h(8))
        XCTAssertTrue(gate(h(4), window: nil, fallback: fallback))
        XCTAssertFalse(gate(h(9), window: nil, fallback: fallback))
        XCTAssertFalse(gate(h(4), window: nil, fallback: nil))
        // With a resolved window the fallback is never consulted.
        var consulted = false
        _ = SleepWindowGate.isInSleepWindow(now: h(4), nightWindow: learned, isExplicit: false,
                                            morningWakeConfirmedAt: nil, fallback: { consulted = true; return nil })
        XCTAssertFalse(consulted)
    }
}
