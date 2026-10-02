import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 45: the strap's PAI is STORED as phone-only `.pai` history and the card reads the store,
// so the number stops going blank after a sync that brought no `0x0d` record (about every sync: the
// record is daily) and after every relaunch. Plus the one-time rewind of the `0x0d` watermark builds
// 59–62 advanced without storing anything.
//
// Every key, reading and time here is synthetic: made-up totals, made-up times, floats written out
// byte by byte.

// MARK: - Fixtures

/// 2026-09-20T12:00:00Z. In the past, so `ingest`'s "not in the future" guard (real clock) passes.
private let pMidnight: TimeInterval = 1_789_862_400
private let pNow = Date(timeIntervalSince1970: pMidnight + 12 * 3600)
private let pKeyHex = "00112233445566778899aabbccddeeff"

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// One 102-byte `0x0d` record (ZEPP_PROTOCOL.md §6.5): u8 type, u32 ts, i8 tz, 31 unknown, three f32
/// zone totals, three u16 zone minutes, f32 today, f32 total, 39 unknown.
private func paiRecord(type: UInt8 = 0x05, at time: TimeInterval, total: Float) -> [UInt8] {
    var r: [UInt8] = [type] + le32(UInt32(time)) + [0x00] + [UInt8](repeating: 0x00, count: 31)
    for f in [Float(1), 2, 3] { r += le32(f.bitPattern) }
    r += le16(10) + le16(20) + le16(30)
    for f in [Float(4.5), total] { r += le32(f.bitPattern) }
    r += [UInt8](repeating: 0x00, count: 39)
    precondition(r.count == 102)
    return r
}

private let pServices: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let pDeviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func makeStrap() -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(pKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
    device.services = pServices
    device.deviceInfoReply = pDeviceInfoReply
    device.dataPacketLength = 200
    return device
}

/// A strap holding only PAI: one record per entry, announced from `start`.
private func makePAIStrap(start: TimeInterval, records: [(at: TimeInterval, total: Float)]) -> FakeZeppDevice {
    let device = makeStrap()
    let data = records.flatMap { paiRecord(at: $0.at, total: $0.total) }
    device.fetchData = [.pai: (stamp(start), data)]
    return device
}

@MainActor
private final class PAITransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }
    func has(_ c: ZeppCharacteristic) -> Bool { available.contains(c) }
    func canNotify(_ c: ZeppCharacteristic) -> Bool {
        has(c) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(c)
    }
    func write(_ write: ZeppWrite) {
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ c: ZeppCharacteristic, enabled: Bool) { inbox.append((c, nil, enabled)) }
    func read(_ c: ZeppCharacteristic) {
        switch c {
        case .hardwareRevision: inbox.append((c, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((c, [64], false))
        default: break
        }
    }
    func drain() {
        var n = 0
        while !inbox.isEmpty, n < 1_000_000 {
            n += 1
            let (c, bytes, enabled) = inbox.removeFirst()
            if let bytes { session?.received(c, bytes) } else { session?.notificationStateChanged(c, enabled: enabled, failed: false) }
        }
    }
}

@MainActor
private final class PAIKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(pKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

private let pStoreTypes: [any PersistentModel.Type] = [
    StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
    StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
]

@MainActor
private func makePAIStore(_ containers: inout [ModelContainer]) throws -> LocalStore {
    let container = try ModelContainer(for: Schema(pStoreTypes),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    containers.append(container)
    return LocalStore(container.mainContext)
}

// MARK: - A PAI round becomes `.pai` rows

@MainActor
final class StrapPAIHistoryTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = pNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D045"
    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func sync(_ device: FakeZeppDevice, store: LocalStore) -> HelioSession {
        let transport = PAITransport(device: device)
        let session = HelioSession(transport: transport, identityID: strapID, key: PAIKeys().load(),
                                   keyStore: PAIKeys(), sink: HelioStoreSink(store: store),
                                   findState: HelioFindState(), clock: { [unowned self] in self.clock },
                                   autoTick: false, autoSyncOnConnect: true)
        transport.session = session
        session.start()
        transport.drain()
        return session
    }

    private func paiRows(_ store: LocalStore) throws -> [StoredSample] {
        let kind = MetricKind.pai.rawValue
        return try store.context.fetch(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == kind },
                                                                     sortBy: [SortDescriptor(\.start)]))
    }

    /// Three days of PAI: one row each, value = TOTAL PAI (not today's), at the record's own time,
    /// on the strap's timeline. The round is acked keep (decision 8), and a re-sync adds nothing.
    func testAPAIRoundStoresOneRowPerRecordAtItsOwnTime() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let day: TimeInterval = 86_400
        let t0 = clock.timeIntervalSince1970 - 3 * day
        let device = makePAIStrap(start: t0, records: [(t0, 87.5), (t0 + day, 102.25), (t0 + 2 * day, 0)])
        sync(device, store: store)

        let rows = try paiRows(store)
        XCTAssertEqual(rows.map(\.value), [87.5, 102.25, 0], "value = total PAI; a total of 0 is a reading")
        XCTAssertEqual(rows.map(\.start), [t0, t0 + day, t0 + 2 * day].map { Date(timeIntervalSince1970: $0) })
        XCTAssertTrue(rows.allSatisfy { $0.deviceID == self.timeline.rawValue })
        XCTAssertFalse(rows.contains { $0.isDelta }, "PAI is not a cumulative counter")
        XCTAssertEqual(Set(device.fetchAcks), [0x09], "decision 8: keep on strap")

        // The same strap again: the `.pai` ingest cursor deduplicates, so no row is doubled.
        clock = clock.addingTimeInterval(600)
        let again = makePAIStrap(start: t0, records: [(t0, 87.5), (t0 + day, 102.25), (t0 + 2 * day, 0)])
        sync(again, store: store)
        XCTAssertEqual(try paiRows(store).count, 3)
    }

    /// Decision 28: a record from before the strap's ownership start is dropped at ingest. Nothing is
    /// lost — the ack stays `03 09`, so the strap keeps it.
    func testOnlyRecordsTheStrapOwnsAreStored() throws {
        let day: TimeInterval = 86_400
        let switchAt = clock.addingTimeInterval(-2 * day)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makePAIStore(&containers)
        let t0 = clock.timeIntervalSince1970 - 4 * day
        let device = makePAIStrap(start: t0, records: [(t0, 10), (t0 + day, 20),
                                                       (switchAt.timeIntervalSince1970 + 60, 30)])
        sync(device, store: store)

        let rows = try paiRows(store)
        XCTAssertEqual(rows.map(\.value), [30], "the two records from the ring's time are dropped")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    /// An empty `0x0d` round (the common case: no new record since the watermark) stores nothing and
    /// breaks nothing.
    func testAnEmptyPAIRoundStoresNothing() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let session = sync(makeStrap(), store: store)
        XCTAssertTrue(try paiRows(store).isEmpty)
        XCTAssertNil(session.lastSyncResult?.latestPAI)
    }

    /// Decision 15: PAI has no Apple Health type, so it is in no mirrored-kind list, never selected
    /// for the flush, and the writer saves none of it even when handed it directly.
    func testAStoredPAISampleIsNeverHandedToOrWrittenByTheHealthWriter() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let t0 = pNow.addingTimeInterval(-3600)
        let pai = (0..<3).map { QuantitySample(kind: .pai, start: t0.addingTimeInterval(Double($0) * 86_400 / 3),
                                               value: 50 + Double($0)) }
        let hr = (0..<30).map { QuantitySample(kind: .heartRate, start: t0.addingTimeInterval(Double($0) * 60), value: 62) }
        XCTAssertEqual(try store.ingest(pai + hr, device: timeline).count, 33, "both are stored in the app")

        let pending = try store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds())
        XCTAssertEqual(pending.count, 30)
        XCTAssertFalse(pending.contains { $0.kind == .pai })
        XCTAssertFalse(try store.pendingHealthSamples(device: timeline).contains { $0.kind == .pai })
        XCTAssertFalse(LocalStore.healthMirroredKinds.contains(.pai))
        XCTAssertFalse(HelioHealthPolicy.healthMirroredKinds().contains(.pai))
        XCTAssertFalse(HelioHealthPolicy.healthMirroredKinds(writesHRV: true).contains(.pai))

        let writer = HealthKitWriter()
        var saved: [HKQuantitySample] = []
        writer.quantitySaveOverride = { saved += $0 }
        let outcome = await writer.write(pending + pai, timeline: timeline)
        XCTAssertEqual(saved.count, 30)
        XCTAssertTrue(saved.allSatisfy { $0.quantityType == HKQuantityType(.heartRate) })
        XCTAssertFalse(outcome.written.contains { $0.kind == .pai }, "no watermark moves for what wasn't written")
        XCTAssertTrue(outcome.failed.isEmpty)
    }
}

// MARK: - The card's number

@MainActor
final class StrapPAICardTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = pNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000E045"
    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }
    private let now = pNow

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func connect(_ device: FakeZeppDevice, store: LocalStore, autoSync: Bool = true) -> HelioSession {
        let transport = PAITransport(device: device)
        let session = HelioSession(transport: transport, identityID: strapID, key: PAIKeys().load(),
                                   keyStore: PAIKeys(), sink: HelioStoreSink(store: store),
                                   findState: HelioFindState(), clock: { [now] in now },
                                   autoTick: false, autoSyncOnConnect: autoSync)
        transport.session = session
        session.start()
        transport.drain()
        return session
    }

    /// What the card reads: the same load `ContentView.loadTrends` runs.
    private func card(_ store: LocalStore, at time: Date? = nil) -> StrapPAIReading? {
        StrapPAIReading.load(container: store.context.container, now: time ?? now)
    }

    private func put(_ store: LocalStore, _ value: Double, at time: Date,
                     device: SyncDeviceID? = nil) throws {
        store.context.insert(StoredSample(QuantitySample(kind: .pai, start: time, value: value),
                                          device: device ?? timeline))
        try store.context.save()
    }

    /// The bug decision 45 fixes: the number survives a sync that brought no `0x0d` record, a sync
    /// whose `0x0d` round is empty, and a fresh session that hasn't synced at all (a relaunch).
    func testTheCardsNumberSurvivesASyncWithNoPAIRecordAndAFreshSession() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let t0 = now.timeIntervalSince1970 - 3600
        let first = connect(makePAIStrap(start: t0, records: [(t0, 64.5)]), store: store)
        XCTAssertEqual(first.lastSyncResult?.latestPAI?.value, 64.5)
        let expected = HelioReading(value: 64.5, at: Date(timeIntervalSince1970: t0))
        XCTAssertEqual(card(store)?.currentReading(now: now), expected)

        // A later sync whose strap answers the `0x0d` fetch empty: the old source goes blank…
        let quiet = makeStrap()
        let second = connect(quiet, store: store)
        XCTAssertNil(second.lastSyncResult?.latestPAI, "this is the flaw: the per-sync value is reset")
        // …but the card's number, read from the store, is still there.
        XCTAssertEqual(card(store)?.currentReading(now: now), expected)

        // A fresh session that hasn't synced at all (a relaunch, or a background wake before the
        // first sync): no sync result, and the number is still there.
        let fresh = connect(quiet, store: store, autoSync: false)
        XCTAssertNil(fresh.lastSyncResult)
        XCTAssertEqual(card(store)?.currentReading(now: now), expected)
    }

    /// 48 h is the bound (`StrapPAIReading.maxAge`): a daily, 7-day-rolling score survives one missed
    /// sync day, and is hidden past two.
    func testTheNumberIsHiddenOnceTheNewestReadingIsOlderThanTwoDays() throws {
        let old = try makePAIStore(&containers)
        try put(old, 50, at: now.addingTimeInterval(-48 * 3600 - 0.001))
        XCTAssertNil(card(old), "a millisecond past 48 h is not loaded")

        let store = try makePAIStore(&containers)
        // Exactly 48 h old is still inside the window, at load and at render.
        try put(store, 40, at: now.addingTimeInterval(-48 * 3600))
        let edge = try XCTUnwrap(card(store))
        XCTAssertTrue(edge.isFresh(now: now))
        XCTAssertFalse(edge.isFresh(now: now.addingTimeInterval(0.001)), "a millisecond later, hidden at render")
        XCTAssertNil(edge.currentReading(now: now.addingTimeInterval(0.001)))

        // 36 hours old — a missed sync day — is shown, where the stress tile's 24 h would blank it.
        let recent = try makePAIStore(&containers)
        try put(recent, 77, at: now.addingTimeInterval(-36 * 3600))
        XCTAssertEqual(card(recent)?.currentReading(now: now)?.value, 77)
        XCTAssertGreaterThan(StrapPAIReading.maxAge, StrapStressTile.maxAge)
    }

    /// The morning case: before the strap's first sync of the day the newest record is last night's,
    /// stamped near its end of day. It is shown with the day-qualified label the Stress tile uses, so
    /// "11:59 PM" can't read as today.
    func testLastNightsReadingIsLabelledYesterday() throws {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        let lastNight = calendar.date(byAdding: .minute, value: -(9 * 60 + 1), to: morning)!   // 23:59 before
        let store = try makePAIStore(&containers)
        try put(store, 96, at: lastNight)

        let loaded = try XCTUnwrap(card(store, at: morning))
        XCTAssertFalse(calendar.isDate(loaded.latest.at, inSameDayAs: morning))
        XCTAssertEqual(loaded.currentReading(now: morning)?.value, 96)
        let clockText = lastNight.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(StrapStressTile.timeLabel(loaded.latest.at, now: morning), "Yesterday \(clockText)",
                       "the card and the Stress tile share one label")
    }

    /// A strap clock running ahead can store rows up to a day in the future. None is ever "latest" or
    /// fresh: the past reading is shown instead, and a future-only store shows nothing
    /// (review-242c NIT 3).
    func testAFutureDatedRowIsNeverLatestOrFresh() throws {
        let store = try makePAIStore(&containers)
        try put(store, 30, at: now.addingTimeInterval(-600))
        try put(store, 90, at: now.addingTimeInterval(3 * 3600))
        let loaded = try XCTUnwrap(card(store))
        XCTAssertEqual(loaded.latest.value, 30, "the future-dated 90 is excluded")
        XCTAssertTrue(loaded.isFresh(now: now))

        let futureOnly = try makePAIStore(&containers)
        try put(futureOnly, 90, at: now.addingTimeInterval(3 * 3600))
        XCTAssertNil(card(futureOnly))

        let ahead = StrapPAIReading(latest: HelioReading(value: 90, at: now.addingTimeInterval(60)))
        XCTAssertFalse(ahead.isFresh(now: now), "a reading after now is never fresh")
        XCTAssertNil(ahead.currentReading(now: now))
    }

    /// A total PAI of 0 is a real reading (a week with no qualifying activity), so the card shows 0
    /// rather than nothing: no `value > 0` filter anywhere on this path.
    func testAZeroIsShownRatherThanTreatedAsNoReading() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let t0 = now.timeIntervalSince1970 - 3600
        connect(makePAIStrap(start: t0, records: [(t0, 0)]), store: store)
        let loaded = try XCTUnwrap(card(store), "a stored zero is still a reading")
        XCTAssertEqual(loaded.currentReading(now: now)?.value, 0)
    }

    /// A ring-only install never gets a number: nothing writes `.pai` on the ring's timeline, and the
    /// read ignores it outright if anything ever did.
    func testARingOnlyInstallNeverGetsANumber() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makePAIStore(&containers)
        XCTAssertNil(card(store))
        try put(store, 70, at: now.addingTimeInterval(-600), device: .ringConn)
        XCTAssertNil(card(store), "the ring's timeline is never read as the strap's")
    }

    /// The off-main entry point returns exactly what the core read returns.
    func testLoadAsyncEqualsLoad() async throws {
        let store = try makePAIStore(&containers)
        try put(store, 42, at: now.addingTimeInterval(-7200))
        let container = store.context.container
        let viaAsync = await StrapPAIReading.loadAsync(container: container, now: now)
        let direct = StrapPAIReading.load(container: container, now: now)
        XCTAssertNotNil(direct)
        XCTAssertEqual(viaAsync, direct)
    }
}

// MARK: - The one-time `0x0d` rewind

@MainActor
final class StrapPAIBackfillTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = pNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000F045"
    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    /// A sync by an OLDER build (59–62): it advances `zepp.fetch.0d` and stores nothing, leaving no
    /// ledger at all — which is exactly how this code recognises the hole.
    private func olderBuildAdvancesPAIWatermark(_ store: LocalStore, to date: Date) throws {
        store.stageHelioCursor(HelioFetchPlan.cursorName(for: .pai), to: date, device: timeline)
        try store.context.save()
    }

    func testTheRewindFiresOnceOnABuild62TimelineAndIsThenANoOp() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let watermark = clock.addingTimeInterval(-600)
        try olderBuildAdvancesPAIWatermark(store, to: watermark)
        XCTAssertNil(store.helioPAILedger(device: timeline))

        let moved = try XCTUnwrap(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertEqual(moved, HelioFetchPlan.floorToMinute(watermark.addingTimeInterval(-7 * 86_400)),
                       "a week back from the watermark the older build left")
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.pai], moved)
        XCTAssertEqual(store.helioPAILedger(device: timeline), moved, "the rewind carries its ledger")

        // Once, and never again.
        XCTAssertNil(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.pai], moved)
        // And the plan fetches from there, so the first sync after it fills the hole.
        let plan = HelioFetchPlan.plan(cursors: store.helioFetchCursors(device: timeline), now: clock,
                                       notBefore: .distantPast)
        XCTAssertEqual(plan.first { $0.type == .pai }?.since, moved)
    }

    /// The ledger is not a fetch watermark, and it is per type: rewinding PAI touches neither the
    /// stress watermark nor the stress ledger.
    func testThePAILedgerIsItsOwnRowAndNotAFetchWatermark() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        try olderBuildAdvancesPAIWatermark(store, to: clock.addingTimeInterval(-600))
        XCTAssertNotNil(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))

        XCTAssertEqual(Set(store.helioFetchCursors(device: timeline).keys), [.pai],
                       "neither ledger row is ever read back as a fetch watermark")
        XCTAssertEqual(LocalStore.helioPAILedgerName, "zepp.ledger.0d")
        XCTAssertEqual(LocalStore.helioStressLedgerName, "zepp.ledger.13")
        XCTAssertNil(store.helioStressLedger(device: timeline), "the stress ledger is untouched")
        XCTAssertNil(store.helioPAILedger(device: .ringConn), "and the ring's timeline gets nothing")
    }

    /// A watermark THIS code advanced is never a hole, however long the strap reported no PAI: quiet
    /// days, time on the charger, records the strap rotated out.
    func testAWatermarkThisCodeAdvancedNeverRewinds() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        var at = clock.addingTimeInterval(-10 * 86_400)
        var rewinds = 0
        for _ in 0..<5 {
            at = at.addingTimeInterval(86_400)
            try store.setHelioFetchCursor(.pai, to: at, device: timeline)
            if store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock) != nil { rewinds += 1 }
        }
        XCTAssertEqual(rewinds, 0)
        XCTAssertEqual(store.helioPAILedger(device: timeline), store.helioFetchCursors(device: timeline)[.pai],
                       "every advance wrote its ledger in the same save")
    }

    /// 63 → 62 → 63: build 62 advances `zepp.fetch.0d` and drops the records, so its days are a hole.
    /// The ledger identifies it exactly: one rewind, to the ledger, then none.
    func testARollbackToAnOlderBuildRewindsOnceToTheLedger() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let t1 = clock.addingTimeInterval(-5 * 86_400)
        try store.setHelioFetchCursor(.pai, to: t1, device: timeline)
        XCTAssertNil(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))

        try olderBuildAdvancesPAIWatermark(store, to: clock)
        XCTAssertEqual(store.helioPAILedger(device: timeline), t1)
        XCTAssertEqual(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock), t1,
                       "the hole is exactly [ledger, watermark]")
        XCTAssertNil(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
    }

    /// Decision 28: never into time the ring owned, not even by seconds.
    func testTheRewindNeverReachesBeforeTheStrapsOwnershipStart() throws {
        let switchAt = clock.addingTimeInterval(-2 * 86_400 + 17)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makePAIStore(&containers)
        try olderBuildAdvancesPAIWatermark(store, to: clock)
        let target = try XCTUnwrap(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertGreaterThanOrEqual(target, switchAt, "never into the ring's time")
        XCTAssertLessThan(target.timeIntervalSince(switchAt), 60, "the switch's minute, rounded up")
    }

    /// And never further back than the store's 30-day raw-sample retention: a `.pai` row older than
    /// that is deleted by the next prune, so refetching it is work whose rows can't survive.
    func testTheRewindNeverReachesBeforeTheSampleRetention() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let retentionFloor = clock.addingTimeInterval(-Double(LocalStore.sampleRetentionDays) * 86_400)
        // A strap left in a drawer: the watermark an older build left is 26 days old, so a bare
        // 7-day rewind would reach 33 days back — outside retention.
        try olderBuildAdvancesPAIWatermark(store, to: clock.addingTimeInterval(-26 * 86_400))
        let target = try XCTUnwrap(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertGreaterThanOrEqual(target, retentionFloor)
        XCTAssertLessThan(target.timeIntervalSince(retentionFloor), 60, "the retention minute, rounded up")

        // A watermark already outside retention has nothing worth refetching: no rewind at all.
        let stale = try makePAIStore(&containers)
        stale.stageHelioCursor(HelioFetchPlan.cursorName(for: .pai), to: clock.addingTimeInterval(-40 * 86_400),
                               device: timeline)
        try stale.context.save()
        XCTAssertNil(stale.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertNil(stale.helioPAILedger(device: timeline))
    }

    /// A strap switched away from: nothing is rewound and no ledger is written, so when it is chosen
    /// again the hole is judged from scratch against its new ownership start.
    func testNoRewindAndNoLedgerWhileTheStrapDoesNotOwnThePresent() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: clock.addingTimeInterval(-86_400)),
                                                       .init(family: .ringConn, since: clock.addingTimeInterval(-3600))]))
        let store = try makePAIStore(&containers)
        let watermark = clock.addingTimeInterval(-600)
        try olderBuildAdvancesPAIWatermark(store, to: watermark)
        XCTAssertNil(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertNil(store.helioPAILedger(device: timeline), "it waits for a sync the strap owns")
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.pai], watermark)
    }

    /// No watermark at all (a strap that has never synced): nothing to rewind, and no ledger written.
    /// The type's first fetch already reaches `firstSyncLookback` back.
    func testAFirstEverSyncHasNothingToRewind() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        XCTAssertNil(store.applyHelioPAIBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertNil(store.helioPAILedger(device: timeline))
    }

    /// End to end: a build-62 timeline's first sync on this code already stores PAI, so the card has
    /// a number straight away — the goal of decision 45's rewind.
    func testABuild62StrapShowsANumberOnItsFirstSync() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makePAIStore(&containers)
        let watermark = clock.addingTimeInterval(-600)
        try olderBuildAdvancesPAIWatermark(store, to: watermark)

        // The strap still holds the last three days of records (the acks were always `03 09`).
        let day: TimeInterval = 86_400
        let t0 = clock.timeIntervalSince1970 - 3 * day
        let device = makePAIStrap(start: t0, records: [(t0, 70), (t0 + day, 80), (t0 + 2 * day, 91.5)])
        let transport = PAITransport(device: device)
        let session = HelioSession(transport: transport, identityID: strapID, key: PAIKeys().load(),
                                   keyStore: PAIKeys(), sink: HelioStoreSink(store: store),
                                   findState: HelioFindState(), clock: { [clock] in clock },
                                   autoTick: false, autoSyncOnConnect: true)
        transport.session = session
        session.start()
        transport.drain()

        // The first `0x0d` fetch started a week back from the stale watermark, once.
        let sinces = device.fetchStarts.filter { $0.count == 10 && $0[1] == ZeppFetchType.pai.rawValue }
            .compactMap { ZeppFetchTimestamp.decode($0[2..<10]) }
        XCTAssertEqual(sinces.first, HelioFetchPlan.floorToMinute(watermark.addingTimeInterval(-7 * 86_400)))
        XCTAssertEqual(StrapPAIReading.load(container: store.context.container, now: clock)?
                        .currentReading(now: clock)?.value, 91.5)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }
}
