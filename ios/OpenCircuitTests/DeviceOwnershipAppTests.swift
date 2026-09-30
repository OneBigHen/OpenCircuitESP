import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 28 (#215, review-224 S2/S3/N1/N2): which device owns which time, end to end through the
// store, the strap's sync and Health attribution. Every key, reading, id and time is synthetic (the
// same made-up strap fixtures as HelioSessionTests and the review-224 probes).

// MARK: - Shared test seams

extension DeviceOwnershipLog {
    /// A strap-only install: the strap's first entry owns all past time.
    static let strapOwnsAllTime = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast)])
}

/// Replaces `LocalStore.ownershipLog` for one test and puts the original back.
@MainActor
final class OwnershipOverride {
    private var saved: (@MainActor () -> DeviceOwnershipLog)?

    func install(_ log: DeviceOwnershipLog) {
        if saved == nil { saved = LocalStore.ownershipLog }
        LocalStore.ownershipLog = { log }
    }

    func restore() {
        if let saved { LocalStore.ownershipLog = saved }
        saved = nil
    }
}

// MARK: - Fixtures

private let oMidnight: TimeInterval = 1_789_862_400          // 2026-09-20T00:00:00Z
private let oNow = Date(timeIntervalSince1970: oMidnight + 12 * 3600)
private let oKeyHex = "00112233445566778899aabbccddeeff"
private func at(_ hoursFromMidnight: Double) -> Date { Date(timeIntervalSince1970: oMidnight + hoursFromMidnight * 3600) }

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// One night 23:00 → 07:00 UTC: light / deep / REM / light (480 min asleep).
private func sessionRecord() -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(oMidnight)), at: 0x000)
    put(le32(UInt32(oMidnight)), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(1380), at: 0x00A)
    put(le16(1860), at: 0x00C)
    r[0x016] = 81
    let stages: [(UInt16, UInt16, UInt8)] = [(1380, 1500, 0x04), (1500, 1560, 0x05), (1560, 1620, 0x08), (1620, 1860, 0x04)]
    r[0x054] = UInt8(stages.count)
    for (i, s) in stages.enumerated() { put(le16(s.0) + le16(s.1) + [s.2], at: 0x056 + 5 * i) }
    return r
}

/// 60 worn minutes from 23:00 UTC: 5 steps, HR 55 each.
private func activityData() -> [UInt8] { (0..<60).flatMap { _ in [0x01, 0x08, 5, 55, 0, 0, 0, 0] as [UInt8] } }
private func temperatureData() -> [UInt8] {
    (0..<60).flatMap { _ in [0xff, 0x7f] + le16(3350) + [0x5a, 0x5a, 0x5a, 0x5a] }
}

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func makeStrap() -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(oKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
    device.services = services
    device.deviceInfoReply = deviceInfoReply
    device.dataPacketLength = 200
    device.fetchData = [
        .activity: (stamp(oMidnight - 3600), activityData()),
        .sleepSession: (stamp(oMidnight), sessionRecord()),
        .temperature: (stamp(oMidnight - 3600), temperatureData()),
    ]
    return device
}

@MainActor
private final class OwnershipTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    /// U1: the strap never answers a keep-ack (`03 09`): the write is recorded but never reaches it.
    var swallowKeepAcks = false
    private(set) var writes: [ZeppWrite] = []
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }
    func has(_ c: ZeppCharacteristic) -> Bool { available.contains(c) }
    func canNotify(_ c: ZeppCharacteristic) -> Bool {
        has(c) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(c)
    }
    func write(_ write: ZeppWrite) {
        writes.append(write)
        if swallowKeepAcks, write.characteristic == .activityControl, write.bytes == [0x03, 0x09] { return }
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
private final class OwnershipKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(oKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class DeviceOwnershipAppTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = oNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D028"
    private let ringID = "5B1E4C2A-0000-4000-8000-00000000A028"
    private let suite = "test.DeviceOwnershipAppTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private func connect(_ device: FakeZeppDevice, store: LocalStore?, autoSync: Bool = true,
                         configure: (OwnershipTransport) -> Void = { _ in }) -> (HelioSession, OwnershipTransport) {
        let transport = OwnershipTransport(device: device)
        configure(transport)
        let keys = OwnershipKeys()
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: store.map { HelioStoreSink(store: $0) }, findState: HelioFindState(),
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: autoSync)
        transport.session = session
        session.start()
        transport.drain()
        return (session, transport)
    }

    private var strapTimeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    private func ringNight(from start: Date, to end: Date) -> [SleepSegment] {
        [SleepSegment(start: start, end: end, stage: .asleepCore)]
    }

    private func saveRingNight(_ store: LocalStore, from start: Date, to end: Date) throws -> SleepPersistOutcome {
        let segments = ringNight(from: start, to: end)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        return try store.saveSleepSummary(SleepStaging.summary(segments),
                                          night: SleepNightKey.night(inBedStart: start, inBedEnd: end),
                                          inBedStart: start, inBedEnd: end, sleepOnset: start, sleepWake: end,
                                          extras: extras)
    }

    /// A ring catch-up: one HR reading every 10 minutes over `[from, to)`.
    private func ringHeartRate(from: Date, to: Date) -> [QuantitySample] {
        stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 600).map {
            let t = Date(timeIntervalSince1970: $0)
            return QuantitySample(kind: .heartRate, start: t, end: t, value: 60)
        }
    }

    private func ringIdentity() -> WearableIdentity {
        WearableIdentity(id: ringID, kind: .ringConn(model: .gen2), name: "RingConn Gen2",
                         hardwareVersion: "00010001", firmwareVersion: "FR02.018")
    }

    // MARK: The log is recorded by the device choice

    func testASwitchIsRecordedOnlyWhenTheChoiceChanges() throws {
        let store = ActiveDeviceChoiceStore(defaults: defaults, ownership: DeviceOwnershipStore(defaults: defaults),
                                            neverHadRing: { false })
        store.set(.ringConn, now: at(1))
        XCTAssertTrue(DeviceOwnershipStore.persisted(defaults).isEmpty, "choosing the ring again records nothing")
        store.set(.helioStrap, now: at(2))
        store.set(.helioStrap, now: at(3))
        store.set(.ringConn, now: at(4))
        XCTAssertEqual(DeviceOwnershipStore.persisted(defaults).entries,
                       [.init(family: .zeppOS, since: at(2)), .init(family: .ringConn, since: at(4))])
        store.set(.helioStrap, now: at(3.5))
        XCTAssertEqual(DeviceOwnershipStore.persisted(defaults).entries.last, .init(family: .zeppOS, since: at(4)),
                       "a clock that moved back is clamped: the log stays monotonic")
    }

    func testTheFirstStrapEntryOnAnInstallThatNeverHadARingOwnsAllPastTime() throws {
        let store = ActiveDeviceChoiceStore(defaults: defaults, ownership: DeviceOwnershipStore(defaults: defaults),
                                            neverHadRing: { true })
        store.set(.helioStrap, now: at(2))
        store.set(.ringConn, now: at(4))
        store.set(.helioStrap, now: at(6))
        XCTAssertEqual(DeviceOwnershipStore.persisted(defaults).entries,
                       [.init(family: .zeppOS, since: .distantPast), .init(family: .ringConn, since: at(4)),
                        .init(family: .zeppOS, since: at(6))],
                       "only the very first entry backfills; every later switch owns time from the switch")
    }

    func testAnInstallThatHadARingGivesTheStrapTimeOnlyFromTheSwitch() throws {
        let store = ActiveDeviceChoiceStore(defaults: defaults, ownership: DeviceOwnershipStore(defaults: defaults),
                                            neverHadRing: { false })
        store.set(.helioStrap, now: at(2))
        XCTAssertEqual(DeviceOwnershipStore.persisted(defaults).entries, [.init(family: .zeppOS, since: at(2))])
    }

    // MARK: A ring-only install is unchanged (empty log)

    func testARingOnlyInstallIsUnchanged() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let hr = ringHeartRate(from: at(-2), to: at(9))
        _ = try store.ingest(hr, device: .ringConn)

        // Pending sets: every stored ring reading, exactly the unfiltered query.
        let everything = try store.samples(kind: .heartRate, from: .distantPast, to: .distantFuture)
        XCTAssertEqual(try store.pendingHealthSamples(device: .ringConn, kinds: [.heartRate]), everything)
        XCTAssertEqual(everything.count, hr.count)
        XCTAssertEqual(try store.ownedSamples(kind: .heartRate, from: .distantPast, to: .distantFuture), everything)

        // Sleep save outcome.
        XCTAssertEqual(try saveRingNight(store, from: at(-1), to: at(7)), .inserted)
        XCTAssertTrue(HealthKitWriter.ringOwnsNight(ringNight(from: at(-1), to: at(7))))

        // Step totals.
        try store.addDailySteps(120, day: at(9), windowStart: at(8.75))
        try store.addDailySteps(80, day: at(9.25), windowStart: at(9))
        XCTAssertEqual(try store.todaySteps(day: at(9)), 200)
        XCTAssertEqual(try store.pendingStepSamples().map(\.delta), [120, 80])

        // Attribution fields: every per-row resolution is exactly the pre-decision answer.
        let identities = WearableIdentityStore(defaults)
        let live = WearableSeamTests.FakeWearable(identity: ringIdentity())
        let connected = ActiveWearable(session: { live }, fallbackDeviceID: { nil }, identityStore: identities,
                                       ringFallbackID: { nil }, strapFallbackID: { nil }, ownership: { DeviceOwnershipLog() })
        let before = HealthDeviceAttribution.fields(for: connected.identityForHealthWrite(), origin: .device)
        XCTAssertNotNil(before)
        XCTAssertEqual(HealthDeviceAttribution.fields(for: connected.identityForHealthWrite(timeline: .ringConn), origin: .device), before)
        XCTAssertEqual(HealthDeviceAttribution.fields(for: connected.identityForHealthWrite(at: at(3)), origin: .device), before)
        XCTAssertEqual(HealthDeviceAttribution.fields(for: connected.identityForHealthWrite(at: .distantPast), origin: .device), before)

        let disconnected = ActiveWearable(session: { nil }, fallbackDeviceID: { self.ringID }, identityStore: identities,
                                          ringFallbackID: { self.ringID }, strapFallbackID: { nil },
                                          ownership: { DeviceOwnershipLog() })
        let offline = HealthDeviceAttribution.fields(for: disconnected.identityForHealthWrite(), origin: .device)
        XCTAssertEqual(offline, before)
        XCTAssertEqual(HealthDeviceAttribution.fields(for: disconnected.identityForHealthWrite(timeline: .ringConn), origin: .device), offline)
        XCTAssertEqual(HealthDeviceAttribution.fields(for: disconnected.identityForHealthWrite(at: at(3)), origin: .device), offline)
    }

    // MARK: The review-224 probes, now asserting the fixed behaviour

    /// Focus 8 / S2: the ring owned the night; the wearer switched to the strap after waking. The
    /// strap's sync (which re-delivers that night) leaves the ring's night, and its Health mirror, alone.
    func testAStrapSyncAfterARingOwnedNightLeavesTheRingNightAndItsHealthMirrorUntouched() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(8))]))
        let store = try makeStore()
        XCTAssertEqual(try saveRingNight(store, from: at(-0.5), to: at(6.5)), .inserted)   // 420 min
        let before = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            .map { "\($0.asleepMin) \($0.inBedStart) \($0.inBedEnd) \($0.updatedAt)" }

        let (session, _) = connect(makeStrap(), store: store)
        XCTAssertEqual(session.lastSyncResult?.interrupted, false)
        let after = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            .map { "\($0.asleepMin) \($0.inBedStart) \($0.inBedEnd) \($0.updatedAt)" }
        XCTAssertEqual(after, before, "the ring's stored night is untouched")
        XCTAssertEqual(session.lastSyncResult?.nights.count, 0, "no strap night is handed to the Health flush")
        XCTAssertTrue(HealthKitWriter.ringOwnsNight(ringNight(from: at(-0.5), to: at(6.5))),
                      "the ring's own mirror of its night still runs")
        XCTAssertEqual(try store.pendingHealthSamples(device: strapTimeline, kinds: HelioHealthPolicy.healthMirroredKinds()), [],
                       "nothing the strap recorded before the switch is pending for Health")
        XCTAssertEqual(try store.pendingStepSamples().count, 0)
    }

    /// Focus 8 / S2: the ring counted 300 steps in an hour it owned; the strap's 300 for the same
    /// hour don't add to them.
    func testRingAndStrapStepsForARingOwnedHourCountOnce() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(0))]))
        let store = try makeStore()
        try store.addDailySteps(300, day: at(-0.1), windowStart: at(-1))
        let day = Calendar.current.startOfDay(for: at(-1))
        _ = connect(makeStrap(), store: store)
        let daily = try store.context.fetch(FetchDescriptor<StoredDaily>()).first { $0.day == day }
        XCTAssertEqual(daily?.steps, 300, "ring 300 + strap 300 for the same ring-owned hour is 300")
        XCTAssertEqual(try store.pendingStepSamples().map(\.delta), [300])
    }

    /// And the other way round: in an hour the strap owned, the ring's steps are refused and the
    /// strap's count.
    func testInAStrapOwnedHourOnlyTheStrapsStepsCount() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2))]))
        let store = try makeStore()
        try store.addDailySteps(300, day: at(-0.1), windowStart: at(-1))
        XCTAssertEqual(try store.pendingStepSamples().count, 0)
        _ = connect(makeStrap(), store: store)
        let day = Calendar.current.startOfDay(for: at(-1))
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredDaily>()).first { $0.day == day }?.steps, 300)
        XCTAssertEqual(try store.pendingStepSamples().count, 60, "the strap's minutes, one row each")
    }

    /// S2: after a switch back, the ring's catch-up of the strap's window is stored but nothing of
    /// it is pending for Health, feeds a derived value, or becomes a night.
    func testARingCatchUpForAStrapOwnedWindowIsStoredButNeverReachesHealth() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)),
                                                       .init(family: .ringConn, since: at(8))]))
        let store = try makeStore()
        _ = try store.ingest(ringHeartRate(from: at(-3), to: at(9)), device: .ringConn)
        let stored = try store.samples(kind: .heartRate, from: .distantPast, to: .distantFuture)
        XCTAssertEqual(stored.count, 72, "the catch-up is kept in the app")

        let pending = try store.pendingHealthSamples(device: .ringConn, kinds: [.heartRate])
        XCTAssertEqual(pending.count, 12, "only the hour before the switch to the strap and the hour after the switch back")
        XCTAssertTrue(pending.allSatisfy { $0.start < at(-2) || $0.start >= at(8) })
        XCTAssertEqual(try store.ownedSamples(kind: .heartRate, from: .distantPast, to: .distantFuture), pending)

        XCTAssertEqual(try saveRingNight(store, from: at(-1), to: at(7)), .ownedByOtherDevice)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).count, 0, "no night saved")
        XCTAssertFalse(HealthKitWriter.ringOwnsNight(ringNight(from: at(-1), to: at(7))), "and none mirrored")
    }

    /// S3: a strap sync whose flush runs after the wearer switched back to the ring names the STRAP,
    /// resolved from the row's timeline, not the current choice.
    func testAStrapFlushAfterASwitchBackToTheRingNamesTheStrap() throws {
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)), .init(family: .ringConn, since: at(10))])
        ownership.install(log)
        let store = try makeStore()
        let (session, _) = connect(makeStrap(), store: store)
        let result = try XCTUnwrap(session.lastSyncResult)
        let synced = try XCTUnwrap(result.identity, "the sync result carries the strap's identity")

        let identities = WearableIdentityStore(defaults)
        let ring = WearableSeamTests.FakeWearable(identity: ringIdentity())
        let active = ActiveWearable(session: { ring }, fallbackDeviceID: { self.ringID }, identityStore: identities,
                                    ringFallbackID: { self.ringID }, strapFallbackID: { self.strapID }, ownership: { log })
        active.recordIdentity(synced)                                      // what flushToHealth does first

        let strap = try XCTUnwrap(HealthDeviceAttribution.fields(for: active.identityForHealthWrite(timeline: session.timeline),
                                                                 origin: .device))
        XCTAssertEqual(strap.name, "Helio Strap")
        XCTAssertEqual(strap.manufacturer, "Amazfit")
        XCTAssertEqual(strap.firmwareVersion, "1.2.3.4")
        XCTAssertEqual(strap.localIdentifier, session.timeline.rawValue)
        XCTAssertTrue(HelioConnection.mayFlush(timeline: session.timeline, strapChosen: false, wearable: active))

        // Untagged rows (steps, the night) name the device that owned their time.
        XCTAssertEqual(HealthDeviceAttribution.fields(for: active.identityForHealthWrite(at: at(3)), origin: .device), strap)
        let ringFields = HealthDeviceAttribution.fields(for: active.identityForHealthWrite(at: at(11)), origin: .device)
        XCTAssertEqual(ringFields?.localIdentifier, SyncDeviceID.ringConn.rawValue)
        XCTAssertEqual(ringFields?.name, "RingConn Gen2")
    }

    /// S3, first-write guard: a strap that never had an identity writes nothing once it isn't chosen,
    /// rather than anonymous rows. While chosen, the guard's own rule stands (no device attached).
    func testAStrapWithoutAnIdentityWritesNothingOnceItIsNoLongerChosen() throws {
        let identities = WearableIdentityStore(defaults)
        let ring = WearableSeamTests.FakeWearable(identity: ringIdentity())
        let active = ActiveWearable(session: { ring }, fallbackDeviceID: { self.ringID }, identityStore: identities,
                                    ringFallbackID: { self.ringID }, strapFallbackID: { self.strapID },
                                    ownership: { DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)),
                                                                             .init(family: .ringConn, since: at(10))]) })
        XCTAssertNil(active.identityForHealthWrite(timeline: strapTimeline))
        XCTAssertFalse(HelioConnection.mayFlush(timeline: strapTimeline, strapChosen: false, wearable: active))
        XCTAssertTrue(HelioConnection.mayFlush(timeline: strapTimeline, strapChosen: true, wearable: active))
        XCTAssertNotEqual(HealthDeviceAttribution.fields(for: active.identityForHealthWrite(at: at(3)), origin: .device)?.localIdentifier,
                          SyncDeviceID.ringConn.rawValue, "strap-owned time never names the ring")
    }

    /// Decision 28 (b): the strap never fetches earlier than its current ownership start, except on a
    /// strap-only install, whose first sync is the normal backfill.
    func testTheStrapsFetchIsBoundedByItsOwnershipStart() throws {
        let store = try makeStore()
        let sink = HelioStoreSink(store: store)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(8))]))
        XCTAssertEqual(sink.notBefore(timeline: strapTimeline, now: oNow), at(8))
        ownership.install(.strapOwnsAllTime)
        XCTAssertEqual(sink.notBefore(timeline: strapTimeline, now: oNow), .distantPast)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)), .init(family: .ringConn, since: at(8))]))
        XCTAssertEqual(sink.notBefore(timeline: strapTimeline, now: oNow), oNow, "switched away: nothing older than now")
    }

    // MARK: Regression tests kept from the review-224 probes (U1, re-download)

    func testAStallInAwaitingAckReplyTripsTheWatchdogAndTheNextSyncWorks() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let device = makeStrap()
        // Over the 4 MiB cap: 524,289 activity records announced → failRound → 03 09 with no 02.
        let oversized = [UInt8](repeating: 0, count: (4 << 20) + 8)
        device.fetchData[.activity] = (stamp(oMidnight - 3600), oversized)
        let (session, transport) = connect(device, store: store, autoSync: false) { $0.swallowKeepAcks = true }
        session.syncHistory(manual: true)
        transport.drain()
        XCTAssertEqual(session.phase, .syncing, "waiting in .awaitingAckReply for a 10 03 that never comes")
        XCTAssertEqual(session.fetchAcksSent, [0x09], "the over-cap round was acked keep, never 03 01")
        XCTAssertEqual(device.fetchAcks, [], "the strap never saw it (U1)")

        clock = clock.addingTimeInterval(HelioSession.syncStallTimeout - 1)
        session.tick(now: clock)
        XCTAssertEqual(session.phase, .syncing)
        clock = clock.addingTimeInterval(2)
        session.tick(now: clock)
        transport.drain()
        XCTAssertEqual(session.phase, .ready, "the watchdog ends the sync")
        XCTAssertEqual(session.lastSyncResult?.interrupted, true)
        XCTAssertNil(session.lastSyncAt, "an interrupted sync is not reported as a sync")

        // The strap answers again and the oversized round is gone: the next sync completes.
        transport.swallowKeepAcks = false
        device.fetchData[.activity] = (stamp(oMidnight - 3600), activityData())
        clock = clock.addingTimeInterval(60)
        session.syncHistory(manual: true)
        transport.drain()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.lastSyncResult?.interrupted, false)
        XCTAssertEqual(session.lastSyncResult?.roundsFailed, 0)
        XCTAssertNotNil(session.lastSyncAt)
        XCTAssertEqual(Set(session.fetchAcksSent), [0x09])
        let hr = try store.context.fetch(FetchDescriptor<StoredSample>()).filter { $0.kindRaw == "heartRate" }
        XCTAssertEqual(hr.count, 60)
    }

    func testARedownloadAfterAHealthFlushWritesNothingTwice() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let device = makeStrap()
        let (first, _) = connect(device, store: store)
        let timeline = first.timeline
        let kinds = HelioHealthPolicy.healthMirroredKinds()
        let pending = try store.pendingHealthSamples(device: timeline, kinds: kinds)
        let steps = try store.pendingStepSamples()
        XCTAssertFalse(pending.isEmpty)
        XCTAssertEqual(steps.count, 60)
        // What a successful flush does (HealthKitWriter.flushToHealth: mark after save).
        try store.markHealthWritten(pending, device: timeline)
        try store.markStepSamplesWritten(steps)

        clock = clock.addingTimeInterval(600)
        _ = connect(device, store: store)          // the strap re-delivers the same history
        XCTAssertEqual(try store.pendingHealthSamples(device: timeline, kinds: kinds).count, 0)
        XCTAssertEqual(try store.pendingStepSamples().count, 0)
    }

    // MARK: Review-224b S-A: a strap chosen before the log existed

    /// From the review's probe: `device.activeChoice.v1 = helioStrap` with no log (a choice persisted
    /// before `1f3164b`). Building the choice store reconciles the two, so the chosen strap owns time
    /// from then and stores what it measures.
    func testAStrapChosenBeforeTheLogExistedOwnsTimeFromTheNextLaunch() throws {
        defaults.set(ActiveDeviceChoice.helioStrap.rawValue, forKey: ActiveDeviceChoiceStore.key)
        let log = DeviceOwnershipStore(defaults: defaults)
        let choice = ActiveDeviceChoiceStore(defaults: defaults, ownership: log, neverHadRing: { false }, now: at(-2))
        XCTAssertTrue(choice.isHelio)
        XCTAssertEqual(log.log.entries, [.init(family: .zeppOS, since: at(-2))])
        XCTAssertEqual(DeviceOwnershipStore.persisted(defaults), log.log, "persisted, not only in memory")
        XCTAssertEqual(choice.ownershipLog, log.log)

        ownership.install(log.log)
        let store = try makeStore()
        let (session, _) = connect(makeStrap(), store: store)
        XCTAssertEqual(session.lastSyncResult?.interrupted, false)
        let strapRows = try store.context.fetch(FetchDescriptor<StoredSample>()).filter { $0.deviceID == strapTimeline.rawValue }
        XCTAssertFalse(strapRows.isEmpty, "the chosen strap stores what it measured while chosen")

        // Reconciled once: the next launch appends nothing.
        _ = ActiveDeviceChoiceStore(defaults: defaults, ownership: DeviceOwnershipStore(defaults: defaults),
                                    neverHadRing: { false }, now: at(5))
        XCTAssertEqual(DeviceOwnershipStore.persisted(defaults).entries, [.init(family: .zeppOS, since: at(-2))])
    }

    func testTheReconciliationUsesTheFirstEntryRule() throws {
        defaults.set(ActiveDeviceChoice.helioStrap.rawValue, forKey: ActiveDeviceChoiceStore.key)
        _ = ActiveDeviceChoiceStore(defaults: defaults, ownership: DeviceOwnershipStore(defaults: defaults),
                                    neverHadRing: { true }, now: at(-2))
        XCTAssertEqual(DeviceOwnershipStore.persisted(defaults).entries, [.init(family: .zeppOS, since: .distantPast)],
                       "an install that never had a ring backfills as a strap-only user")
    }

    func testTheRingChosenReconcilesNothing() throws {
        var neverHadRingAsked = false
        _ = ActiveDeviceChoiceStore(defaults: defaults, ownership: DeviceOwnershipStore(defaults: defaults),
                                    neverHadRing: { neverHadRingAsked = true; return true }, now: at(-2))
        defaults.set(ActiveDeviceChoice.ringConn.rawValue, forKey: ActiveDeviceChoiceStore.key)
        _ = ActiveDeviceChoiceStore(defaults: defaults, ownership: DeviceOwnershipStore(defaults: defaults),
                                    neverHadRing: { neverHadRingAsked = true; return true }, now: at(-2))
        XCTAssertTrue(DeviceOwnershipStore.persisted(defaults).isEmpty, "a ring-only install records nothing")
        XCTAssertFalse(neverHadRingAsked, "and doesn't even look at the store")
    }

    // MARK: Review-224b B-1 / decision 28b: step rows lie wholly in their device's time

    /// From the review's probe: back to the ring at 08:05. The ring's first reading at 08:07 credits
    /// its 08:00 bucket (120 steps). The row is clamped to 08:05, delta kept: wholly ring time, named
    /// the ring, given distance, and clear of the strap's 08:00–08:04 minutes.
    func testARingBucketSpanningASwitchBackIsStoredWhollyInRingTime() throws {
        let switchBack = at(8 + 5.0 / 60)
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)), .init(family: .ringConn, since: switchBack)])
        ownership.install(log)
        let store = try makeStore()
        let strapMinutes = (0..<5).map { m -> QuantitySample in
            let t = at(8 + Double(m) / 60)
            return QuantitySample(kind: .steps, start: t, end: t.addingTimeInterval(60), value: 10)
        }
        XCTAssertEqual(try store.ingestHelioStepMinutes(strapMinutes, device: strapTimeline, now: oNow), 5)
        try store.addDailySteps(120, day: at(8 + 7.0 / 60), windowStart: at(8))

        let rows = try store.pendingStepSamples()
        let ringRow = try XCTUnwrap(rows.first { $0.delta == 120 })
        let strapRows = rows.filter { $0.delta == 10 }
        XCTAssertEqual(ringRow.start, switchBack, "clamped to the ring's ownership start")
        XCTAssertEqual(ringRow.end, at(8 + 7.0 / 60))
        XCTAssertEqual(strapRows.count, 5)
        XCTAssertTrue(strapRows.allSatisfy { $0.end <= ringRow.start }, "no overlap with the strap's minutes")
        XCTAssertEqual(try store.todaySteps(day: at(8)), 170, "the delta is kept")

        // Named the ring (untagged rows name the owner at their start) and given distance.
        XCTAssertEqual(log.owner(at: ringRow.start), .ringConn)
        let active = ActiveWearable(session: { nil }, fallbackDeviceID: { nil }, identityStore: WearableIdentityStore(defaults),
                                    ringFallbackID: { self.ringID }, strapFallbackID: { self.strapID }, ownership: { log })
        active.recordIdentity(ringIdentity())
        XCTAssertEqual(HealthDeviceAttribution.fields(for: active.identityForHealthWrite(at: ringRow.start), origin: .device)?.localIdentifier,
                       SyncDeviceID.ringConn.rawValue)
        XCTAssertEqual(HealthKitWriter.distanceRows(rows, ownership: log).map(\.delta), [120],
                       "distance from the ring's row only")
    }

    /// The mirror (28b for the strap): the minute a ring→strap switch lands in counts for the strap,
    /// clamped to the switch; a minute that ends after a switch away is the ring's, not the strap's.
    func testAStrapMinuteSpanningASwitchIsClampedToTheStrapsTime() throws {
        let toStrap = at(-2 + 30.0 / 3600), backToRing = at(-1 + 30.0 / 3600)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: toStrap), .init(family: .ringConn, since: backToRing)]))
        let store = try makeStore()
        let minutes = [at(-2), at(-2 + 1.0 / 60), at(-1)].map {
            QuantitySample(kind: .steps, start: $0, end: $0.addingTimeInterval(60), value: 10)
        }
        XCTAssertEqual(try store.ingestHelioStepMinutes(minutes, device: strapTimeline, now: oNow), 2)
        let rows = try store.pendingStepSamples().sorted { $0.start < $1.start }
        XCTAssertEqual(rows.map(\.start), [toStrap, at(-2 + 1.0 / 60)], "the spanning minute starts at the switch")
        XCTAssertEqual(rows.map(\.delta), [10, 10])
    }
}
