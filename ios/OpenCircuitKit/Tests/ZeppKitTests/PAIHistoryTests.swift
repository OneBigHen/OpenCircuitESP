// The strap's PAI as history (decision 45): the mapping onto `.pai`, the kind's app-only shape, and
// the `0x0d` watermark backfill's ledger rule. Every fixture is synthetic: made-up totals, times
// chosen by hand, floats written out byte by byte.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

final class PAIHistoryTests: XCTestCase {
    /// 2026-09-30T08:00:00Z.
    private let start = date(1_790_755_200)

    /// One 102-byte `0x0d` record (ZEPP_PROTOCOL.md §6.5): type, u32 ts, i8 tz, 31 unknown, three
    /// f32 zone totals, three u16 zone minutes, f32 today, f32 total, 39 unknown.
    private func paiRecord(type: UInt8 = 0x05, ts: UInt32, total: Float, today: Float = 3.5) -> [UInt8] {
        var r: [UInt8] = [type] + le32(ts) + [0x08] + [UInt8](repeating: 0x00, count: 31)
        for f in [Float(1.0), 2.0, 3.0] { r += le32(f.bitPattern) }
        r += le16(10) + le16(20) + le16(30)
        for f in [today, total] { r += le32(f.bitPattern) }
        r += [UInt8](repeating: 0x00, count: 39)
        precondition(r.count == 102)
        return r
    }

    // MARK: Mapping

    func testEachKeptRecordBecomesOnePAISampleAtItsOwnTime() throws {
        let t0: UInt32 = 1_790_755_200
        let parsed = try ZeppRecordParser.parse(.pai, data:
            paiRecord(ts: t0, total: 87.5)
            + paiRecord(ts: t0 + 86_400, total: 102.25)
            + paiRecord(type: 0x00, ts: t0 + 2 * 86_400, total: 55)   // pre-reset: the parser drops it
            + paiRecord(ts: t0 + 3 * 86_400, total: 0),               // a real zero week
            start: start)
        let expected = [
            QuantitySample(kind: .pai, start: date(Double(t0)), value: 87.5),
            QuantitySample(kind: .pai, start: date(Double(t0) + 86_400), value: 102.25),
            QuantitySample(kind: .pai, start: date(Double(t0) + 3 * 86_400), value: 0),
        ]
        XCTAssertEqual(ZeppMetricMapping.paiSamples(from: parsed), expected,
                       "value = total PAI, start = the record's own time; a total of 0 is a real reading")
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed), expected, "the local store gets them")
        XCTAssertEqual(parsed.skippedRecords, 1)
    }

    /// A total of 0 is a week with no qualifying activity — a reading, not a missing one. Pinned on
    /// its own because every "no reading" convention in this protocol is a sentinel, not a zero.
    func testATotalOfZeroIsStoredAsAReading() throws {
        let parsed = try ZeppRecordParser.parse(.pai, data: paiRecord(ts: 1_790_755_200, total: 0), start: start)
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed),
                       [QuantitySample(kind: .pai, start: start, value: 0)])
    }

    /// SPEC-GAP: the `0x0d` float fields are 🟡. A non-finite or negative total is not a number the
    /// strap can mean, so it is skipped rather than stored (and can never poison the `.pai` cursor).
    func testANonFiniteOrNegativeTotalIsSkipped() throws {
        let t0: UInt32 = 1_790_755_200
        let parsed = try ZeppRecordParser.parse(.pai, data:
            paiRecord(ts: t0, total: .nan)
            + paiRecord(ts: t0 + 60, total: .infinity)
            + paiRecord(ts: t0 + 120, total: -1)
            + paiRecord(ts: t0 + 180, total: 12),
            start: start)
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed),
                       [QuantitySample(kind: .pai, start: date(Double(t0) + 180), value: 12)])
    }

    func testPAINeverEntersTheHealthMappingOrAHealthKind() throws {
        let parsed = try ZeppRecordParser.parse(.pai, data: paiRecord(ts: 1_790_755_200, total: 40), start: start)
        XCTAssertEqual(ZeppMetricMapping.samples(from: parsed), [], "the Apple-Health-clean mapping keeps PAI out")
        XCTAssertNotNil(ZeppMetricMapping.deferredReason(for: .pai))
        XCTAssertFalse(HelioHealthPolicy.healthMirroredKinds().contains(.pai))
        XCTAssertFalse(HelioHealthPolicy.healthMirroredKinds(writesHRV: true).contains(.pai))
    }

    func testOnlyAPAIRoundMapsToPAI() throws {
        let hr = try ZeppRecordParser.parse(.restingHeartRate, data: le32(1_790_755_200) + [8, 55], start: start)
        XCTAssertEqual(ZeppMetricMapping.paiSamples(from: hr), [])
        XCTAssertFalse(ZeppMetricMapping.storedSamples(from: hr).contains { $0.kind == .pai })
        let stress = try ZeppRecordParser.parse(.autoStress, data: [0x20, 0x30], start: start)
        XCTAssertEqual(ZeppMetricMapping.paiSamples(from: stress), [])
        XCTAssertFalse(ZeppMetricMapping.storedSamples(from: stress).contains { $0.kind == .pai })
    }

    func testAnEmptyPAIRoundStoresNothing() throws {
        let parsed = try ZeppRecordParser.parse(.pai, data: [], start: start)
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed), [])
        // Only pre-reset records: nothing kept either.
        let preReset = try ZeppRecordParser.parse(.pai, data: paiRecord(type: 0x00, ts: 1_790_755_200, total: 9),
                                                  start: start)
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: preReset), [])
    }

    // MARK: The kind itself

    /// `.pai` is a phone-only kind: no physical unit, not a cumulative counter, and in no export's
    /// unit block (which would change a shipped export schema).
    func testThePAIKindIsAppOnly() {
        XCTAssertEqual(MetricKind.pai.rawValue, "pai", "the raw value is a persistence key: it must not drift")
        XCTAssertEqual(MetricKind.pai.unit, "points")
        XCTAssertEqual(MetricKind.pai.displayName, "PAI")
        XCTAssertFalse(MetricKind.pai.isCumulativeCounter)
    }

    // MARK: Backfill window (decision 45, #239's exact-ledger rule)

    /// 2026-09-30T12:34:56Z.
    private let now = date(1_790_772_896)
    private var weekBack: Date { HelioFetchPlan.floorToMinute(now.addingTimeInterval(-7 * 86_400)) }

    func testABacklogLeftByAnOlderBuildIsRefetchedFromTheLedger() {
        let ledger = now.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(HelioFetchPlan.paiBackfillCursor(watermark: now, ledger: ledger, notBefore: .distantPast),
                       ledger, "rewind to the ledger, not a blanket week")
    }

    /// Builds 59–62: they advanced `zepp.fetch.0d` and stored nothing, and no build ever wrote a PAI
    /// ledger — so the first run of this code on such a timeline gets the week.
    func testTheFirstRunOnATimelineAnOlderBuildAdvancedGetsTheWeekBackfill() {
        XCTAssertEqual(HelioFetchPlan.paiBackfillCursor(watermark: now, ledger: nil, notBefore: .distantPast),
                       weekBack)
        XCTAssertNil(HelioFetchPlan.paiBackfillCursor(watermark: nil, ledger: nil, notBefore: .distantPast),
                     "no watermark: the type's first fetch already reaches back")
    }

    func testAHoleOlderThanAWeekIsCappedAtTheLookback() {
        XCTAssertEqual(HelioFetchPlan.paiBackfillCursor(watermark: now, ledger: now.addingTimeInterval(-30 * 86_400),
                                                        notBefore: .distantPast), weekBack)
    }

    /// The whole point of the ledger: every ordinary reason the strap reports no PAI — days with no
    /// qualifying activity, the strap on the charger, records it rotated out — leaves the watermark
    /// exactly where this code put it, and is never a backfill.
    func testEveryOrdinaryGapLeavesTheBackfillNotDue() {
        for (name, watermark) in [("a quiet day with no new record", now.addingTimeInterval(-86_400)),
                                  ("three days off the wrist", now.addingTimeInterval(-3 * 86_400)),
                                  ("records the strap rotated out", now.addingTimeInterval(-30 * 86_400))] {
            XCTAssertNil(HelioFetchPlan.paiBackfillCursor(watermark: watermark, ledger: watermark,
                                                          notBefore: .distantPast), name)
        }
        // A ledger AHEAD of the watermark (an interrupted backfill's rewind) is not due either.
        XCTAssertNil(HelioFetchPlan.paiBackfillCursor(watermark: now.addingTimeInterval(-86_400), ledger: now,
                                                      notBefore: .distantPast))
    }

    func testTheRewindNeverReachesBeforeTheStrapsOwnershipStart() {
        let owned = now.addingTimeInterval(-2 * 86_400 + 17)
        let target = HelioFetchPlan.paiBackfillCursor(watermark: now, ledger: now.addingTimeInterval(-9 * 86_400),
                                                      notBefore: owned)
        XCTAssertNotNil(target)
        XCTAssertGreaterThanOrEqual(target!, owned, "not even the seconds before the switch")
        XCTAssertLessThan(target!.timeIntervalSince(owned), 60)
        let plan = HelioFetchPlan.plan(cursors: [.pai: target!], now: now, notBefore: owned)
        XCTAssertEqual(plan.first { $0.type == .pai }?.since, target)
    }

    func testNothingToMoveReturnsNil() {
        XCTAssertNil(HelioFetchPlan.paiBackfillCursor(watermark: now, ledger: nil, notBefore: now))
        XCTAssertNil(HelioFetchPlan.paiBackfillCursor(watermark: now, ledger: nil,
                                                      notBefore: now.addingTimeInterval(3600)))
    }

    /// The two backfills share one rule and differ only in their lookback, so stress keeps #239's
    /// behaviour byte for byte.
    func testTheStressAndPAIRulesAreTheSameRuleWithTheirOwnLookback() {
        XCTAssertEqual(HelioFetchPlan.paiBackfillLookback, 7 * 86_400)
        for (ledger, notBefore) in [(nil as Date?, Date.distantPast),
                                    (now.addingTimeInterval(-3 * 86_400), .distantPast),
                                    (now.addingTimeInterval(-9 * 86_400), now.addingTimeInterval(-86_400))] {
            XCTAssertEqual(HelioFetchPlan.paiBackfillCursor(watermark: now, ledger: ledger, notBefore: notBefore),
                           HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: ledger, notBefore: notBefore),
                           "equal lookbacks, so the two agree everywhere")
            XCTAssertEqual(HelioFetchPlan.stressBackfillCursor(watermark: now, ledger: ledger, notBefore: notBefore),
                           HelioFetchPlan.backfillCursor(watermark: now, ledger: ledger, notBefore: notBefore,
                                                         lookback: HelioFetchPlan.stressBackfillLookback))
        }
    }
}
