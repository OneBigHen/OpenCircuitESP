// The strap's all-day stress as history (#239): the mapping onto `.stress` and the one-time
// watermark backfill. Every fixture is synthetic: made-up levels, times chosen by hand.

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

    // MARK: One-time backfill

    /// 2026-09-30T12:34:56Z.
    private let now = date(1_790_772_896)
    private var weekBack: Date { HelioFetchPlan.floorToMinute(now.addingTimeInterval(-7 * 86_400)) }

    func testTheBackfillMovesTheStressWatermarkBackAWeekOnce() {
        let current = now.addingTimeInterval(-600)
        XCTAssertEqual(HelioFetchPlan.stressBackfillCursor(current: current, done: false, now: now, notBefore: .distantPast),
                       weekBack)
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(current: current, done: true, now: now, notBefore: .distantPast),
                     "once done, never again")
    }

    func testTheBackfillNeverReachesBeforeTheStrapsOwnershipStart() {
        let current = now.addingTimeInterval(-600)
        // The strap became the owner two days ago, at a second that isn't on a minute.
        let owned = now.addingTimeInterval(-2 * 86_400 + 17)
        let target = HelioFetchPlan.stressBackfillCursor(current: current, done: false, now: now, notBefore: owned)
        XCTAssertNotNil(target)
        XCTAssertGreaterThanOrEqual(target!, owned, "not even the seconds before the switch")
        XCTAssertLessThan(target!.timeIntervalSince(owned), 60)
        // And the fetch plan built from that watermark starts there, inside the strap's time.
        let plan = HelioFetchPlan.plan(cursors: [.autoStress: target!], now: now, notBefore: owned)
        let stressSince = plan.first { $0.type == .autoStress }!.since
        XCTAssertEqual(stressSince, target)
        XCTAssertGreaterThanOrEqual(stressSince, owned)
        // Every other type keeps its own start: only the stress watermark moved.
        let unchanged = HelioFetchPlan.plan(cursors: [.autoStress: current], now: now, notBefore: owned)
        for (a, b) in zip(plan, unchanged) where a.type != .autoStress { XCTAssertEqual(a.since, b.since, "\(a.type)") }
    }

    func testTheBackfillDoesNothingWhenTheStrapDoesNotOwnThePresent() {
        // `HelioStoreSink.notBefore` is `now` when the strap isn't the current owner.
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(current: now.addingTimeInterval(-600), done: false, now: now,
                                                         notBefore: now))
    }

    func testTheBackfillOnlyEverMovesTheWatermarkBack() {
        // Already a fortnight back (a strap that hasn't synced): leave it.
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(current: now.addingTimeInterval(-14 * 86_400), done: false,
                                                         now: now, notBefore: .distantPast))
        // No watermark at all: the first fetch already reaches a week back.
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(current: nil, done: false, now: now, notBefore: .distantPast))
        // Exactly at the target: nothing to move.
        XCTAssertNil(HelioFetchPlan.stressBackfillCursor(current: weekBack, done: false, now: now, notBefore: .distantPast))
    }
}
