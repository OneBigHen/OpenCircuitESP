import XCTest
@testable import OpenCircuitKit

/// Decision 28 of #215: the chosen device owns the time it was chosen for. Synthetic times only.
final class DeviceOwnershipTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let strap = SyncDeviceID(rawValue: "zeppos:TEST")

    func testAnEmptyLogIsTheRingForAllTime() {
        let log = DeviceOwnershipLog()
        XCTAssertTrue(log.isEmpty)
        for t in [Date.distantPast, t0, Date.distantFuture] {
            XCTAssertEqual(log.owner(at: t), .ringConn)
            XCTAssertTrue(log.owns(.ringConn, at: t))
            XCTAssertFalse(log.owns(strap, at: t))
        }
        XCTAssertEqual(log.currentStart(of: .ringConn), .distantPast)
        XCTAssertNil(log.currentStart(of: .zeppOS))
        XCTAssertEqual(log.intervals(of: .ringConn).count, 1)
        XCTAssertTrue(log.intervals(of: .zeppOS).isEmpty)
    }

    func testOwnerIsTheLatestEntryAtOrBeforeT() {
        var log = DeviceOwnershipLog()
        XCTAssertFalse(log.record(.ringConn, since: t0), "the ring already owns the present")
        XCTAssertTrue(log.record(.zeppOS, since: t0))
        XCTAssertTrue(log.record(.ringConn, since: t0 + 3600))
        XCTAssertEqual(log.owner(at: t0 - 1), .ringConn, "the ring owns everything before the first entry")
        XCTAssertEqual(log.owner(at: t0), .zeppOS, "an entry owns from its own instant")
        XCTAssertEqual(log.owner(at: t0 + 3599), .zeppOS)
        XCTAssertEqual(log.owner(at: t0 + 3600), .ringConn)
        XCTAssertTrue(log.owns(strap, at: t0 + 60))
        XCTAssertFalse(log.owns(.ringConn, at: t0 + 60))
        XCTAssertEqual(log.currentStart(of: .ringConn), t0 + 3600)
        XCTAssertNil(log.currentStart(of: .zeppOS))
        let strapIntervals = log.intervals(of: .zeppOS)
        XCTAssertEqual(strapIntervals.count, 1)
        XCTAssertEqual(strapIntervals.first?.start, t0)
        XCTAssertEqual(strapIntervals.first?.end, t0 + 3600)
        XCTAssertEqual(log.intervals(of: .ringConn).map(\.start), [.distantPast, t0 + 3600])
    }

    func testTheLogOnlyRecordsChanges() {
        var log = DeviceOwnershipLog()
        XCTAssertTrue(log.record(.zeppOS, since: t0))
        XCTAssertFalse(log.record(.zeppOS, since: t0 + 60), "already the owner: no entry")
        XCTAssertEqual(log.entries.count, 1)
    }

    func testTheOwnershipStartIsTheStretchContainingT() {
        XCTAssertEqual(DeviceOwnershipLog().ownershipStart(at: t0), .distantPast, "an empty log clamps nothing")
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: t0), .init(family: .ringConn, since: t0 + 3600)])
        XCTAssertEqual(log.ownershipStart(at: t0 - 1), .distantPast)
        XCTAssertEqual(log.ownershipStart(at: t0), t0)
        XCTAssertEqual(log.ownershipStart(at: t0 + 3599), t0)
        XCTAssertEqual(log.ownershipStart(at: t0 + 3600), t0 + 3600)
        XCTAssertEqual(log.ownershipStart(at: .distantFuture), t0 + 3600)
    }

    func testAClockThatMovedBackIsClampedToTheLastEntry() {
        var log = DeviceOwnershipLog()
        log.record(.zeppOS, since: t0)
        log.record(.ringConn, since: t0 - 7200)
        XCTAssertEqual(log.entries.last?.since, t0, "monotonic")
        XCTAssertEqual(log.owner(at: t0), .ringConn)
        XCTAssertTrue(log.intervals(of: .zeppOS).isEmpty, "a zero-length ownership owns nothing")
        // Decoding a log keeps the rule.
        let decoded = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: t0), .init(family: .ringConn, since: t0 - 1)])
        XCTAssertEqual(decoded.entries.map(\.since), [t0, t0])
    }

    func testAStrapOnlyInstallOwnsAllTime() {
        var log = DeviceOwnershipLog()
        log.record(.zeppOS, since: .distantPast)
        XCTAssertEqual(log.owner(at: t0 - 86_400 * 365), .zeppOS)
        XCTAssertEqual(log.currentStart(of: .zeppOS), .distantPast)
        XCTAssertTrue(log.intervals(of: .ringConn).isEmpty)
    }

    /// Decision 28a: the device you went to bed with keeps the night, however late the switch.
    func testANightBelongsToTheDeviceYouWentToBedWith() {
        var log = DeviceOwnershipLog()
        log.record(.zeppOS, since: t0)   // switched at t0
        XCTAssertEqual(log.owner(ofNightFrom: t0 - 3600, to: t0 + 7 * 3600), .ringConn,
                       "a switch an hour into the night leaves it the ring's (the midpoint rule said strap)")
        XCTAssertEqual(log.owner(ofNightFrom: t0 - 7 * 3600, to: t0 + 3600), .ringConn)
        XCTAssertEqual(log.owner(ofNightFrom: t0 + 60, to: t0 + 8 * 3600), .zeppOS, "switched before bed")
        XCTAssertEqual(log.owner(ofNightFrom: t0, to: t0 + 8 * 3600), .zeppOS,
                       "a switch at exactly the in-bed start goes to the NEW device (made before bed)")
        log.record(.ringConn, since: t0 + 3 * 3600)   // and back, mid-night
        XCTAssertEqual(log.owner(ofNightFrom: t0 - 3600, to: t0 + 7 * 3600), .ringConn,
                       "two switches inside: the owner just before the first")
        XCTAssertEqual(log.owner(ofNightFrom: t0 + 3600, to: t0 + 7 * 3600), .zeppOS)
        XCTAssertEqual(DeviceOwnershipLog.midpoint(t0, t0), t0, "naps keep the midpoint rule")
    }

    /// Decision 29: a baseline uses only the newest item's device; an empty log changes nothing.
    func testBaselinesKeepToTheNewestItemsDevice() {
        let nights = (0..<6).map { t0 + Double($0) * 86_400 }
        XCTAssertEqual(DeviceOwnershipLog().sameDeviceAsNewest(nights, time: { $0 }), nights)
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: nights[4] - 3600)])
        XCTAssertEqual(log.sameDeviceAsNewest(nights, time: { $0 }), [nights[4], nights[5]], "the strap's own nights only")
        XCTAssertEqual(log.sameDeviceAsNewest(Array(nights.prefix(4)), time: { $0 }), Array(nights.prefix(4)),
                       "judging a ring night uses the ring's nights")
        XCTAssertEqual(log.only(.ringConn, nights, time: { $0 }), Array(nights.prefix(4)))
        XCTAssertTrue(log.isOwn(recordedBy: strap, at: nights[5], by: .zeppOS))
        XCTAssertFalse(log.isOwn(recordedBy: .ringConn, at: nights[5], by: .ringConn), "the ring's catch-up of strap time")
        XCTAssertFalse(log.isOwn(recordedBy: .ringConn, at: nights[5], by: .zeppOS))
        XCTAssertTrue(DeviceOwnershipLog().isOwn(recordedBy: .ringConn, at: nights[5], by: .ringConn))
    }

    func testFamiliesMapFromTimelines() {
        XCTAssertEqual(DeviceOwnershipLog.Family(timeline: .ringConn), .ringConn)
        XCTAssertEqual(DeviceOwnershipLog.Family(timeline: strap), .zeppOS)
        XCTAssertEqual(DeviceOwnershipLog.Family.ringConn.rawValue, "ringConn", "persisted")
        XCTAssertEqual(DeviceOwnershipLog.Family.zeppOS.rawValue, "zeppOS", "persisted")
    }

    func testTheNewSleepOutcomeIsADeliberateKeep() {
        XCTAssertFalse(SleepPersistOutcome.ownedByOtherDevice.wroteRow)
        XCTAssertTrue(SleepPersistOutcome.ownedByOtherDevice.nightIsStored)
        XCTAssertFalse(SleepPersistOutcome.ownedByOtherDevice.isSilentLoss)
        XCTAssertEqual(SleepPersistOutcome.ownedByOtherDevice.rawValue, "ownedByOtherDevice")
    }

    /// Review-224b N-3: when the other device owns the night but stored none, the wearer has no night.
    func testAnOwnedNightWithNoStoredRowIsNotStored() {
        let o = SleepPersistOutcome.ownedByOtherDeviceNoRow
        XCTAssertFalse(o.wroteRow)
        XCTAssertFalse(o.nightIsStored)
        XCTAssertTrue(o.isSilentLoss, "the card must not hide the gap")
        XCTAssertFalse(o.isRecoverableByRetry, "this device syncing again can't store it")
        XCTAssertEqual(o.rawValue, "ownedByOtherDeviceNoRow")
    }
}
