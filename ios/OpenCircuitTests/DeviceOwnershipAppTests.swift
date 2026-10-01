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
        XCTAssertTrue(HealthKitWriter.ringOwnsNight(ringNight(from: at(-1), to: at(7)), store: store))

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
        XCTAssertTrue(HealthKitWriter.ringOwnsNight(ringNight(from: at(-0.5), to: at(6.5)), store: store),
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

        XCTAssertEqual(try saveRingNight(store, from: at(-1), to: at(7)), .ownedByOtherDeviceNoRow,
                       "the strap owns it and stored none (review-224b N-3)")
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).count, 0, "no night saved")
        XCTAssertFalse(HealthKitWriter.ringOwnsNight(ringNight(from: at(-1), to: at(7)), store: store), "and none mirrored")
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
        // The day's distance sample starts at midnight, which the strap owned: it still names the ring.
        XCTAssertEqual(log.owner(at: Calendar.current.startOfDay(for: ringRow.end)), .zeppOS)
        XCTAssertEqual(HealthKitWriter.wearableDevice(forTimeline: HealthKitWriter.distanceTimeline, wearable: active)?.localIdentifier,
                       SyncDeviceID.ringConn.rawValue)
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

    // MARK: Review-224b S-C / decision 28a: the device you went to bed with keeps the night

    private func saveNight(_ store: LocalStore, _ device: SyncDeviceID, _ from: Double, _ to: Double) throws -> SleepPersistOutcome {
        let segments = ringNight(from: at(from), to: at(to))
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        return try store.saveSleepSummary(SleepStaging.summary(segments),
                                          night: SleepNightKey.night(inBedStart: at(from), inBedEnd: at(to)),
                                          inBedStart: at(from), inBedEnd: at(to), sleepOnset: at(from), sleepWake: at(to),
                                          extras: extras, device: device)
    }

    /// Saves `ring` and `strap` nights in both orders under `log`; each order must end with exactly one
    /// stored night, the expected one, and the device that lost must not be allowed to mirror.
    private func assertOneKeptNight(_ log: DeviceOwnershipLog, ring: (Double, Double), strap: (Double, Double),
                                    ringFirst keptRingFirst: SyncDeviceID, strapFirst keptStrapFirst: SyncDeviceID,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        ownership.install(log)
        for ringFirst in [true, false] {
            let store = try makeStore()
            let order: [(SyncDeviceID, (Double, Double))] = ringFirst
                ? [(.ringConn, ring), (strapTimeline, strap)] : [(strapTimeline, strap), (.ringConn, ring)]
            let outcomes = try order.map { try saveNight(store, $0.0, $0.1.0, $0.1.1) }
            let expected = ringFirst ? keptRingFirst : keptStrapFirst
            let window = expected == .ringConn ? ring : strap
            let rows = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            let label = ringFirst ? "ring first" : "strap first"
            XCTAssertEqual(rows.count, 1, "\(label): exactly one kept night", file: file, line: line)
            XCTAssertEqual(rows.first?.inBedStart, at(window.0), "\(label): the kept night is the \(expected.rawValue)'s", file: file, line: line)
            XCTAssertEqual(rows.first?.inBedEnd, at(window.1), "\(label): never merged", file: file, line: line)
            XCTAssertEqual(outcomes.filter(\.wroteRow).count, 1, "\(label): \(outcomes)", file: file, line: line)
            // Health: only the keeper may mirror, and the loser's mirror delete never reaches the kept night.
            let ringKeeps = HealthKitWriter.ringOwnsNight(ringNight(from: at(ring.0), to: at(ring.1)), store: store)
            XCTAssertEqual(ringKeeps, expected == .ringConn, "\(label): ring mirror", file: file, line: line)
            let strapFamily: DeviceOwnershipLog.Family = .zeppOS
            let loser: DeviceOwnershipLog.Family = expected == .ringConn ? strapFamily : .ringConn
            XCTAssertFalse(store.nightKeeping(loser, inBedStart: at(expected == .ringConn ? strap.0 : ring.0),
                                              inBedEnd: at(expected == .ringConn ? strap.1 : ring.1)).keep,
                           "\(label): the other device's night may not be mirrored", file: file, line: line)
            XCTAssertEqual(store.otherDevicesNightWindows(loser, overlapping: at(-6), to: at(12)),
                           [DateInterval(start: at(window.0), end: at(window.1))],
                           "\(label): excluded from the loser's union delete", file: file, line: line)
        }
    }

    func testSwitchedBeforeBedTheStrapKeepsTheNight() throws {
        try assertOneKeptNight(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2))]),
                               ring: (-1, 7), strap: (-0.5, 6.5), ringFirst: strapTimeline, strapFirst: strapTimeline)
    }

    /// The review's "neither" probe: switch at 03:00; each device's own midpoint pointed at the other.
    func testASwitchMidSleepLeavesTheNightWithTheDeviceYouWentToBedWith() throws {
        try assertOneKeptNight(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(3))]),
                               ring: (-1, 7.5), strap: (-0.5, 6), ringFirst: .ringConn, strapFirst: .ringConn)
    }

    /// The review's "both" probe: the strap's fuller night must never replace the ring's.
    func testAStrapNightNeverReplacesTheRingsNightAfterAMidSleepSwitch() throws {
        try assertOneKeptNight(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(3))]),
                               ring: (-0.5, 6), strap: (-1, 7.5), ringFirst: .ringConn, strapFirst: .ringConn)
    }

    /// A switch between the two devices' in-bed starts: each window says "mine", so the first stored
    /// wins and the other never replaces it.
    func testASwitchBetweenTheTwoBedtimesKeepsWhicheverSyncedFirst() throws {
        try assertOneKeptNight(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-0.75))]),
                               ring: (-1, 7), strap: (-0.5, 7), ringFirst: .ringConn, strapFirst: strapTimeline)
    }

    func testTwoSwitchesInOneNightStillKeepOneNight() throws {
        try assertOneKeptNight(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(1)),
                                                            .init(family: .ringConn, since: at(4))]),
                               ring: (-1, 7), strap: (1.2, 3.8), ringFirst: .ringConn, strapFirst: strapTimeline)
    }

    /// Ring-only: the verdict never refuses and never queries.
    func testNightKeepingIsANoOpWithAnEmptyLog() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        XCTAssertEqual(try saveNight(store, .ringConn, -1, 7), .inserted)
        XCTAssertTrue(store.nightKeeping(.ringConn, inBedStart: at(-1), inBedEnd: at(7)).keep)
        XCTAssertEqual(store.otherDevicesNightWindows(.ringConn, overlapping: at(-6), to: at(12)), [])
    }

    // MARK: Review-224b N-3: an owned night with no stored row is a gap, not a keep

    func testTheRingsStagingOfAStrapNightSaysWhetherTheStrapStoredOne() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)), .init(family: .ringConn, since: at(8))]))
        let store = try makeStore()
        let noRow = try saveNight(store, .ringConn, -1, 7)
        XCTAssertEqual(noRow, .ownedByOtherDeviceNoRow, "the strap stored no night: nothing backs this one")
        XCTAssertTrue(noRow.isSilentLoss, "so the Sleep card shows its unsaved-night notice")
        XCTAssertTrue(SleepCardView.unsavedNightCopy(noRow).contains("the strap’s night"))
        XCTAssertFalse(SleepCardView.unsavedNightCopy(noRow).contains("Sync again"), "no promise a retry can't keep")

        XCTAssertEqual(try saveNight(store, strapTimeline, -0.5, 6.5), .inserted)
        let kept = try saveNight(store, .ringConn, -1, 7)
        XCTAssertEqual(kept, .ownedByOtherDevice, "the strap's night is stored: a deliberate keep")
        XCTAssertFalse(kept.isSilentLoss)
    }

    // MARK: Review-224c S-1 / decision 28c: only an overnight strap sleep is a night

    /// Hours on the LOCAL day of `oNow`: the overnight gate judges local time, as it does the ring's.
    private func localHour(_ h: Double) -> Date { Calendar.current.startOfDay(for: oNow).addingTimeInterval(h * 3600) }

    /// A strap sleep session record between two local hours (minute fields count from the previous
    /// local midnight, `ZeppSleepSession.absolute`).
    private func localSession(_ from: Double, _ to: Double, stages: [(Double, Double, UInt8)]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
        func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
        func minute(_ h: Double) -> UInt16 { UInt16((h + 24) * 60) }
        let midnight = UInt32(localHour(0).timeIntervalSince1970)
        put(le32(midnight), at: 0x000)
        put(le32(midnight), at: 0x004)
        r[0x008] = 1
        r[0x009] = 1
        put(le16(minute(from)), at: 0x00A)
        put(le16(minute(to)), at: 0x00C)
        r[0x016] = 81
        r[0x054] = UInt8(stages.count)
        for (i, stage) in stages.enumerated() {
            put(le16(minute(stage.0)) + le16(minute(stage.1)) + [stage.2], at: 0x056 + 5 * i)
        }
        return r
    }

    /// From review-224c's probe, through the strap's real path: ring→strap at 05:00, mid-sleep (the
    /// ring went to bed with the night, 28a). The strap syncs a 13:00–14:00 daytime session on the
    /// same night key. Back to the ring at 18:00: the ring's 23:00–07:00 night is stored and mirrored.
    func testAStrapDaytimeSessionNeverTakesTheRingsNightKey() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: localHour(5))]))
        let store = try makeStore()
        let device = makeStrap()
        device.fetchData[.sleepSession] = (stamp(oMidnight), localSession(13, 14, stages: [(13, 14, 0x04)]))
        clock = localHour(16)
        let (session, _) = connect(device, store: store)
        XCTAssertEqual(session.lastSyncResult?.interrupted, false)
        XCTAssertEqual(session.lastSyncResult?.nights.count, 0, "a daytime session is not a night")
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).count, 0, "and takes no night key")

        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: localHour(5)),
                                                       .init(family: .ringConn, since: localHour(18))]))
        XCTAssertEqual(try saveRingNight(store, from: localHour(-1), to: localHour(7)), .inserted,
                       "the night the wearer went to bed with is stored")
        XCTAssertTrue(HealthKitWriter.ringOwnsNight(ringNight(from: localHour(-1), to: localHour(7)), store: store),
                      "and mirrored to Health")
    }

    /// The gate changes nothing for an overnight strap night: stored with the same window and minutes.
    func testAnOvernightStrapNightStillStoresExactlyAsBefore() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let device = makeStrap()
        device.fetchData[.sleepSession] = (stamp(oMidnight), localSession(-1, 7, stages: [(-1, 1, 0x04), (1, 2, 0x05), (2, 3, 0x08), (3, 7, 0x04)]))
        clock = localHour(12)
        let (session, _) = connect(device, store: store)
        XCTAssertEqual(session.lastSyncResult?.nights.map(\.window), [DateInterval(start: localHour(-1), end: localHour(7))])
        let rows = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(rows.map { "\($0.asleepMin) light \($0.lightMin) deep \($0.deepMin) rem \($0.remMin)" },
                       ["480 light 360 deep 60 rem 60"])
        XCTAssertEqual(rows.first?.inBedStart, localHour(-1))
        XCTAssertEqual(rows.first?.inBedEnd, localHour(7))
    }

    // MARK: Review-224c S-3: the Sleep card after a switch back

    /// The strap keeps the night (390 min); after the switch back the ring stages a fuller reading of
    /// it (540 min) and gets `.ownedByOtherDevice`. The card shows the strap's stored row, the one Edit
    /// targets, not the ring's reading.
    func testTheSleepCardShowsTheStrapsKeptNightNotTheRingsLargerStaging() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)), .init(family: .ringConn, since: at(8))]))
        let store = try makeStore()
        XCTAssertEqual(try saveNight(store, strapTimeline, -0.5, 6), .inserted)
        let ringStaging = ringNight(from: at(-1.5), to: at(7.5))
        let outcome = try saveNight(store, .ringConn, -1.5, 7.5)
        XCTAssertEqual(outcome, .ownedByOtherDevice)
        let row = try XCTUnwrap(store.context.fetch(FetchDescriptor<StoredSleepSummary>()).first)
        XCTAssertEqual(SleepCardView.selectNight(liveSegments: ringStaging, stored: row)?.stageSource, .live,
                       "unfiltered, the fuller ring staging would win the card")

        let shown = SleepCardView.selectNight(liveSegments: SleepCardView.liveSegments(ringStaging, outcome: outcome), stored: row)
        XCTAssertEqual(shown?.stageSource, .stored)
        XCTAssertEqual(shown?.summary.minutes.asleep, 390, "the strap's kept night")
        XCTAssertEqual(shown?.inBedStart, at(-0.5))
        XCTAssertEqual(shown?.nightKey, row.night, "the row Edit targets is the row on screen")
    }

    /// The strap owns the ring's latest night and stored none: no ring stages as the night, and the
    /// notice says why.
    func testANightTheStrapOwnsWithNoRowShowsTheNoticeNotTheRingsStages() {
        let staged = ringNight(from: at(-1), to: at(7))
        XCTAssertEqual(SleepCardView.liveSegments(staged, outcome: .ownedByOtherDeviceNoRow), [])
        XCTAssertNil(SleepCardView.selectNight(liveSegments: SleepCardView.liveSegments(staged, outcome: .ownedByOtherDeviceNoRow),
                                               stored: nil))
        let copy = SleepCardView.unsavedNightCopy(.ownedByOtherDeviceNoRow)
        XCTAssertTrue(copy.contains("the strap’s night") && copy.contains("no strap night is stored"))
    }

    /// Ring-only: no save ever returns an ownership outcome on an empty log, so the card's live
    /// staging passes through untouched for every outcome it can get.
    func testARingOnlyInstallNeverGetsAnOwnershipOutcomeAndTheCardIsUnchanged() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let shapes: [(Double, Double)] = [(-1, 7), (-1, 7), (-0.5, 6), (-1.5, 7.5), (23, 31), (13, 15), (46, 55)]
        let outcomes = try shapes.map { try saveNight(store, .ringConn, $0.0, $0.1) }
        XCTAssertFalse(outcomes.contains(.ownedByOtherDevice), "\(outcomes)")
        XCTAssertFalse(outcomes.contains(.ownedByOtherDeviceNoRow), "\(outcomes)")
        let staged = ringNight(from: at(-1), to: at(7))
        for outcome in [nil] + SleepPersistOutcome.allCases.map(Optional.some)
        where outcome != .ownedByOtherDevice && outcome != .ownedByOtherDeviceNoRow {
            XCTAssertEqual(SleepCardView.liveSegments(staged, outcome: outcome), staged, "\(String(describing: outcome))")
        }
    }

    // MARK: Review-224d S-1 / decision 28d: a strap sleep takes a night key only if it could be that night

    /// One strap sync of `spans` (local hours of `oNow`'s day, one session each) through the production
    /// path, under `log`. Returns the sync's night windows.
    @discardableResult
    private func strapSync(_ spans: [(Double, Double)], now: Date, log: DeviceOwnershipLog,
                           store: LocalStore) throws -> [DateInterval] {
        ownership.install(log)
        let device = makeStrap()
        device.fetchData[.sleepSession] = (stamp(localHour(0).timeIntervalSince1970 - 86_400),
                                           spans.flatMap { localSession($0.0, $0.1, stages: [($0.0, $0.1, 0x04)]) })
        clock = now
        let (session, _) = connect(device, store: store)
        XCTAssertEqual(session.lastSyncResult?.interrupted, false)
        return session.lastSyncResult?.nights.map(\.window) ?? []
    }

    private func nightRows(_ store: LocalStore) throws -> [String] {
        try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.inBedStart)])).map {
            "\(($0.inBedStart.timeIntervalSince(localHour(0))) / 3600)…\(($0.inBedEnd.timeIntervalSince(localHour(0))) / 3600) asleep=\($0.asleepMin)"
        }
    }

    /// From review-224d's probe: ring→strap at 05:00, mid-sleep (the ring went to bed with the night);
    /// the strap syncs a 20:00–22:30 evening doze the overnight gate accepts (midpoint 21:15). Back to the
    /// ring at 23:15: the ring's 23:00–07:00 night is stored and mirrored, and the doze took no key.
    func testAnEveningStrapDozeNeverTakesTheRingsNightKey() throws {
        let store = try makeStore()
        let nights = try strapSync([(20, 22.5)], now: localHour(23),
                                   log: DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: localHour(5))]), store: store)
        XCTAssertEqual(nights, [], "an evening doze is never a night")
        XCTAssertEqual(try nightRows(store), [])
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: localHour(5)),
                                                       .init(family: .ringConn, since: localHour(23.25))]))
        XCTAssertEqual(try saveRingNight(store, from: localHour(-1), to: localHour(7)), .inserted)
        XCTAssertTrue(HealthKitWriter.ringOwnsNight(ringNight(from: localHour(-1), to: localHour(7)), store: store))
    }

    /// The morning variant: a switch at 07:15 after the ring's night, then the strap's 07:30–10:00
    /// back-to-sleep (a legal night by 28c and 28d, and on the same key). The two don't overlap, so the
    /// longer one that ends in the wake window, the ring's 23:00–07:00, is the night, in either order.
    func testAMorningStrapSleepNeverMakesTheRingsLongerNightUnkeepable() throws {
        let strapTime = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: localHour(7.25))])
        let backToRing = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: localHour(7.25)),
                                                      .init(family: .ringConn, since: localHour(12))])
        // Strap first (the review's order): its sleep is stored, then the ring's night replaces it.
        let store = try makeStore()
        XCTAssertEqual(try strapSync([(7.5, 10)], now: localHour(11), log: strapTime, store: store).count, 1)
        ownership.install(backToRing)
        XCTAssertTrue(try saveRingNight(store, from: localHour(-1), to: localHour(7)).wroteRow)
        XCTAssertEqual(try nightRows(store), ["-1.0…7.0 asleep=480"], "one row, the ring's night")
        XCTAssertTrue(HealthKitWriter.ringOwnsNight(ringNight(from: localHour(-1), to: localHour(7)), store: store))
        XCTAssertEqual(store.nightKeeping(.zeppOS, inBedStart: localHour(7.5), inBedEnd: localHour(10)).keep, false,
                       "and the strap's re-sync of its shorter sleep never takes the key back")

        // Ring first: the strap's shorter sleep on the same key is skipped.
        let other = try makeStore()
        ownership.install(strapTime)
        XCTAssertEqual(try saveRingNight(other, from: localHour(-1), to: localHour(7)), .inserted)
        XCTAssertEqual(try strapSync([(7.5, 10)], now: localHour(11), log: strapTime, store: other), [])
        XCTAssertEqual(try nightRows(other), ["-1.0…7.0 asleep=480"])
    }

    /// From review-224d's `evening-then-night` probe, strap only: an evening doze and the night in one
    /// sync, more than 60 min apart. The doze doesn't end in a wake window, so only the night is stored.
    /// (The probe's exact shape, a 60-minute gap, is one night under 28f; see the stitching test.)
    func testAnEveningDozeBeforeTheNightIsNotStoredAsItsOwnNight() throws {
        let store = try makeStore()
        let nights = try strapSync([(-4, -2), (-0.5, 7)], now: localHour(9), log: .strapOwnsAllTime, store: store)
        XCTAssertEqual(nights, [DateInterval(start: localHour(-0.5), end: localHour(7))])
        XCTAssertEqual(try nightRows(store), ["-0.5…7.0 asleep=450"])
    }

    /// Decision 28d is only reached with a non-empty log: on an empty log the keyed-row rule never runs.
    func testTheKeyedRowRuleIsANoOpWithAnEmptyLog() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let outcomes = try [(7.5, 10.0), (-1.0, 7.0), (20.0, 22.5)].map { try saveNight(store, .ringConn, $0.0, $0.1) }
        XCTAssertFalse(outcomes.contains(.ownedByOtherDevice) || outcomes.contains(.ownedByOtherDeviceNoRow))
        XCTAssertTrue(store.nightKeeping(.ringConn, inBedStart: at(-1), inBedEnd: at(7)).keep)
    }

    // MARK: Review-224d U-1: Edit only on a night the ring owns

    func testEditIsOfferedOnlyOnANightTheRingOwns() throws {
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-2)), .init(family: .ringConn, since: at(8))])
        ownership.install(log)
        let store = try makeStore()
        XCTAssertEqual(try saveNight(store, strapTimeline, -0.5, 6.5), .inserted)
        XCTAssertEqual(try saveNight(store, .ringConn, 22, 31), .inserted)   // the next night, the ring's
        let rows = try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.inBedStart)]))
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(SleepCardView.ringMayEdit(rows[0], log: log), "the strap's kept night: no ring Edit over it")
        XCTAssertTrue(SleepCardView.ringMayEdit(rows[1], log: log), "the ring's own night stays editable")
        XCTAssertTrue(SleepCardView.ringMayEdit(rows[0], log: DeviceOwnershipLog()), "ring-only: always editable, as before")
    }

    // MARK: Decision 30: the strap's live heart rate works like the ring's Measure

    func testTheStrapsMeasureStartsStopsRestartsAndStopsItselfAfterTheRingsBudget() throws {
        ownership.install(.strapOwnsAllTime)
        let (session, transport) = connect(makeStrap(), store: nil, autoSync: false)
        defer { withExtendedLifetime(transport) {} }   // the session holds its transport weakly
        let live = StrapLiveHeartRate(session: session)
        XCTAssertTrue(live.canMeasure, "authenticated, with the heart-rate endpoint: the control shows")
        XCTAssertFalse(live.measuring)
        XCTAssertFalse(live.disabled)

        session.received(.heartRateMeasurement, [0x00, 61])   // an earlier reading
        live.toggle()
        XCTAssertTrue(live.measuring)
        XCTAssertNil(live.liveHR, "a new measurement shows only its own readings")
        session.received(.heartRateMeasurement, [0x00, 72])
        XCTAssertEqual(live.liveHR, 72)

        live.toggle()
        XCTAssertFalse(live.measuring, "stop")
        XCTAssertNil(live.liveHR)
        live.toggle()
        XCTAssertTrue(live.measuring, "and restart")

        XCTAssertEqual(StrapLiveHeartRate.duration, 90, "the ring's heart-rate Measure budget")
        clock = clock.addingTimeInterval(StrapLiveHeartRate.duration - 1)
        session.tick(now: clock)
        XCTAssertTrue(live.measuring)
        clock = clock.addingTimeInterval(2)
        session.tick(now: clock)
        XCTAssertFalse(live.measuring, "stops by itself, as the live card says")
    }

    func testAKeylessStrapHasNoMeasureControl() throws {
        let transport = OwnershipTransport(device: makeStrap())
        let session = HelioSession(transport: transport, identityID: strapID, key: nil, keyStore: OwnershipKeys(),
                                   sink: nil, findState: HelioFindState(), clock: { oNow },
                                   autoTick: false, autoSyncOnConnect: false)
        transport.session = session
        session.start()
        transport.drain()
        XCTAssertEqual(session.phase, .keyless)
        XCTAssertFalse(StrapLiveHeartRate(session: session).canMeasure, "nothing to start without the key")
    }
}
