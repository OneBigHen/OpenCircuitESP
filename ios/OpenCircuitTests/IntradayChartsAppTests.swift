import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// #239: each metric through the day, for the ring and the strap. The strap's all-day stress through a
// real `HelioSession` against the simulated strap, the one-time backfill, stress never reaching Apple
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

@MainActor
private func makeMemoryStore(_ containers: inout [ModelContainer]) throws -> LocalStore {
    let container = try ModelContainer(
        for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
        StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
        sink.clock = { [unowned self] in self.clock }
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
        // Build 59: the stress watermark advanced on every sync while nothing was stored.
        try store.setHelioFetchCursor(.autoStress, to: clock.addingTimeInterval(-600), device: timeline)
        let start = clock.timeIntervalSince1970 - 3 * 86_400
        let device = makeStressStrap(start: start, count: 180)
        let session = sync(device, store: store)

        // The first stress round starts a week back, once.
        let weekBack = HelioFetchPlan.floorToMinute(clock.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(stressSinces(device).first, weekBack)
        XCTAssertTrue(store.helioStressBackfillDone(device: timeline))
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
        try store.setHelioFetchCursor(.autoStress, to: clock.addingTimeInterval(-600), device: timeline)
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

    func testNoBackfillAndNoFlagWhileTheStrapDoesNotOwnThePresent() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: clock.addingTimeInterval(-86_400)),
                                                       .init(family: .ringConn, since: clock.addingTimeInterval(-3600))]))
        let store = try makeMemoryStore(&containers)
        let watermark = clock.addingTimeInterval(-600)
        try store.setHelioFetchCursor(.autoStress, to: watermark, device: timeline)
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline, now: clock))
        XCTAssertFalse(store.helioStressBackfillDone(device: timeline), "it waits for a sync the strap owns")
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.autoStress], watermark)
    }

    func testTheBackfillFlagIsNotAFetchWatermark() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        try store.setHelioFetchCursor(.autoStress, to: clock.addingTimeInterval(-600), device: timeline)
        let moved = store.applyHelioStressBackfillIfNeeded(device: timeline, now: clock)
        XCTAssertEqual(moved, HelioFetchPlan.floorToMinute(clock.addingTimeInterval(-7 * 86_400)))
        XCTAssertEqual(Set(store.helioFetchCursors(device: timeline).keys), [.autoStress], "only the stress watermark")
        XCTAssertNil(store.applyHelioStressBackfillIfNeeded(device: timeline, now: clock.addingTimeInterval(3600)), "once")
        XCTAssertEqual(store.helioFetchCursors(device: timeline)[.autoStress], moved)
        // The ring's timeline never gets a flag or a watermark from this.
        XCTAssertFalse(store.helioStressBackfillDone(device: .ringConn))
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
    private let ownership = OwnershipOverride()
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-00000000D239")
    /// A past local day, so every row passes `ingest`'s real-clock guard.
    private let dayStart = Calendar.current.startOfDay(for: sNow.addingTimeInterval(-86_400))
    private func at(_ minutes: Double) -> Date { dayStart.addingTimeInterval(minutes * 60) }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func insert(_ store: LocalStore, _ kind: MetricKind, _ minutes: [Double], value: (Double) -> Double,
                        device: SyncDeviceID) throws {
        for m in minutes {
            store.context.insert(StoredSample(QuantitySample(kind: kind, start: at(m), value: value(m)), device: device))
        }
        try store.context.save()
    }

    /// The load check: a synthetic full strap day, 1440 per-minute heart rates and 288 stress values,
    /// read from the store and bucketed. The measured time is printed for the report.
    func testAFullStrapDayLoadsAndBucketsInTime() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeMemoryStore(&containers)
        try insert(store, .heartRate, (0..<1440).map(Double.init), value: { 60 + $0.truncatingRemainder(dividingBy: 37) },
                   device: strap)
        try insert(store, .stress, (0..<288).map { Double($0) * 5 }, value: { $0.truncatingRemainder(dividingBy: 100) },
                   device: strap)

        let clock = ContinuousClock()
        var timeline: DayTimeline?
        let elapsed = clock.measure { timeline = DayTimeline.load(store: store, day: dayStart) }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("DayTimeline load check: 1440 HR + 288 stress loaded and bucketed in \(String(format: "%.1f", ms)) ms")

        let hr = try XCTUnwrap(timeline?.day(.heartRate))
        XCTAssertEqual(hr.points.count, 1440)
        XCTAssertEqual(hr.series.map(\.family), [.zeppOS])
        XCTAssertEqual(hr.series.first?.bucketWidth, 300)
        XCTAssertEqual(hr.series.first?.buckets.count, 288)
        let stress = try XCTUnwrap(timeline?.day(.stress))
        XCTAssertEqual(stress.points.count, 288, "a stress of 0 is a reading, not a gap")
        XCTAssertEqual(stress.series.first?.buckets.count, 144)
        XCTAssertTrue(timeline?.showsStress == true)
        XCTAssertLessThan(ms, 2000)
    }

    func testASwitchMidDayGivesEachDeviceItsOwnTimeOnlyAndItsOwnAverage() throws {
        let switchAt = at(12 * 60)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makeMemoryStore(&containers)
        // The ring every 5 minutes ALL day (its readings after the switch are the other device's time),
        // the strap every minute all day (its readings before the switch likewise).
        try insert(store, .heartRate, (0..<288).map { Double($0) * 5 }, value: { _ in 60 }, device: .ringConn)
        try insert(store, .heartRate, (0..<1440).map(Double.init), value: { _ in 70 }, device: strap)

        let timeline = DayTimeline.load(store: store, day: dayStart)
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

    func testRingFingerAndStrapArmSkinTemperatureNeverShareALineOrAnAverage() throws {
        let switchAt = at(12 * 60)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makeMemoryStore(&containers)
        try store.recordDaytimeTemperature(35.0, at: at(9 * 60))
        try store.recordDaytimeTemperature(35.4, at: at(10 * 60))
        try store.recordDaytimeTemperature(36.9, at: at(13 * 60))   // the ring, in the strap's time: not drawn
        try insert(store, .temperature, [13 * 60, 14 * 60, 15 * 60], value: { 32 + ($0 - 780) / 120 }, device: strap)
        try insert(store, .temperature, [3 * 60], value: { _ in 34.0 }, device: .ringConn)   // the ring's night rows: never on this chart

        let temp = DayTimeline.load(store: store, day: dayStart).day(.skinTemp)
        XCTAssertEqual(temp.series.map(\.family), [.ringConn, .zeppOS])
        XCTAssertEqual(temp.series[0].points.map(\.value), [35.0, 35.4])
        XCTAssertEqual(temp.series[1].points.map(\.value), [32.0, 32.5, 33.0])
        XCTAssertEqual(temp.averages[.ringConn]!, 35.2, accuracy: 1e-9)
        XCTAssertEqual(temp.averages[.zeppOS]!, 32.5, accuracy: 1e-9)
    }

    func testARingOnlyInstallReadsExactlyTheRowsItReadBefore() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeMemoryStore(&containers)
        try insert(store, .heartRate, (0..<96).map { Double($0) * 15 }, value: { _ in 58 }, device: .ringConn)
        try insert(store, .heartRate, [600], value: { _ in 20 }, device: .ringConn)   // below the valid floor
        try store.recordDaytimeTemperature(35.1, at: at(600))
        try insert(store, .temperature, [180], value: { _ in 34.0 }, device: .ringConn)

        let timeline = DayTimeline.load(store: store, day: dayStart)
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
