import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// #239: each metric through the day, for the ring and the strap. The strap's all-day stress through a
// real `HelioSession` against the simulated strap, the backfill's ledger rule, stress never reaching Apple
// Health, and the day charts' store reads (ownership, per-device series, the load check). Every
// key, reading and time is synthetic.

// MARK: - Fixtures

/// 2026-09-20T00:00:00Z. In the past, so `ingest`'s "not in the future" guard (real clock) passes.
private let sMidnight: TimeInterval = 1_789_862_400
private let sNow = Date(timeIntervalSince1970: sMidnight + 12 * 3600)
private let sKeyHex = "00112233445566778899aabbccddeeff"

private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// `count` stress minutes: level `i % 100`, every tenth minute `ff` (no reading).
private func stressData(_ count: Int) -> [UInt8] {
    (0..<count).map { $0 % 10 == 9 ? 0xff : UInt8($0 % 100) }
}

private let sServices: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let sDeviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

/// A strap holding only stress, `count` minutes from `start`.
private func makeStressStrap(start: TimeInterval, count: Int) -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(sKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
    device.services = sServices
    device.deviceInfoReply = sDeviceInfoReply
    device.dataPacketLength = 200
    device.fetchData = [.autoStress: (stamp(start), stressData(count))]
    return device
}

@MainActor
private final class StressTransport: HelioTransport {
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
private final class StressKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(sKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

private let storeTypes: [any PersistentModel.Type] = [
    StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
    StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
]

@MainActor
private func makeMemoryStore(_ containers: inout [ModelContainer]) throws -> LocalStore {
    let container = try ModelContainer(
        for: Schema(storeTypes),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    containers.append(container)
    return LocalStore(container.mainContext)
}

/// A store backed by a real file, for the load check: an in-memory container never touches SQLite, so
/// it cannot measure what a phone actually pays (review-242 SF-2).
@MainActor
private func makeOnDiskStore(_ containers: inout [ModelContainer], _ urls: inout [URL]) throws -> LocalStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("oc-intraday-\(UUID().uuidString).store")
    urls.append(url)
    let container = try ModelContainer(for: Schema(storeTypes), configurations: ModelConfiguration(url: url))
    containers.append(container)
    return LocalStore(container.mainContext)
}

// MARK: - The strap's stress history

@MainActor
final class StrapStressHistoryTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = sNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000C239"
    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func sync(_ device: FakeZeppDevice, store: LocalStore) -> HelioSession {
        let transport = StressTransport(device: device)
        let keys = StressKeys()
        let sink = HelioStoreSink(store: store)
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: sink, findState: HelioFindState(),
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = session
        session.start()
        transport.drain()
        return session
    }

    /// The *since* of every stress fetch the strap was asked for, in order.
    private func stressSinces(_ device: FakeZeppDevice) -> [Date] {
        device.fetchStarts.filter { $0.count == 10 && $0[1] == ZeppFetchType.autoStress.rawValue }
            .compactMap { ZeppFetchTimestamp.decode($0[2..<10]) }
    }

    private func stressRows(_ store: LocalStore) throws -> [StoredSample] {
        let kind = MetricKind.stress.rawValue
        return try store.context.fetch(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == kind },
                                                                     sortBy: [SortDescriptor(\.start)]))
    }

    func testABuild59StrapBackfillsAWeekOfStressOnceStoresEveryMinuteAndAcksKeep() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        // Build 59: the stress watermark advanced on every sync while nothing was stored, and it left
        // no ledger — which is exactly how this code recognises the hole.
        let staleWatermark = clock.addingTimeInterval(-600)
        store.stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: staleWatermark, device: timeline)
        try store.context.save()
        let start = clock.timeIntervalSince1970 - 3 * 86_400
        let device = makeStressStrap(start: start, count: 180)
        let session = sync(device, store: store)

        // The first stress round starts a week back from that watermark, once.
        let weekBack = HelioFetchPlan.floorToMinute(staleWatermark.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(stressSinces(device).first, weekBack)
        // The ledger now records where this code left the watermark, so the next sync is not due.
        XCTAssertNotNil(store.helioStressLedger(device: timeline))
        XCTAssertEqual(store.helioStressLedger(device: timeline),
                       store.helioFetchCursors(device: timeline)[.autoStress])
        // Decision 8: every round acked keep, the backfill changes nothing about that.
        XCTAssertFalse(device.fetchAcks.isEmpty)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])

        // Every minute with a reading is a `.stress` row on the strap's timeline; `ff` is skipped.
        let rows = try stressRows(store)
        XCTAssertEqual(rows.count, 162, "180 minutes minus 18 without a reading")
        XCTAssertTrue(rows.allSatisfy { $0.deviceID == self.timeline.rawValue && (0...100).contains($0.value) })
        XCTAssertEqual(rows.first?.start, Date(timeIntervalSince1970: start))
        XCTAssertEqual(rows.last?.start, Date(timeIntervalSince1970: start + 178 * 60))
        // The latest-value behaviour is kept for the Today card (which reads `lastSyncResult`).
        XCTAssertEqual(session.lastSyncResult?.latestStress?.value, 78)
        XCTAssertEqual(session.lastSyncResult?.latestStress?.at, Date(timeIntervalSince1970: start + 178 * 60))

        // The next sync: no second backfill, no duplicate rows.
        let cursorAfter = store.helioFetchCursors(device: timeline)[.autoStress]
        clock = clock.addingTimeInterval(600)
        let again = makeStressStrap(start: start, count: 180)
        sync(again, store: store)
        XCTAssertEqual(stressSinces(again).first, cursorAfter.map(HelioFetchPlan.floorToMinute))
        XCTAssertNotEqual(stressSinces(again).first, weekBack)
        XCTAssertEqual(try stressRows(store).count, 162)
        XCTAssertEqual(Set(again.fetchAcks), [0x09])
    }

    func testTheBackfillNeverFetchesOrStoresBeforeTheStrapsOwnershipStart() throws {
        // The ring owned everything before a switch two days ago (at a second that isn't a minute).
        let switchAt = clock.addingTimeInterval(-2 * 86_400 + 17)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makeMemoryStore(&containers)
        // An older build's watermark: advanced, with no ledger behind it.
        store.stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: clock.addingTimeInterval(-600),
                               device: timeline)
        try store.context.save()
        // The strap still holds stress from an hour before the switch to two hours after it.
        let start = switchAt.timeIntervalSince1970 - 17 - 3600
        let device = makeStressStrap(start: start, count: 180)
        sync(device, store: store)

        let since = try XCTUnwrap(stressSinces(device).first)
        XCTAssertGreaterThanOrEqual(since, switchAt, "the backfill never reaches the ring's time")
        XCTAssertEqual(since, switchAt.addingTimeInterval(43), "the switch's minute, rounded up")
        // Every other type keeps the ownership bound it already had.
        for c in device.fetchStarts where c.count == 10 {
            let s = try XCTUnwrap(ZeppFetchTimestamp.decode(c[2..<10]))
            XCTAssertGreaterThanOrEqual(s, HelioFetchPlan.floorToMinute(switchAt))
        }
        // What the strap delivered from before the switch is dropped at ingest.
        let rows = try stressRows(store)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.start >= switchAt })
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    /// A strap switched away from: nothing is rewound and no ledger is written, so when it is chosen
    /// again the hole is still judged from scratch, bounded by its new ownership start.
    func testNoBackfillAndNoLedgerWhileTheStrapDoesNotOwnThePresent() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: clock.addingTimeInterval(-86_400)),
                                                       .init(family: .ringConn, since: clock.addingTimeInterval(-3600))]))
        let store = try makeMemoryStore(&containers)
        let watermark = clock.addingTimeInterval(-600)
        // Staged directly: `setHelioFetchCursor` would write the ledger, which is the point under test.
        store.stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: watermark, device: timeline)
        try store.context.save()
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline))
        XCTAssertNil(store.helioStressLedger(device: timeline), "it waits for a sync the strap owns")
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.autoStress], watermark)
    }

    func testTheLedgerIsNotAFetchWatermark() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        // An older build's watermark: no ledger, so the first run backfills a week.
        store.stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: clock.addingTimeInterval(-600),
                               device: timeline)
        try store.context.save()
        let moved = store.applyHelioStressBackfillIfNeeded(device: timeline)
        XCTAssertEqual(moved, HelioFetchPlan.floorToMinute(clock.addingTimeInterval(-600 - 7 * 86_400)),
                       "a week back from the watermark the older build left")
        XCTAssertEqual(Set(store.helioFetchCursors(device: timeline).keys), [.autoStress],
                       "the ledger row is never read back as a fetch watermark")
        // The rewind carried the ledger, so nothing is due again.
        XCTAssertEqual(store.helioStressLedger(device: timeline), moved)
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline))
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.autoStress], moved)
        // The ring's timeline never gets a ledger or a watermark from this.
        XCTAssertNil(store.helioStressLedger(device: .ringConn))
    }

    // MARK: Is a backfill due? (review-242b SF-1)

    /// A sync by THIS code advancing the stress watermark, ledger and all.
    private func advanceStressWatermark(_ store: LocalStore, to date: Date) throws {
        try store.setHelioFetchCursor(.autoStress, to: date, device: timeline)
    }

    /// A sync by an OLDER build (59/60): it advances the watermark and stores nothing, leaving the
    /// ledger where this code last wrote it.
    private func olderBuildAdvancesStressWatermark(_ store: LocalStore, to date: Date) throws {
        store.stageHelioCursor(HelioFetchPlan.cursorName(for: .autoStress), to: date, device: timeline)
        try store.context.save()
    }

    /// 61 → 60 → 61. Build 60 advances `zepp.fetch.13` and drops the bytes, so its days are a hole.
    /// The ledger makes that hole exactly identifiable: one rewind, to the ledger, then none.
    func testARollbackToBuildSixtyRewindsOnceToTheLedger() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)

        // Build 61 running normally for a few days: watermark and ledger move together.
        let t0 = clock.addingTimeInterval(-10 * 86_400)
        try advanceStressWatermark(store, to: t0)
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline), "this code's own advance is no hole")
        let t1 = clock.addingTimeInterval(-5 * 86_400)
        try advanceStressWatermark(store, to: t1)
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline))

        // Five days on build 60: the watermark reaches now, the ledger stays at t1.
        try olderBuildAdvancesStressWatermark(store, to: clock)
        XCTAssertEqual(store.helioStressLedger(device: timeline), t1)
        let refill = store.applyHelioStressBackfillIfNeeded(device: timeline)
        XCTAssertEqual(refill, t1, "the hole is exactly [ledger, watermark]")
        XCTAssertEqual(store.helioStressLedger(device: timeline), t1, "the rewind carries the ledger with it")

        // …and never again, whatever the strap did or didn't return.
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline))
        try advanceStressWatermark(store, to: clock)
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline))
    }

    /// The SF-1 case: ordinary wear gaps must never cost a refetch. `ff` minutes advance the watermark
    /// through this code, so the ledger follows them and nothing is ever due.
    func testAnOrdinaryWearGapNeverRewinds() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        try advanceStressWatermark(store, to: clock.addingTimeInterval(-3 * 86_400))
        // 90 minutes with no reading: the watermark walked on, no row was stored.
        try advanceStressWatermark(store, to: clock.addingTimeInterval(-3 * 86_400 + 5400))
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline), "a 90-minute gap is not a hole")
    }

    /// An hour off the wrist every day for three days: zero rewinds (it used to be one per day).
    func testAnHourOffTheWristEachDayCostsNoRewinds() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        var rewinds = 0
        var at = clock.addingTimeInterval(-3 * 86_400)
        for _ in 0..<3 {
            at = at.addingTimeInterval(23 * 3600)          // worn
            try advanceStressWatermark(store, to: at)
            if store.applyHelioStressBackfillIfNeeded(device: timeline) != nil { rewinds += 1 }
            at = at.addingTimeInterval(3600)               // on the charger: `ff` minutes
            try advanceStressWatermark(store, to: at)
            if store.applyHelioStressBackfillIfNeeded(device: timeline) != nil { rewinds += 1 }
        }
        XCTAssertEqual(rewinds, 0)
    }

    /// Stress monitoring switched off on the strap (#240): the watermark walks through days of `ff`
    /// and no row is ever stored. Zero attempts — the old rule spent one per sync-with-a-new-row.
    func testStressMonitoringTurnedOffCostsNoAttempts() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        var attempts = 0
        for day in 0..<5 {
            try advanceStressWatermark(store, to: clock.addingTimeInterval(Double(day - 5) * 86_400))
            if store.applyHelioStressBackfillIfNeeded(device: timeline) != nil { attempts += 1 }
        }
        XCTAssertEqual(attempts, 0)
        XCTAssertNil(try stressRows(store).first, "nothing was stored, and nothing was refetched for it")
    }

    /// A backfill interrupted before its rounds land keeps its rewind: the ledger moved with the
    /// watermark, so the next sync is not due and simply fetches from the rewound point.
    func testAnInterruptedBackfillKeepsItsRewindAndIsNotRewoundAgain() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        try advanceStressWatermark(store, to: clock.addingTimeInterval(-6 * 86_400))
        try olderBuildAdvancesStressWatermark(store, to: clock)
        let target = try XCTUnwrap(store.applyHelioStressBackfillIfNeeded(device: timeline))

        // The process dies here: no rounds stored. The watermark is still the rewound one.
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.autoStress], target)
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline), "not rewound a second time")
        // And the plan still starts the fetch there, so the hole is filled on this next sync.
        let plan = HelioFetchPlan.plan(cursors: store.helioFetchCursors(device: timeline), now: clock,
                                       notBefore: .distantPast)
        XCTAssertEqual(plan.first { $0.type == .autoStress }?.since, HelioFetchPlan.floorToMinute(target))
    }

    /// Per timeline: one strap's ledger says nothing about another's, and each rewind is bounded by
    /// its own ownership start.
    func testTheLedgerIsPerTimelineAndBoundedByOwnership() throws {
        let switchAt = clock.addingTimeInterval(-2 * 86_400 + 17)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makeMemoryStore(&containers)
        let other = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-00000000C240")

        try olderBuildAdvancesStressWatermark(store, to: clock)
        let target = try XCTUnwrap(store.applyHelioStressBackfillIfNeeded(device: timeline))
        XCTAssertGreaterThanOrEqual(target, switchAt, "never into the ring's time")
        XCTAssertLessThan(target.timeIntervalSince(switchAt), 60, "the switch's minute, rounded up")
        // The other strap has no ledger and no watermark of its own: nothing to do, nothing written.
        XCTAssertNil(store.helioStressLedger(device: other))
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: other))
        XCTAssertNil(store.helioStressLedger(device: other))
    }

    /// A failed save moves neither the watermark nor the ledger.
    ///
    /// Driven through `context.rollback()` — the exact call the backfill's `catch` makes — rather than
    /// by contriving a SwiftData write error, so the test says something definite instead of depending
    /// on whether a given bad row happens to be rejected.
    func testAFailedSaveMovesNeitherTheWatermarkNorTheLedger() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        let watermark = clock.addingTimeInterval(-600)
        try olderBuildAdvancesStressWatermark(store, to: watermark)
        XCTAssertNil(store.helioStressLedger(device: timeline))

        // Stage the rewind exactly as the backfill does, then fail the save.
        let target = clock.addingTimeInterval(-7 * 86_400)
        store.stageHelioStressCursor(to: target, device: timeline)
        store.context.rollback()

        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.autoStress], watermark,
                       "the watermark stays where the older build left it")
        XCTAssertNil(store.helioStressLedger(device: timeline), "and no ledger is written")
        // The backfill is therefore still due, and succeeds on the next attempt — the two move together.
        let moved = try XCTUnwrap(store.applyHelioStressBackfillIfNeeded(device: timeline))
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.autoStress], moved)
        XCTAssertEqual(store.helioStressLedger(device: timeline), moved)
    }
}

// MARK: - Stress never reaches Apple Health

@MainActor
final class StressNeverReachesHealthTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-00000000F239")

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    func testAStoredStressSampleIsNeverHandedToOrWrittenByTheHealthWriter() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        let t0 = sNow.addingTimeInterval(-3600)
        let stress = (0..<30).map { QuantitySample(kind: .stress, start: t0.addingTimeInterval(Double($0) * 60), value: 40) }
        let hr = (0..<30).map { QuantitySample(kind: .heartRate, start: t0.addingTimeInterval(Double($0) * 60), value: 62) }
        XCTAssertEqual(try store.ingest(stress + hr, device: timeline).count, 60, "both are stored in the app")

        // The flush's selection: neither the strap's Health kinds nor the ring's include stress.
        let pending = try store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds())
        XCTAssertEqual(pending.count, 30)
        XCTAssertFalse(pending.contains { $0.kind == .stress })
        XCTAssertFalse(try store.pendingHealthSamples(device: timeline).contains { $0.kind == .stress })
        XCTAssertFalse(LocalStore.healthMirroredKinds.contains(.stress))

        // And the writer itself, handed stress directly, saves none of it.
        let writer = HealthKitWriter()
        var saved: [HKQuantitySample] = []
        writer.quantitySaveOverride = { saved += $0 }
        let outcome = await writer.write(pending + stress, timeline: timeline)
        XCTAssertEqual(saved.count, 30)
        XCTAssertTrue(saved.allSatisfy { $0.quantityType == HKQuantityType(.heartRate) })
        XCTAssertFalse(outcome.written.contains { $0.kind == .stress }, "no watermark moves for what wasn't written")
        XCTAssertTrue(outcome.failed.isEmpty)
    }
}

// MARK: - The day charts' store reads

@MainActor
final class DayTimelineLoadTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var storeURLs: [URL] = []
    private let ownership = OwnershipOverride()
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-00000000D239")
    /// A past local day, so every row passes `ingest`'s real-clock guard.
    private let dayStart = Calendar.current.startOfDay(for: sNow.addingTimeInterval(-86_400))
    private func at(_ minutes: Double) -> Date { dayStart.addingTimeInterval(minutes * 60) }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        for url in storeURLs {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        storeURLs.removeAll()
        super.tearDown()
    }

    private func insert(_ store: LocalStore, _ kind: MetricKind, _ minutes: [Double], value: (Double) -> Double,
                        device: SyncDeviceID) throws {
        for m in minutes {
            store.context.insert(StoredSample(QuantitySample(kind: kind, start: at(m), value: value(m)), device: device))
        }
        try store.context.save()
    }

    /// The load check, ON DISK (review-242 SF-2: an in-memory container never touches SQLite, so it
    /// can't measure what a phone pays). One synthetic strap day of per-minute HR and stress, and then
    /// the full 30-day retention window, both read through the off-main entry point. Times are printed
    /// for the report.
    func testAFullStrapDayAndAMonthOfHistoryLoadOffTheMainActorInTime() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeOnDiskStore(&containers, &storeURLs)
        // Day under test: 1440 per-minute HR + 288 stress (every 5 min).
        try insert(store, .heartRate, (0..<1440).map(Double.init), value: { 60 + $0.truncatingRemainder(dividingBy: 37) },
                   device: strap)
        try insert(store, .stress, (0..<288).map { Double($0) * 5 }, value: { $0.truncatingRemainder(dividingBy: 100) },
                   device: strap)

        let container = store.context.container
        let clock = ContinuousClock()
        /// Three runs, so the report can quote WARM numbers: the first load of a fresh store pays
        /// SQLite's cold cost and is several times the steady-state figure (review-242b FC-1).
        func measure(_ label: String, metrics: Set<DayTimeline.Metric>? = nil) async -> DayTimeline {
            var last: DayTimeline?
            var times: [String] = []
            for _ in 0..<3 {
                let elapsed = await clock.measure {
                    if let metrics {
                        last = await DayTimeline.loadAsync(container: container, day: dayStart, metrics: metrics)
                    } else {
                        last = await DayTimeline.loadAsync(container: container, day: dayStart)
                    }
                }
                times.append(String(format: "%.1f",
                                    Double(elapsed.components.seconds) * 1000
                                        + Double(elapsed.components.attoseconds) / 1e15))
            }
            print("DayTimeline load check (\(label)) ms, cold first then warm: \(times.joined(separator: " / "))")
            return last!
        }
        let timeline: DayTimeline? = await measure("on disk, 1 day stored, all cards")

        let hr = try XCTUnwrap(timeline?.day(.heartRate))
        XCTAssertEqual(hr.points.count, 1440)
        XCTAssertEqual(hr.series.map(\.family), [.zeppOS])
        XCTAssertEqual(hr.series.first?.bucketWidth, 300)
        XCTAssertEqual(hr.series.first?.buckets.count, 288)
        let stress = try XCTUnwrap(timeline?.day(.stress))
        XCTAssertEqual(stress.points.count, 288, "a stress of 0 is a reading, not a gap")
        XCTAssertEqual(stress.series.first?.buckets.count, 144)
        XCTAssertTrue(timeline?.showsStress == true)

        // Now 29 more days of the same density behind it: the retention window a strap user reaches
        // after a month (`LocalStore.sampleRetentionDays`). The day under test is unchanged.
        for day in 1..<30 {
            let offset = Double(day) * -1440
            try insert(store, .heartRate, (0..<1440).map { offset + Double($0) },
                       value: { 60 + $0.truncatingRemainder(dividingBy: 37) }, device: strap)
            try insert(store, .stress, (0..<1440).map { offset + Double($0) },
                       value: { $0.truncatingRemainder(dividingBy: 100) }, device: strap)
        }
        let monthTimeline: DayTimeline? = await measure("on disk, 30 days stored, all cards")
        _ = await measure("on disk, 30 days stored, one metric", metrics: [.heartRate])

        // The same day, read identically with a month of history behind it.
        XCTAssertEqual(monthTimeline?.day(.heartRate).points.count, 1440)
        XCTAssertEqual(monthTimeline?.day(.stress).points.count, 288)
        XCTAssertEqual(monthTimeline?.day(.heartRate).series.first?.buckets.count, 288)
    }

    /// The load really is off the main actor: it is `async` and its fetch is `nonisolated`, so a
    /// main-actor caller can await it without blocking. Asserted by calling the nonisolated core from
    /// a detached task (it would not compile if it required the main actor) and comparing the result.
    func testTheLoadRunsOffTheMainActorAndAgreesWithTheMainActorStore() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        try insert(store, .heartRate, (0..<240).map(Double.init), value: { 60 + $0.truncatingRemainder(dividingBy: 11) },
                   device: strap)
        let container = store.context.container
        let log = LocalStore.ownershipLog()
        let day = dayStart
        let detached = await Task.detached {
            DayTimeline.fetch(container: container, day: day, metrics: Set(DayTimeline.Metric.allCases),
                              calendar: .current, log: log)
        }.value
        let viaAsync = await DayTimeline.loadAsync(container: container, day: day)
        XCTAssertEqual(detached.day(.heartRate).points.count, 240)
        XCTAssertEqual(detached.day(.heartRate).points, viaAsync.day(.heartRate).points)
        XCTAssertEqual(detached.day(.heartRate).averages, viaAsync.day(.heartRate).averages)
    }

    /// Stepping through days fast must publish only the newest day's series. The views guard on
    /// `Task.isCancelled` AND on the day, so an older day's result can never land on a newer one; this
    /// pins the day-tagging the guard relies on.
    func testARapidDayChangePublishesOnlyTheNewestDay() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!
        try insert(store, .heartRate, (0..<60).map(Double.init), value: { _ in 61 }, device: strap)
        for minute in 0..<60 {
            store.context.insert(StoredSample(
                QuantitySample(kind: .heartRate, start: yesterday.addingTimeInterval(Double(minute) * 60), value: 77),
                device: strap))
        }
        try store.context.save()

        let container = store.context.container
        // Both days in flight at once, finishing in an arbitrary order.
        async let older = DayTimeline.loadAsync(container: container, day: yesterday, metrics: [.heartRate])
        async let newer = DayTimeline.loadAsync(container: container, day: dayStart, metrics: [.heartRate])
        let results = await [older, newer]

        // Each result carries the day it was asked for, which is what the views compare before they
        // publish; a late result for the day the view has left is dropped, never drawn over.
        XCTAssertEqual(results[0].day, DayTimeline.dayInterval(yesterday))
        XCTAssertEqual(results[1].day, DayTimeline.dayInterval(dayStart))
        XCTAssertNotEqual(results[0].day, results[1].day)
        XCTAssertEqual(results[0].day(.heartRate).points.map(\.value).first, 77)
        XCTAssertEqual(results[1].day(.heartRate).points.map(\.value).first, 61)
    }

    /// A ring-only install never fetches stress at all (there can be no strap rows), and a strap
    /// install does.
    func testOnlyTheCardsTheScreenShowsAreLoaded() {
        XCTAssertFalse(DayTimeline.metricsToLoad(log: DeviceOwnershipLog()).contains(.stress))
        XCTAssertEqual(DayTimeline.metricsToLoad(log: DeviceOwnershipLog()).count, 6)
        let strapLog = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(12 * 60))])
        XCTAssertTrue(DayTimeline.metricsToLoad(log: strapLog).contains(.stress))
        XCTAssertEqual(DayTimeline.metricsToLoad(log: strapLog).count, 7)
        // A strap-only install too (the first entry owns all past time).
        XCTAssertTrue(DayTimeline.metricsToLoad(log: .strapOwnsAllTime).contains(.stress))
    }

    func testASwitchMidDayGivesEachDeviceItsOwnTimeOnlyAndItsOwnAverage() async throws {
        let switchAt = at(12 * 60)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makeMemoryStore(&containers)
        // The ring every 5 minutes ALL day (its readings after the switch are the other device's time),
        // the strap every minute all day (its readings before the switch likewise).
        try insert(store, .heartRate, (0..<288).map { Double($0) * 5 }, value: { _ in 60 }, device: .ringConn)
        try insert(store, .heartRate, (0..<1440).map(Double.init), value: { _ in 70 }, device: strap)

        let timeline = await DayTimeline.loadAsync(container: store.context.container, day: dayStart)
        let hr = timeline.day(.heartRate)
        XCTAssertEqual(hr.series.map(\.family), [.ringConn, .zeppOS])
        XCTAssertEqual(hr.series[0].points.count, 144)
        XCTAssertTrue(hr.series[0].points.allSatisfy { $0.time < switchAt && $0.value == 60 })
        XCTAssertEqual(hr.series[1].points.count, 720)
        XCTAssertTrue(hr.series[1].points.allSatisfy { $0.time >= switchAt && $0.value == 70 })
        XCTAssertEqual(hr.averages, [.ringConn: 60, .zeppOS: 70])
        XCTAssertEqual(timeline.owners, [.ringConn, .zeppOS])
        XCTAssertTrue(timeline.namesDevices)
    }

    func testRingFingerAndStrapArmSkinTemperatureNeverShareALineOrAnAverage() async throws {
        let switchAt = at(12 * 60)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makeMemoryStore(&containers)
        try store.recordDaytimeTemperature(35.0, at: at(9 * 60))
        try store.recordDaytimeTemperature(35.4, at: at(10 * 60))
        try store.recordDaytimeTemperature(36.9, at: at(13 * 60))   // the ring, in the strap's time: not drawn
        try insert(store, .temperature, [13 * 60, 14 * 60, 15 * 60], value: { 32 + ($0 - 780) / 120 }, device: strap)
        try insert(store, .temperature, [3 * 60], value: { _ in 34.0 }, device: .ringConn)   // the ring's night rows: never on this chart

        let temp = await DayTimeline.loadAsync(container: store.context.container, day: dayStart).day(.skinTemp)
        XCTAssertEqual(temp.series.map(\.family), [.ringConn, .zeppOS])
        XCTAssertEqual(temp.series[0].points.map(\.value), [35.0, 35.4])
        XCTAssertEqual(temp.series[1].points.map(\.value), [32.0, 32.5, 33.0])
        XCTAssertEqual(temp.averages[.ringConn]!, 35.2, accuracy: 1e-9)
        XCTAssertEqual(temp.averages[.zeppOS]!, 32.5, accuracy: 1e-9)
    }

    func testARingOnlyInstallReadsExactlyTheRowsItReadBefore() async throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeMemoryStore(&containers)
        try insert(store, .heartRate, (0..<96).map { Double($0) * 15 }, value: { _ in 58 }, device: .ringConn)
        try insert(store, .heartRate, [600], value: { _ in 20 }, device: .ringConn)   // below the valid floor
        try store.recordDaytimeTemperature(35.1, at: at(600))
        try insert(store, .temperature, [180], value: { _ in 34.0 }, device: .ringConn)

        let timeline = await DayTimeline.loadAsync(container: store.context.container, day: dayStart)
        XCTAssertEqual(timeline.day(.heartRate).series.count, 1)
        XCTAssertEqual(timeline.day(.heartRate).points.count, 96, "the same HR filter as before #239")
        XCTAssertEqual(timeline.day(.skinTemp).points.map(\.value), [35.1], "daytime readings only, as before")
        XCTAssertEqual(timeline.owners, [.ringConn])
        XCTAssertFalse(timeline.namesDevices)
        XCTAssertFalse(timeline.showsStress)
    }

    func testStepsAreSplitByTheDeviceThatOwnedThem() {
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(12 * 60))])
        let rows: [(start: Date, end: Date, delta: Int)] = [
            (at(11 * 60 + 10), at(11 * 60 + 25), 300),   // the ring's quarter hour
            (at(12 * 60 + 1), at(12 * 60 + 2), 40),      // the strap's minutes
            (at(12 * 60 + 2), at(12 * 60 + 3), 35),
        ]
        let buckets = DayTimeline.hourlySteps(rows, log: log)
        XCTAssertEqual(buckets, [
            .init(hour: at(11 * 60), family: .ringConn, steps: 300),
            .init(hour: at(12 * 60), family: .zeppOS, steps: 75),
        ])
        // Ring-only: one ring bar per hour, the pre-#239 sum.
        XCTAssertEqual(DayTimeline.hourlySteps(rows, log: DeviceOwnershipLog()).map(\.family), [.ringConn, .ringConn])
    }

    func testASyncFinishingBumpsTheRevisionAnOpenDayChartReloadsOn() {
        let before = SyncRevision.shared.count
        SyncRevision.shared.syncFinished()
        XCTAssertEqual(SyncRevision.shared.count, before + 1)
    }
}

// MARK: - The strap's stress on Today (steer 3)

/// The strap card's number and the Today Stress tile read the newest STORED stress, so they survive a
/// sync without a stress round, a relaunch and a background wake — which `lastSyncResult` did not.
@MainActor
final class StrapStressTodayTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000C241"
    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }
    private let now = sNow

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func connect(_ device: FakeZeppDevice, store: LocalStore, autoSync: Bool = true) -> HelioSession {
        let transport = StressTransport(device: device)
        let keys = StressKeys()
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: HelioStoreSink(store: store), findState: HelioFindState(),
                                   clock: { [now] in now }, autoTick: false, autoSyncOnConnect: autoSync)
        transport.session = session
        session.start()
        transport.drain()
        return session
    }

    /// What the card and the tile read: the same load ContentView runs.
    private func tile(_ store: LocalStore, at time: Date? = nil) -> StrapStressTile? {
        StrapStressTile.load(container: store.context.container, log: LocalStore.ownershipLog(),
                             now: time ?? now, calendar: .current)
    }

    private func insertStress(_ store: LocalStore, _ value: Double, at time: Date, device: SyncDeviceID) throws {
        store.context.insert(StoredSample(QuantitySample(kind: .stress, start: time, value: value), device: device))
        try store.context.save()
    }

    func testTheCardsNumberSurvivesASyncWithNoStressRoundAndAFreshSession() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        // A sync that brings stress: 180 minutes ending two minutes ago (every tenth `ff`).
        let start = now.timeIntervalSince1970 - 3 * 3600
        let first = connect(makeStressStrap(start: start, count: 180), store: store)
        XCTAssertEqual(first.lastSyncResult?.latestStress?.value, 78)
        let expected = HelioReading(value: 78, at: Date(timeIntervalSince1970: start + 178 * 60))
        XCTAssertEqual(tile(store)?.currentReading(now: now), expected)

        // A later sync whose strap has no new stress minute: the old source goes blank…
        let quiet = FakeZeppDevice(authKey: ZeppHex.bytes(sKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                   random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        quiet.services = sServices
        quiet.deviceInfoReply = sDeviceInfoReply
        quiet.dataPacketLength = 200
        let second = connect(quiet, store: store)
        XCTAssertNil(second.lastSyncResult?.latestStress, "this is the flaw: the per-sync value is reset")
        // …but the card's number, read from the store, is still there.
        XCTAssertEqual(tile(store)?.currentReading(now: now), expected)

        // A fresh session that hasn't synced at all (a relaunch, or a background wake before the first
        // sync): no sync result, and the number is still there.
        let fresh = connect(quiet, store: store, autoSync: false)
        XCTAssertNil(fresh.lastSyncResult)
        XCTAssertEqual(tile(store)?.currentReading(now: now), expected)
    }

    func testTheNumberIsHiddenOnceTheNewestReadingIsOlderThanADay() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        // Older than 24 hours: no tile, no number.
        try insertStress(store, 50, at: now.addingTimeInterval(-24 * 3600 - 60), device: timeline)
        XCTAssertNil(tile(store))

        // 23 hours old: shown…
        try insertStress(store, 42, at: now.addingTimeInterval(-23 * 3600), device: timeline)
        let loaded = try XCTUnwrap(tile(store))
        XCTAssertEqual(loaded.currentReading(now: now)?.value, 42)
        // …until it ages past the day while the app stays open: checked at render, not only at load.
        XCTAssertFalse(loaded.isFresh(now: now.addingTimeInterval(2 * 3600)))
        XCTAssertNil(loaded.currentReading(now: now.addingTimeInterval(2 * 3600)))
        // Exactly 24 hours is still within the day.
        XCTAssertTrue(loaded.isFresh(now: now.addingTimeInterval(3600)))
    }

    func testTheTileAppearsForStrapStressWithItsBandAndTodaysReadings() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        let today = Calendar.current.startOfDay(for: now)
        // Every 5 minutes from local midnight to just before now: "relaxed" all day, then 45 ("mild").
        var times: [Date] = []
        var t = today
        while t < now.addingTimeInterval(-60) { times.append(t); t = t.addingTimeInterval(300) }
        XCTAssertGreaterThan(times.count, 1)
        let levels = times.indices.map { $0 == times.count - 1 ? 45.0 : 20.0 }
        for (time, level) in zip(times, levels) {
            store.context.insert(StoredSample(QuantitySample(kind: .stress, start: time, value: level), device: timeline))
        }
        try store.context.save()

        let loaded = try XCTUnwrap(tile(store))
        XCTAssertEqual(loaded.latest.value, 45)
        XCTAssertEqual(loaded.band, .mild, "Amazfit's word for 45")
        XCTAssertEqual(loaded.today.points.count, levels.count, "today's readings feed the sparkline")
        XCTAssertEqual(loaded.today.series.map(\.family), [.zeppOS])
        XCTAssertEqual(loaded.day, DayTimeline.dayInterval(now))
    }

    func testARingOnlyInstallNeverGetsTheTile() throws {
        // Empty log: the ring owns all time, and the ring never writes stress.
        ownership.install(DeviceOwnershipLog())
        let store = try makeMemoryStore(&containers)
        for minute in stride(from: 0.0, to: 600, by: 5) {
            store.context.insert(StoredSample(QuantitySample(kind: .heartRate, start: now.addingTimeInterval(-minute * 60),
                                                             value: 60), device: .ringConn))
        }
        try store.context.save()
        XCTAssertNil(tile(store), "a ring day has no stress tile")
        // Even a stress row on the ring's timeline (nothing writes one) is never read as the strap's.
        try insertStress(store, 70, at: now.addingTimeInterval(-600), device: .ringConn)
        XCTAssertNil(tile(store))
    }

    func testTheTileAndTheCardOpenTodaysStressChart() {
        XCTAssertEqual(Route.strapStress, .dayMetric(.stress))
    }

    func testTheDayCardsBandListMatchesTheTilesWords() {
        XCTAssertTrue(DayMetricCard.stressFootnote.contains("0–39 relaxed, 40–59 mild, 60–79 moderate, 80–100 high"))
    }
}

// MARK: - The Stress tile's edges (adopted from review-242c's probes, steer 4)

@MainActor
final class StrapStressTileEdgeTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let strap = SyncDeviceID(rawValue: "zeppos:AAAAAAAA-0000-4000-8000-000000000001")
    /// 2026-09-20 12:00 UTC.
    private let now = sNow

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func put(_ store: LocalStore, _ value: Double, at t: Date) throws {
        store.context.insert(StoredSample(QuantitySample(kind: .stress, start: t, value: value), device: strap))
        try store.context.save()
    }

    private func load(_ store: LocalStore, at time: Date) -> StrapStressTile? {
        StrapStressTile.load(container: store.context.container, log: .strapOwnsAllTime, now: time, calendar: .current)
    }

    /// The day card's footnote is generated from `HelioStressBand` now; it must still be byte-for-byte
    /// the text that shipped before that change.
    func testTheDayCardFootnoteIsByteIdenticalToTheShippedText() {
        let shipped = "The Helio Strap's all-day stress, 0 to 100, as the strap measures it. "
            + "It is not the ring's Overnight Stress score. Amazfit's bands: 0–39 relaxed, 40–59 mild, "
            + "60–79 moderate, 80–100 high. Stays in the app: Apple Health has no stress type."
        XCTAssertEqual(Array(DayMetricCard.stressFootnote.utf8), Array(shipped.utf8))
    }

    /// Exactly 24 hours old is shown, at load and at render; a millisecond past it is not.
    func testTheDayBoundaryIsInclusiveAtExactly24HoursAtLoadAndAtRender() throws {
        let edge = try makeMemoryStore(&containers)
        try put(edge, 40, at: now.addingTimeInterval(-86_400))
        let tile = try XCTUnwrap(load(edge, at: now), "exactly 24 h old is loaded")
        XCTAssertTrue(tile.isFresh(now: now))
        XCTAssertFalse(tile.isFresh(now: now.addingTimeInterval(0.001)), "a millisecond later it is hidden at render")

        let over = try makeMemoryStore(&containers)
        try put(over, 40, at: now.addingTimeInterval(-86_400.001))
        XCTAssertNil(load(over, at: now), "a millisecond past 24 h is not loaded")
    }

    /// The morning case: before the strap's first sync of the day the newest reading is last night's.
    /// It is still shown, labelled "Yesterday …" rather than a bare clock time, above an empty today.
    func testLastNightsReadingIsLabelledYesterday() throws {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        let lastNight = calendar.date(byAdding: .hour, value: -10, to: morning)!   // 23:00 the day before
        let store = try makeMemoryStore(&containers)
        try put(store, 45, at: lastNight)

        let tile = try XCTUnwrap(load(store, at: morning))
        XCTAssertFalse(calendar.isDate(tile.latest.at, inSameDayAs: morning))
        XCTAssertTrue(tile.today.points.isEmpty, "nothing yet today")
        XCTAssertEqual(tile.currentReading(now: morning)?.value, 45)
        let clock = lastNight.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(StrapStressTile.timeLabel(tile.latest.at, now: morning), "Yesterday \(clock)")
    }

    /// The one label the card and the tile share: bare time today, "Yesterday" before, weekday older.
    func testTheTimeLabelQualifiesEveryDayButToday() {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        let earlier = morning.addingTimeInterval(-3600)
        XCTAssertEqual(StrapStressTile.timeLabel(earlier, now: morning),
                       earlier.formatted(date: .omitted, time: .shortened), "today's reading: the clock time alone")
        let older = calendar.date(byAdding: .day, value: -3, to: morning)!
        XCTAssertEqual(StrapStressTile.timeLabel(older, now: morning),
                       "\(older.formatted(.dateTime.weekday(.abbreviated))) \(older.formatted(date: .omitted, time: .shortened))")
        XCTAssertFalse(StrapStressTile.timeLabel(older, now: morning).hasPrefix("Yesterday"))
    }

    /// A strap clock running ahead can store rows up to a day in the future. None is ever "latest" or
    /// fresh: the past reading is shown instead, and a future-only store shows nothing.
    func testAFutureDatedRowIsNeverLatestOrFresh() throws {
        let store = try makeMemoryStore(&containers)
        try put(store, 30, at: now.addingTimeInterval(-600))
        try put(store, 90, at: now.addingTimeInterval(3 * 3600))
        let tile = try XCTUnwrap(load(store, at: now))
        XCTAssertEqual(tile.latest.value, 30, "the future-dated 90 is excluded")
        XCTAssertTrue(tile.isFresh(now: now))

        let futureOnly = try makeMemoryStore(&containers)
        try put(futureOnly, 90, at: now.addingTimeInterval(3 * 3600))
        XCTAssertNil(load(futureOnly, at: now))

        let ahead = StrapStressTile(latest: HelioReading(value: 90, at: now.addingTimeInterval(60)),
                                    today: .empty, day: DayTimeline.dayInterval(now))
        XCTAssertFalse(ahead.isFresh(now: now), "a reading after now is never fresh")
        XCTAssertNil(ahead.currentReading(now: now))
    }

    /// The off-main entry point returns exactly what the core read returns.
    func testLoadAsyncEqualsLoad() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        let today = Calendar.current.startOfDay(for: now)
        var t = today
        var i = 0
        while t < now {
            store.context.insert(StoredSample(QuantitySample(kind: .stress, start: t, value: Double(i % 100)), device: strap))
            t = t.addingTimeInterval(300)
            i += 1
        }
        try store.context.save()
        let container = store.context.container
        let viaAsync = await StrapStressTile.loadAsync(container: container, now: now)
        let direct = StrapStressTile.load(container: container, log: LocalStore.ownershipLog(), now: now, calendar: .current)
        XCTAssertNotNil(direct)
        XCTAssertEqual(viaAsync, direct)
    }
}
