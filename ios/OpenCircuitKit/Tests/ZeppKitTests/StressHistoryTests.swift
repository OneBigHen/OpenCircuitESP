// The strap's all-day stress as history (#239): the mapping onto `.stress` and the watermark
// backfill's ledger rule. Every fixture is synthetic: made-up levels, times chosen by hand.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

final class StressHistoryTests: XCTestCase {
    /// 2026-09-30T08:00:00Z.
    private let start = date(1_790_755_200)

    // MARK: Mapping

    func testStressMinutesBecomeStressSamplesAndNoReadingIsSkipped() throws {
        // 0, 39, ff (no reading), 100, 101 (out of range), 255 again.
        let parsed = try ZeppRecordParser.parse(.autoStress, data: [0x00, 0x27, 0xff, 0x64, 0x65, 0xff], start: start)
        let expected = [
            QuantitySample(kind: .stress, start: start, value: 0),
            QuantitySample(kind: .stress, start: start.addingTimeInterval(60), value: 39),
            QuantitySample(kind: .stress, start: start.addingTimeInterval(180), value: 100),
        ]
        XCTAssertEqual(ZeppMetricMapping.stressSamples(from: parsed), expected,
                       "rawLevel > 100 is no reading: skipped, and the minutes after it keep their own time")
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed), expected, "the local store gets them")
    }

    func testStressNeverEntersTheHealthMappingOrAHealthKind() throws {
        let parsed = try ZeppRecordParser.parse(.autoStress, data: [0x20, 0x30], start: start)
        XCTAssertEqual(ZeppMetricMapping.samples(from: parsed), [], "the Apple-Health-clean mapping keeps stress out")
        XCTAssertNotNil(ZeppMetricMapping.deferredReason(for: .autoStress))
        XCTAssertFalse(HelioHealthPolicy.healthMirroredKinds().contains(.stress))
        XCTAssertFalse(HelioHealthPolicy.healthMirroredKinds(writesHRV: true).contains(.stress))
    }

    func testOnlyTheAutoStressRoundMapsToStress() throws {
        let hr = try ZeppRecordParser.parse(.restingHeartRate, data: le32(1_790_755_200) + [8, 55], start: start)
        XCTAssertEqual(ZeppMetricMapping.stressSamples(from: hr), [])
        XCTAssertFalse(ZeppMetricMapping.storedSamples(from: hr).contains { $0.kind == .stress })
    }

    func testAnAllNoReadingRoundStoresNothing() throws {
        let parsed = try ZeppRecordParser.parse(.autoStress, data: [UInt8](repeating: 0xff, count: 30), start: start)
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed), [])
    }

    // MARK: Backfill window

    /// 2026-09-30T12:34:56Z.
    private let now = date(1_790_772_896)
    private var weekBack: Date { HelioFetchPlan.floorToMinute(now.addingTimeInterval(-7 * 86_400)) }

    // MARK: When a backfill is due — "did another build advance the watermark?" (review-242b SF-1)

    func testABacklogLeftByAnOlderBuildIsRefetchedFromTheLedger() {
        // Build 60 ran for five days: it advanced the watermark and stored nothing. The ledger is
        // where this code left off, so the hole is exactly [ledger, watermark].
        let ledger = now.addingTimeInterval(-5 * 86_400)
        XCTAssertEqual(HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: ledger, notBefore: .distantPast),
                       ledger, "rewind to the ledger, not a blanket week")
    }

    func testAHoleOlderThanAWeekIsCappedAtTheLookback() {
        let ledger = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: ledger, notBefore: .distantPast),
                       weekBack)
    }

    func testTheFirstRunOnATimelineAnOlderBuildAdvancedGetsTheWeekBackfill() {
        // No ledger: build 59/60 moved this watermark before this code ever ran.
        XCTAssertEqual(HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: nil, notBefore: .distantPast),
                       weekBack)
        // …and with no watermark either there is nothing to rewind: the first fetch already reaches back.
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(watermark: nil, ledger: nil, notBefore: .distantPast))
    }

    /// The whole point of the ledger: every ordinary reason the strap reports no stress leaves the
    /// watermark exactly where this code put it, so none of them is ever a backfill.
    func testEveryOrdinaryGapLeavesTheBackfillNotDue() {
        for (name, watermark) in [("an ordinary 90-minute wear gap", now.addingTimeInterval(-5400)),
                                  ("an hour on the charger", now.addingTimeInterval(-3600)),
                                  ("stress monitoring off for days (#240)", now.addingTimeInterval(-3 * 86_400)),
                                  ("minutes the strap rotated out", now.addingTimeInterval(-30 * 86_400))] {
            XCTAssertNil(HelioFetchPlan.stressBackfillCursor(watermark: watermark, ledger: watermark,
                                                              notBefore: .distantPast), name)
        }
        // A ledger AHEAD of the watermark (an interrupted backfill's rewind) is not due either.
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(watermark: now.addingTimeInterval(-86_400),
                                                          ledger: now, notBefore: .distantPast))
    }

    func testTheRewindNeverReachesBeforeTheStrapsOwnershipStart() {
        // The ledger predates the switch: the ownership start wins, rounded UP to its minute.
        let owned = now.addingTimeInterval(-2 * 86_400 + 17)
        let target = HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: now.addingTimeInterval(-9 * 86_400),
                                                         notBefore: owned)
        XCTAssertNotNil(target)
        XCTAssertGreaterThanOrEqual(target!, owned, "not even the seconds before the switch")
        XCTAssertLessThan(target!.timeIntervalSince(owned), 60)
        // The plan built from it starts there, inside the strap's own time.
        let plan = HelioFetchPlan.plan(cursors: [.autoStress: target!], now: now, notBefore: owned)
        XCTAssertEqual(plan.first { $0.type == .autoStress }?.since, target)
    }

    func testNothingToMoveReturnsNil() {
        // The ownership start is at or after the watermark: no window left to refetch.
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: nil, notBefore: now))
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: nil,
                                                          notBefore: now.addingTimeInterval(3600)))
    }
}
