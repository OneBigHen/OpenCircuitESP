import XCTest
@testable import OpenCircuitKit

/// Per-device sync cursors (#214, docs/DEVICE_SEAM.md §3). All timestamps synthetic.
final class SyncDeviceTests: XCTestCase {
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-1")
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func hr(_ value: Double, _ date: Date) -> QuantitySample {
        QuantitySample(kind: .heartRate, start: date, value: value)
    }

    // MARK: Device ids

    /// The literal the SchemaV8 column defaults spell out. Changing it re-labels every migrated row.
    func testTheRingTimelineIdIsPinned() {
        XCTAssertEqual(SyncDeviceID.ringConn.rawValue, "ringconn")
    }

    /// Every RingConn ring shares ONE timeline — multi-ring merged before this change and still does.
    func testEveryRingSharesOneTimeline() {
        for generation in [RingGeneration.gen1, .gen2, .gen2Air, .gen3, .unknown] {
            XCTAssertEqual(SyncDeviceID.timeline(for: .ringConn(model: generation), identityID: "RING-A"),
                           .ringConn)
            XCTAssertEqual(SyncDeviceID.timeline(for: .ringConn(model: generation), identityID: "RING-B"),
                           .ringConn)
        }
    }

    func testEachZeppDeviceHasItsOwnTimeline() {
        let other = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Ring"), identityID: "RING-9")
        XCTAssertNotEqual(strap, .ringConn)
        XCTAssertNotEqual(strap, other)
        XCTAssertEqual(strap, SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "STRAP-1"),
                       "the model string must not split one device's timeline")
    }

    // MARK: Keys

    /// The ring's keys are the pre-V8 keys, byte for byte — no stored row is rewritten.
    func testTheRingsKeysAreUnchanged() {
        for name in ["heartRate", "hk:heartRate", "export:sleepSessions", "sleep"] {
            XCTAssertEqual(SyncCursorKey.key(name, device: .ringConn), name)
            XCTAssertEqual(SyncCursorKey.name(fromKey: name, device: .ringConn), name)
        }
    }

    func testAnotherDevicesKeysRoundTripAndKeepTheirPrefix() {
        let key = SyncCursorKey.key("hk:heartRate", device: strap)
        XCTAssertNotEqual(key, "hk:heartRate", "must not collide with the ring's row")
        XCTAssertTrue(key.hasPrefix("hk:"), "prefix filters (hk:, export:) must keep working")
        XCTAssertEqual(SyncCursorKey.name(fromKey: key, device: strap), "hk:heartRate")
    }

    func testAKeyIsNeverReadAsAnotherDevicesKey() {
        let other = SyncDeviceID(rawValue: "zeppos:OTHER")
        XCTAssertNil(SyncCursorKey.name(fromKey: "heartRate", device: strap))
        XCTAssertNil(SyncCursorKey.name(fromKey: SyncCursorKey.key("heartRate", device: other), device: strap))
    }

    // MARK: Per-device cursor

    /// With only the ring present, the per-device cursor is exactly the map the store built before.
    func testRingOnlyCursorIsTheOldCursor() {
        let rows: [(key: String, device: String, last: Date)] = [
            ("heartRate", "ringconn", t0), ("spo2", "ringconn", t0.addingTimeInterval(-60)),
            ("sleep", "ringconn", t0.addingTimeInterval(-3600)),
        ]
        let old = SyncCursor(lastByKind: ["heartRate": t0, "spo2": t0.addingTimeInterval(-60),
                                          "sleep": t0.addingTimeInterval(-3600)])
        XCTAssertEqual(SyncCursor.forDevice(.ringConn, rows: rows), old)
    }

    /// THE BUG THIS FIXES. The ring's HR watermark is at t0. A strap joins and backfills three days
    /// that are all OLDER than t0. One global cursor dropped every one of them; the strap's own
    /// cursor keeps them all — and the ring's cursor does not move.
    func testANewDevicesBackfillOlderThanTheRingsWatermarkIsKept() {
        let backfill = (1...3).map { hr(60 + Double($0), t0.addingTimeInterval(-86_400 * Double($0))) }

        var global = SyncCursor(lastByKind: ["heartRate": t0])
        XCTAssertEqual(global.selectNew(backfill), [], "the pre-#214 behaviour: all silently dropped")

        let rows: [(key: String, device: String, last: Date)] = [("heartRate", "ringconn", t0)]
        let (fresh, advanced) = SyncCursor.forDevice(strap, rows: rows).selectNewStaged(backfill)
        XCTAssertEqual(fresh.count, 3)
        XCTAssertEqual(advanced.last(.heartRate), t0.addingTimeInterval(-86_400))
        XCTAssertEqual(SyncCursor.forDevice(.ringConn, rows: rows).last(.heartRate), t0)
    }

    /// And the ring is still judged against its OWN watermark once a strap has advanced past it.
    func testTheRingIsNotAffectedByAnotherDevicesRows() {
        let rows: [(key: String, device: String, last: Date)] = [
            ("heartRate", "ringconn", t0),
            (SyncCursorKey.key("heartRate", device: strap), strap.rawValue, t0.addingTimeInterval(86_400)),
        ]
        var ring = SyncCursor.forDevice(.ringConn, rows: rows)
        XCTAssertEqual(ring.last(.heartRate), t0)
        XCTAssertEqual(ring.selectNew([hr(70, t0.addingTimeInterval(60))]).count, 1)
    }
}
