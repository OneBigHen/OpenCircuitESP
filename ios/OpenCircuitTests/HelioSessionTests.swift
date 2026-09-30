import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// `HelioSession` end to end against the simulated strap (`FakeZeppDevice`, shared with ZeppKitTests)
// and a real in-memory `LocalStore` (#215 phase 3). Every key, reading and time is synthetic.

// MARK: - Fixtures

/// 2026-09-20T00:00:00Z. Test clocks sit in the past so `ingest`'s "not in the future" guard, which
/// reads the real clock, always passes.
private let midnight: TimeInterval = 1_789_862_400
private let testNow = Date(timeIntervalSince1970: midnight + 12 * 3600)

private let keyHex = "00112233445566778899aabbccddeeff"
private let strapPrivateKey = Array(UInt8(0x81)...UInt8(0x98))
private let strapRandom = Array(UInt8(0xf0)...UInt8(0xff))

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// One night 23:00 → 07:00 (UTC), staged light / deep / REM / light.
private func sessionRecord() -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(midnight)), at: 0x000)
    put(le32(UInt32(midnight)), at: 0x004)
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

/// 60 activity minutes from 23:00: worn (kind 0x01, 5 steps, HR 55), except minutes 10–14 not
/// worn (0x73, no HR) and 20–24 charging (0x76, no HR).
private func activityData() -> [UInt8] {
    (0..<60).flatMap { i -> [UInt8] in
        switch i {
        case 10..<15: return [0x73, 0, 0, 0xff, 0, 0, 0, 0]
        case 20..<25: return [0x76, 0, 0, 0xff, 0, 0, 0, 0]
        default: return [0x01, 0x08, 5, 55, 0, 0, 0, 0]
        }
    }
}

/// 60 temperature minutes from 23:00 at 33.50 °C, except minute 30 at 29.00 °C (out of range).
private func temperatureData() -> [UInt8] {
    (0..<60).flatMap { i -> [UInt8] in
        let centi = UInt16(i == 30 ? 2900 : 3350)
        return [0xff, 0x7f] + le16(centi) + [0x5a, 0x5a, 0x5a, 0x5a]
    }
}

/// Two HRV readings during the night (made-up values).
private func hrvData() -> [UInt8] {
    le32(UInt32(midnight + 3600)) + [0x00, 41] + le32(UInt32(midnight + 7200)) + [0x00, 47]
}

/// One SpO₂ record (version 02, 65-byte record): automatic, 96 %.
private func spo2Data() -> [UInt8] {
    [0x02] + le32(UInt32(midnight + 1800)) + [0x80 | 96] + [UInt8](repeating: 0, count: 60)
}

/// The endpoints a Helio lists, with the controls (§3.5): find encrypted, alarms plaintext.
private let helioServices: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]

/// A device-info reply (§5.3): `02 01`, flags 0x0C (hardware + firmware, no bit-0 blob), then the two
/// NUL-terminated versions. Made-up versions; the hardware one matches the fake DIS read.
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func makeStrap(authKey: String = keyHex) -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(authKey)!, privateKey: strapPrivateKey, random: strapRandom,
                                writeLength: 244)
    device.services = helioServices
    device.deviceInfoReply = deviceInfoReply
    device.dataPacketLength = 200
    let night = midnight - 3600
    device.fetchData = [
        .activity: (stamp(night), activityData()),
        .sleepSession: (stamp(midnight), sessionRecord()),
        .temperature: (stamp(night), temperatureData()),
        .hrv: (stamp(midnight + 3600), hrvData()),
        .spo2: (stamp(midnight + 1800), spo2Data()),
    ]
    return device
}

/// `HelioTransport` over `FakeZeppDevice`. Deliveries are QUEUED and handed to the session by
/// `drain()`, as CoreBluetooth hands them over on a later run-loop turn, never inside a write.
@MainActor
private final class FakeStrapTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    /// When true, writes vanish (a strap that never answers).
    var silent = false
    private(set) var writes: [ZeppWrite] = []
    private(set) var notifyChanges: [(ZeppCharacteristic, Bool)] = []
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }

    func write(_ write: ZeppWrite) {
        writes.append(write)
        guard !silent else { return }
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }

    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) {
        notifyChanges.append((characteristic, enabled))
        inbox.append((characteristic, nil, enabled))
    }

    func read(_ characteristic: ZeppCharacteristic) {
        switch characteristic {
        case .hardwareRevision: inbox.append((characteristic, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((characteristic, [64], false))
        default: break
        }
    }

    /// A strap-originated message (e.g. find device `07`).
    func push(_ notifications: [FakeZeppDevice.Notification]) {
        for n in notifications { inbox.append((n.characteristic, n.bytes, false)) }
    }

    /// Deliver only the next `count` queued events.
    func drainSteps(_ count: Int) {
        for _ in 0..<count where !inbox.isEmpty {
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes {
                session?.received(characteristic, bytes)
            } else {
                session?.notificationStateChanged(characteristic, enabled: enabled, failed: false)
            }
        }
    }

    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 100_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes {
                session?.received(characteristic, bytes)
            } else {
                session?.notificationStateChanged(characteristic, enabled: enabled, failed: false)
            }
        }
    }
}

@MainActor
private final class MemoryKeyStore: HelioKeyStoring {
    var text: String?
    var isRejected = false
    init(_ text: String?) { self.text = text }
    func load() -> ZeppAuthKey? { text.flatMap(HelioKeyText.parse) }
    func save(pasted text: String) throws -> Bool {
        guard HelioKeyText.normalized(text) != nil else { return false }
        self.text = text
        isRejected = false
        return true
    }
    func forget() { text = nil; isRejected = false }
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class HelioSessionTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = testNow
    private let strapID = "5B1E4C2A-0000-4000-8000-0000000000A1"

    override func tearDown() {
        containers.removeAll()
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

    private struct Rig {
        let session: HelioSession
        let transport: FakeStrapTransport
        let keyStore: MemoryKeyStore
        var synced: [HelioSyncResult]
    }

    /// A connected session over `device`, started and drained until it settles.
    private func connect(_ device: FakeZeppDevice, store: LocalStore?, key: String? = keyHex,
                         keyStore: MemoryKeyStore? = nil, findState: HelioFindState? = nil,
                         autoSync: Bool = true, finished: @escaping (HelioSyncResult) -> Void = { _ in }) -> Rig {
        let transport = FakeStrapTransport(device: device)
        let keys = keyStore ?? MemoryKeyStore(key)
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: store.map { HelioStoreSink(store: $0) }, findState: findState ?? HelioFindState(),
                                   onSyncFinished: { result, _ in finished(result) },
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: autoSync)
        transport.session = session
        session.start()
        transport.drain()
        return Rig(session: session, transport: transport, keyStore: keys, synced: [])
    }

    private func rows(_ store: LocalStore) throws -> [String] {
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "\($0.deviceID) \($0.kindRaw) \($0.start.timeIntervalSince1970) \($0.value)" }
        let steps = try store.context.fetch(FetchDescriptor<StoredStepSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "step \($0.start.timeIntervalSince1970) \($0.end.timeIntervalSince1970) \($0.delta)" }
        let dailies = try store.context.fetch(FetchDescriptor<StoredDaily>()).map { "daily \($0.day.timeIntervalSince1970) \($0.steps)" }
        let nights = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            .map { "night \($0.night.timeIntervalSince1970) asleep \($0.asleepMin) deep \($0.deepMin) rem \($0.remMin) temp \($0.skinTempC)" }
        return (samples + steps + dailies + nights).sorted()
    }

    // MARK: auth ok → clock set → fetch all types → store rows → ack 03 09 every round

    func testAFullSyncSetsTheClockStoresEveryTypeAndAcksKeepEveryRound() async throws {
        let store = try makeStore()
        let device = makeStrap()
        var results: [HelioSyncResult] = []
        let rig = connect(device, store: store, finished: { results.append($0) })

        XCTAssertTrue(device.authenticated)
        XCTAssertEqual(device.timeSetCount, 1, "decision 9: the clock is set after auth on every connection")
        XCTAssertTrue(rig.session.clockSet)
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.batteryPercent, 0x57, "the battery endpoint's level replaces the unauthenticated read")
        XCTAssertEqual(rig.session.hardwareVersion, "9.9.9.9")

        // Every planned type was started, each first round from its watermark.
        let startedTypes = Set(device.fetchStarts.compactMap { ZeppFetchType(rawValue: $0[1]) })
        XCTAssertEqual(startedTypes, Set(HelioFetchPlan.types))
        // Decision 8: every round, delivered or empty, is acked 03 09. Never 03 01.
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertEqual(Set(rig.session.fetchAcksSent), [0x09])
        XCTAssertEqual(device.failures, [])

        // Rows, all on the strap's own timeline (decision 10).
        let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: strapID)
        XCTAssertEqual(timeline.rawValue, "zeppos:\(strapID)")
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertTrue(samples.allSatisfy { $0.deviceID == timeline.rawValue })
        XCTAssertEqual(samples.filter { $0.kindRaw == "heartRate" }.count, 50, "60 minutes minus 10 unworn/charging without HR")
        XCTAssertEqual(samples.filter { $0.kindRaw == "hrvSDNN" }.map(\.value).sorted(), [41, 47], "HRV stored locally (decision 14)")
        XCTAssertEqual(samples.filter { $0.kindRaw == "spo2" }.map(\.value), [0.96])
        // Temperature: worn, in the strap's sleep window, 30–42 °C: 60 − 5 unworn − 5 charging − 1 at 29 °C.
        XCTAssertEqual(samples.filter { $0.kindRaw == "temperature" }.count, 49)
        let steps = try store.context.fetch(FetchDescriptor<StoredStepSample>())
        XCTAssertEqual(steps.count, 50)
        XCTAssertTrue(steps.allSatisfy { $0.delta == 5 && $0.end.timeIntervalSince($0.start) == 60 })
        // The strap's night, with its nightly skin temperature.
        let nights = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights.first?.asleepMin, 480)
        XCTAssertEqual(nights.first?.deepMin, 60)
        XCTAssertEqual(nights.first?.remMin, 60)
        // Each type's watermark, under the strap's timeline.
        let cursors = store.helioFetchCursors(device: timeline)
        XCTAssertNotNil(cursors[.activity])
        XCTAssertNotNil(cursors[.temperature])
        XCTAssertNotNil(cursors[.sleepSession])

        // The Health pass hands over the night and the timeline; HRV is not a Health kind for it.
        for _ in 0..<200 where results.isEmpty { await Task.yield() }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.nights.count, 1)
        let pending = try store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds())
        XCTAssertFalse(pending.contains { $0.kind == .hrvSDNN }, "decision 14: never written to Apple Health")
        XCTAssertTrue(pending.contains { $0.kind == .heartRate })
        XCTAssertTrue(pending.contains { $0.kind == .temperature })
        XCTAssertTrue(try store.pendingHealthSamples().isEmpty, "the ring's timeline is untouched")
    }

    // MARK: the same history twice → no duplicate rows

    func testSyncingTheSameHistoryTwiceLeavesIdenticalRows() throws {
        let store = try makeStore()
        let device = makeStrap()
        _ = connect(device, store: store)
        let first = try rows(store)
        XCTAssertFalse(first.isEmpty)

        // A new connection re-delivers everything (the strap keeps what 03 09 acknowledged, §6.3).
        clock = clock.addingTimeInterval(600)
        _ = connect(device, store: store)
        XCTAssertEqual(try rows(store), first)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    // MARK: wrong key → key rejected, no retry loop

    func testAWrongKeyIsRejectedOnceAndNeverRetried() throws {
        let device = makeStrap(authKey: "ffeeddccbbaa99887766554433221100")
        let keys = MemoryKeyStore(keyHex)
        let rig = connect(device, store: try makeStore(), keyStore: keys)
        XCTAssertEqual(rig.session.phase, .keyRejected)
        XCTAssertTrue(keys.isRejected)
        XCTAssertFalse(device.authenticated)
        let authMessages = device.receivedEndpoints.filter { $0 == 0x0082 }.count
        XCTAssertEqual(authMessages, 2, "one 04 and one 05")

        // Time passes: nothing is re-sent on this connection.
        clock = clock.addingTimeInterval(3600)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, authMessages)

        // A later connection with the same (rejected) key doesn't authenticate at all.
        let again = connect(device, store: try makeStore(), keyStore: keys)
        XCTAssertEqual(again.session.phase, .keyRejected)
        XCTAssertFalse(again.transport.writes.contains { $0.characteristic == .chunkedWrite })
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, authMessages)
        XCTAssertFalse(again.session.capabilities.contains(.historySync))

        // Replacing the key clears the mark.
        XCTAssertTrue(try keys.save(pasted: "0x" + keyHex))
        XCTAssertFalse(keys.isRejected)
    }

    func testAStrapThatNeverAnswersIsReportedBusy() throws {
        let device = makeStrap()
        let transport = FakeStrapTransport(device: device)
        transport.silent = true
        let keys = MemoryKeyStore(keyHex)
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: nil, findState: HelioFindState(), clock: { [unowned self] in self.clock },
                                   autoTick: false)
        transport.session = session
        session.start()
        transport.drain()
        XCTAssertEqual(session.phase, .authenticating)
        clock = clock.addingTimeInterval(HelioSession.authTimeout + 1)
        session.tick(now: clock)
        XCTAssertEqual(session.phase, .strapBusy)
        XCTAssertFalse(keys.isRejected, "busy is not a wrong key")
    }

    func testWithoutAKeyOnlyStandardHeartRateIsShown() throws {
        let device = makeStrap()
        let rig = connect(device, store: try makeStore(), key: nil)
        XCTAssertEqual(rig.session.phase, .keyless)
        XCTAssertFalse(rig.transport.writes.contains { $0.characteristic == .chunkedWrite }, "nothing is sent without a key")
        XCTAssertTrue(rig.transport.notifyChanges.contains { $0 == (.heartRateMeasurement, true) })
        XCTAssertNil(rig.session.liveHR, "no data is made up")
        XCTAssertFalse(rig.session.capabilities.contains(.liveHeartRate))

        rig.transport.push([FakeZeppDevice.Notification(characteristic: .heartRateMeasurement, bytes: [0x00, 62])])
        rig.transport.drain()
        XCTAssertEqual(rig.session.liveHR, 62)
        XCTAssertTrue(rig.session.capabilities.contains(.liveHeartRate))
        XCTAssertFalse(rig.session.capabilities.contains(.historySync))
    }

    // MARK: find start → leaving the screen or backgrounding → stop 06

    func testFindStopsWhenTheAppBackgroundsOrTheScreenIsLeft() throws {
        let device = makeStrap()
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertTrue(rig.session.capabilities.contains(.findMyDevice))
        XCTAssertEqual(rig.session.findVersion, 2)

        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        rig.session.appDidEnterBackground()
        rig.transport.drain()
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(device.findOpcodes.suffix(2), [0x03, 0x06])

        // Leaving the Find My Strap screen calls `stopFind()`.
        XCTAssertNil(rig.session.startFind())
        rig.session.stopFind()
        rig.transport.drain()
        XCTAssertEqual(device.findOpcodes.suffix(2), [0x03, 0x06])
        XCTAssertFalse(device.isBuzzing)
    }

    func testFindStopsAfterSixtySecondsAndABuzzAfterTwo() throws {
        let device = makeStrap()
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        clock = clock.addingTimeInterval(59)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        clock = clock.addingTimeInterval(1)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertFalse(device.isBuzzing, "decision 18: 60 s at most")

        XCTAssertNil(rig.session.buzz())
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        clock = clock.addingTimeInterval(2)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertFalse(device.isBuzzing, "decision 19: a 2 s buzz")
        XCTAssertEqual(device.findOpcodes.filter { $0 == 0x03 }.count, device.findOpcodes.filter { $0 == 0x06 }.count)
    }

    func testALinkDropMidFindSendsTheStopOnTheNextConnection() throws {
        let device = makeStrap()
        let findState = HelioFindState()
        let rig = connect(device, store: nil, findState: findState, autoSync: false)
        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        rig.session.linkLost()
        XCTAssertTrue(device.isBuzzing, "the stop could not go out")

        let next = connect(device, store: nil, findState: findState, autoSync: false)
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(next.session.findPhase, .stopped(.linkLost))
        XCTAssertEqual(Array(device.findOpcodes.suffix(2)), [0x06, 0x01], "the owed stop, then the capabilities request")
    }

    func testAFindStopOwedSurvivesTheProcess() throws {
        let suite = "test.HelioSessionTests.findStop"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = makeStrap()
        let rig = connect(device, store: nil, findState: HelioFindState(defaults: defaults), autoSync: false)
        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        XCTAssertTrue(defaults.bool(forKey: HelioFindState.stopOwedKey))

        // The system ends the process with the strap still buzzing. The next process's first
        // connection sends the stop before anything else on the find endpoint.
        let next = connect(device, store: nil, findState: HelioFindState(defaults: defaults), autoSync: false)
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(Array(device.findOpcodes.suffix(2)), [0x06, 0x01])
        XCTAssertFalse(defaults.bool(forKey: HelioFindState.stopOwedKey))

        // A find stopped normally leaves nothing owed.
        XCTAssertNil(next.session.startFind())
        XCTAssertTrue(defaults.bool(forKey: HelioFindState.stopOwedKey))
        next.session.stopFind()
        next.transport.drain()
        XCTAssertFalse(defaults.bool(forKey: HelioFindState.stopOwedKey))
    }

    func testControlsTheStrapDoesNotListAreHidden() throws {
        let device = makeStrap()
        device.services = helioServices.filter { $0.endpoint != 0x001A && $0.endpoint != 0x000F }
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertFalse(rig.session.capabilities.contains(.findMyDevice))
        XCTAssertFalse(rig.session.capabilities.contains(.vibration))
        XCTAssertFalse(rig.session.capabilities.contains(.alarm))
        XCTAssertNotNil(rig.session.startFind(), "nothing is sent to an unlisted endpoint")
        XCTAssertEqual(device.findOpcodes, [])
        XCTAssertEqual(device.alarmCommands, [])
    }

    // MARK: an alarm edit writes exactly one slot, after a read

    func testAnAlarmEditWritesExactlyOneSlotAfterARead() throws {
        let device = makeStrap()
        // One alarm the person made in Zepp, in slot 3: 09:15, Sat + Sun, disabled.
        device.alarmRecords = [3: [0x00, 0x03, 0x09, 0x0f, 0x60, 0x00, 0x00, 0x00, 0x01, 0x00]]
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertEqual(device.alarmCommands, [[0x09]], "setup reads the list and writes nothing (§15.1)")
        XCTAssertEqual(rig.session.alarmEditor?.alarms?.map(\.slot), [3])
        XCTAssertTrue(rig.session.alarmEditor?.canEdit == true, "the clock was set on this connection")

        XCTAssertNil(rig.session.addAlarm(hour: 6, minute: 30, days: .weekdays))
        rig.transport.drain()
        XCTAssertEqual(device.alarmCommands, [
            [0x09],
            [0x03, 0x01, 0x04, 0x00, 0x06, 0x1e, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00],   // slot 0, the lowest free
            [0x09],                                                                      // re-read
        ])
        XCTAssertEqual(rig.session.alarmEditor?.alarms?.map(\.slot), [0, 3])
        XCTAssertEqual(rig.session.alarmNotice, "Saved on the strap.")

        // Enabling the Zepp alarm rewrites only its own slot.
        var zepp = try XCTUnwrap(rig.session.alarmEditor?.alarms?.first { $0.slot == 3 })
        zepp.isEnabled = true
        XCTAssertNil(rig.session.replaceAlarm(zepp))
        rig.transport.drain()
        let writes = device.alarmCommands.filter { $0.first == 0x03 || $0.first == 0x05 }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?[3], 3, "slot 3 only")
        XCTAssertEqual(device.alarmCommands.last, [0x09])
    }

    // MARK: identity and capabilities

    func testIdentityNamesTheStrapForAppleHealth() throws {
        let device = makeStrap()
        let rig = connect(device, store: nil, autoSync: false)
        let fields = try XCTUnwrap(HealthDeviceAttribution.fields(for: rig.session.identity, origin: .device))
        XCTAssertEqual(fields.name, "Helio Strap")
        XCTAssertEqual(fields.manufacturer, "Amazfit")
        XCTAssertEqual(fields.model, "Helio Strap")
        XCTAssertEqual(fields.hardwareVersion, "9.9.9.9")
        XCTAssertEqual(fields.firmwareVersion, "1.2.3.4", "from the device-info read (§5.3): the Helio has no DIS firmware")
        // The family rule (#222): a device's localIdentifier is its timeline, the strap's own zeppos:<id>.
        XCTAssertEqual(fields.localIdentifier, "zeppos:\(strapID)")
        XCTAssertNotEqual(fields.localIdentifier, SyncDeviceID.ringConn.rawValue)
        XCTAssertNil(HealthDeviceAttribution.fields(for: rig.session.identity, origin: .userEntered),
                     "manual entries carry no device (decision 11)")
        XCTAssertEqual(rig.session.deviceKind, .zeppOS(model: "Helio Strap"))
    }

    // MARK: review follow-ups

    func testActiveHRMonitoringIsNeverARecordingWarning() throws {
        // HEALTH read reply: all-day HR 00 (off), 0x04 (Active HR monitoring) off, stress off.
        let reply = try XCTUnwrap(ZeppConfig.parseReadReply(
            [0x04, 0x01, 0x08, 0x03, 0x00, 0x03, 0x01, 0x10, 0x00, 0x04, 0x0b, 0x00, 0x13, 0x0b, 0x00]))
        let warnings = HelioSession.recordingWarnings(ZeppHealthSettings(reply))
        XCTAssertEqual(warnings.count, 2, "all-day HR and stress; never 0x04")
        XCTAssertFalse(warnings.contains { $0.localizedCaseInsensitiveContains("activity") })
        XCTAssertTrue(HelioSession.recordingWarnings(ZeppHealthSettings(
            try XCTUnwrap(ZeppConfig.parseReadReply([0x04, 0x01, 0x08, 0x03, 0x00, 0x01, 0x04, 0x0b, 0x00])))).isEmpty)
    }

    func testADisconnectMidSyncAcksTheOpenRoundKeep() throws {
        let store = try makeStore()
        let device = makeStrap()
        let rig = connect(device, store: store, autoSync: false)
        rig.session.syncHistory(manual: true)
        // Enable notify, send the first start, and let its reply open a round, then stop draining.
        rig.transport.drainSteps(3)
        let acksBefore = rig.session.fetchAcksSent.count
        rig.session.abortSync()
        XCTAssertEqual(rig.session.fetchAcksSent.count, acksBefore + 1)
        XCTAssertEqual(rig.session.fetchAcksSent.last, 0x09)
    }

    // MARK: review-223 U1: a round the strap never answers after our 03 09

    func testARoundTheStrapNeverAnswersAfterOurKeepAckTripsTheStallTimeoutAndTheNextSyncWorks() throws {
        let store = try makeStore()
        let device = makeStrap()
        // A hostile announcement: 4 MiB of automatic stress (over the record limit, review-223 N1). The
        // app refuses it with 03 09 and no 02, and this strap then never answers (no 10 03).
        device.announcedLengths[.autoStress] = 4 << 20
        device.unansweredAckTypes = [.autoStress]
        var results: [HelioSyncResult] = []
        let rig = connect(device, store: store, finished: { results.append($0) })
        XCTAssertEqual(rig.session.phase, .syncing, "stuck waiting for the ack reply")
        XCTAssertEqual(device.fetchAcks.last, 0x09)
        let stressStart = try XCTUnwrap(device.fetchStarts.last)
        XCTAssertEqual(stressStart[1], ZeppFetchType.autoStress.rawValue)

        // No progress for the stall timeout: the sync ends cleanly, interrupted, nothing more is sent.
        let writesBefore = rig.transport.writes.count
        clock = clock.addingTimeInterval(HelioSession.syncStallTimeout - 1)
        rig.session.tick(now: clock)
        XCTAssertEqual(rig.session.phase, .syncing)
        clock = clock.addingTimeInterval(2)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.lastSyncResult?.interrupted, true)
        XCTAssertEqual(rig.session.syncStatus, "Sync interrupted: what arrived is saved, the rest stays on the strap")
        XCTAssertFalse(rig.transport.writes[writesBefore...].contains { $0.characteristic == .activityControl && $0.bytes.first == 0x03 },
                       "the round already had its 03 09; the abort sends no second ack")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        let storedBefore = try store.context.fetch(FetchDescriptor<StoredSample>()).count
        XCTAssertGreaterThan(storedBefore, 0, "the rounds before it stay stored")

        // The strap answers again: the next sync on the same connection runs every type to the end.
        device.unansweredAckTypes = []
        device.announcedLengths = [:]
        let startsBefore = device.fetchStarts.count
        rig.session.syncHistory(manual: true)
        rig.transport.drain()
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.lastSyncResult?.interrupted, false)
        XCTAssertEqual(Set(device.fetchStarts[startsBefore...].compactMap { ZeppFetchType(rawValue: $0[1]) }),
                       Set(HelioFetchPlan.types))
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)
    }

    func testALateNotifyOffDoesNotStartTheNextFetch() throws {
        let store = try makeStore()
        let device = makeStrap()
        let rig = connect(device, store: store, autoSync: false)
        rig.session.syncHistory(manual: true)
        let startsBefore = device.fetchStarts.count
        // The previous sync's teardown lands after the new sync asked for notify-on.
        rig.session.notificationStateChanged(.activityControl, enabled: false, failed: false)
        rig.session.notificationStateChanged(.activityData, enabled: false, failed: false)
        XCTAssertEqual(device.fetchStarts.count, startsBefore, "no start before notify is back on")
        rig.transport.drain()
        XCTAssertGreaterThan(device.fetchStarts.count, startsBefore)
    }
}

// MARK: - Key store, device choice

@MainActor
final class HelioKeyStoreTests: XCTestCase {
    private let suite = "test.HelioKeyStoreTests"

    func testTheKeychainRoundTripsAndForgets() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = HelioKeyStore(service: "com.standardsoftwaresolutions.opencircuit.tests.helio", account: "t", defaults: defaults)
        store.forget()
        XCTAssertNil(store.load())
        XCTAssertFalse(try store.save(pasted: "not a key"))
        XCTAssertNil(store.load(), "an invalid paste saves nothing")
        XCTAssertTrue(try store.save(pasted: "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"))
        XCTAssertEqual(store.load(), HelioKeyText.parse(keyHex))
        store.markRejected()
        XCTAssertTrue(store.isRejected)
        XCTAssertTrue(try store.save(pasted: keyHex))
        XCTAssertFalse(store.isRejected, "a replaced key starts fresh")
        store.forget()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.isRejected)
    }

    func testTheSavedKeyNeverAppearsInADescription() throws {
        let key = try XCTUnwrap(HelioKeyText.parse(keyHex))
        XCTAssertFalse(String(describing: key).contains("0011"))
        XCTAssertFalse(String(reflecting: key).contains("0011"))
    }

    func testTheRingIsTheDefaultDevice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(ActiveDeviceChoiceStore.persisted(defaults), .ringConn, "an existing ring user sees no change")
        let store = ActiveDeviceChoiceStore(defaults: defaults)
        XCTAssertTrue(store.isRing)
        store.set(.helioStrap)
        XCTAssertEqual(ActiveDeviceChoiceStore.persisted(defaults), .helioStrap)
        XCTAssertTrue(ActiveDeviceChoiceStore(defaults: defaults).isHelio)
    }

    func testTheStrapsStepsLandAsMinuteDeltasOnceOnly() throws {
        let container = try ModelContainer(for: StoredSample.self, StoredCursor.self, StoredDaily.self, StoredStepSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LocalStore(container.mainContext)
        let device = SyncDeviceID(rawValue: "zeppos:test")
        let t0 = Date(timeIntervalSince1970: midnight + 8 * 3600)
        let minutes = (0..<3).map { QuantitySample(kind: .steps, start: t0.addingTimeInterval(Double($0) * 60),
                                                   end: t0.addingTimeInterval(Double($0 + 1) * 60), value: 10) }
        XCTAssertEqual(try store.ingestHelioStepMinutes(minutes, device: device, now: testNow), 3)
        XCTAssertEqual(try store.ingestHelioStepMinutes(minutes, device: device, now: testNow), 0, "re-delivered minutes are skipped")
        XCTAssertEqual(try store.todaySteps(day: t0), 30)
        let pending = try store.pendingStepSamples()
        XCTAssertEqual(pending.map(\.delta), [10, 10, 10])
        XCTAssertEqual(pending.map { $0.end.timeIntervalSince($0.start) }, [60, 60, 60], "each over its real minute")
        withExtendedLifetime(container) {}
    }
}

// MARK: - Key states and Health attribution

@MainActor
final class HelioStatusTests: XCTestCase {

    func testTheKeyStatesOfDecisionSeven() {
        func status(_ state: HelioConnection.State, _ phase: HelioSession.Phase?, key: Bool = true,
                    rejected: Bool = false, saved: Bool = true) -> HelioStatus.Kind {
            HelioStatus.from(connection: state, phase: phase, hasKey: key, keyRejected: rejected, hasSavedStrap: saved).kind
        }
        XCTAssertEqual(status(.idle, nil, key: false, saved: false), .notSetUp)
        XCTAssertEqual(status(.idle, nil, key: false), .keyNeeded)
        XCTAssertEqual(status(.idle, nil, rejected: true), .keyRejected)
        XCTAssertEqual(status(.connected, .keyless, key: false), .keyNeeded)
        XCTAssertEqual(status(.connected, .keyRejected), .keyRejected)
        XCTAssertEqual(status(.connected, .strapBusy), .strapBusy)
        XCTAssertEqual(status(.connected, .syncing), .syncing)
        XCTAssertEqual(status(.connected, .ready), .ready)
        XCTAssertEqual(status(.searching, nil), .searching)
        XCTAssertEqual(status(.bluetoothOff, .ready), .bluetoothOff)
    }

    func testTheZeppCoexistenceCopyIsVerbatim() {
        XCTAssertEqual(HelioStatus.dontUnpairCopy,
                       "Don't unpair the strap in the Zepp app; unpairing makes the key stop working.")
        XCTAssertEqual(HelioStatus.zeppBluetoothCopy,
                       "To let OpenCircuit connect, turn off Bluetooth for Zepp (Settings ▸ Zepp ▸ Bluetooth) or delete the Zepp app.")
        let busy = HelioStatus.from(connection: .connected, phase: .strapBusy, hasKey: true, keyRejected: false, hasSavedStrap: true)
        XCTAssertTrue(busy.detail?.contains(HelioStatus.zeppBluetoothCopy) == true)
        XCTAssertTrue(HelioStatus.keyGuideURL.absoluteString.hasSuffix("docs/HELIO_KEY_EXTRACTION.md"))
    }

    func testHealthWritesNameTheStrapWhenItIsTheActiveDevice() throws {
        let suite = "test.HelioStatusTests.identity"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let device = makeStrap()
        let transport = FakeStrapTransport(device: device)
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000B2",
                                   key: HelioKeyText.parse(keyHex), keyStore: MemoryKeyStore(keyHex), sink: nil,
                                   findState: HelioFindState(), clock: { testNow }, autoTick: false, autoSyncOnConnect: false)
        transport.session = session
        session.start()
        transport.drain()
        let active = ActiveWearable(session: { session }, fallbackDeviceID: { nil },
                                    identityStore: WearableIdentityStore(defaults))
        let fields = try XCTUnwrap(HealthDeviceAttribution.fields(for: active.identityForHealthWrite(), origin: .device))
        XCTAssertEqual(fields.name, "Helio Strap")
        XCTAssertEqual(fields.manufacturer, "Amazfit")
        XCTAssertEqual(fields.hardwareVersion, "9.9.9.9")
        XCTAssertEqual(fields.firmwareVersion, "1.2.3.4",
                       "the first-write guard needs a firmware version: it is read before the first sync")
        XCTAssertEqual(fields.localIdentifier, "zeppos:5B1E4C2A-0000-4000-8000-0000000000B2")
        XCTAssertTrue(active.capabilities.contains(.historySync))
    }
}

// MARK: - Background sync (#215 phase 4)

/// `HelioBackgroundLink` over the simulated strap: what `HelioConnection` does for a background run,
/// minus CoreBluetooth. A connect builds a session over a `FakeStrapTransport`; events reach it only
/// when the test's `pause` drains them, as CoreBluetooth hands them over on later run-loop turns.
@MainActor
private final class FakeBackgroundLink: HelioBackgroundLink {
    let device: FakeZeppDevice
    let keyStore: MemoryKeyStore
    let store: LocalStore?
    let findState = HelioFindState()
    let clock: () -> Date
    var strapID: String? = "5B1E4C2A-0000-4000-8000-0000000000C3"
    /// false: a connect is armed but never completes (the strap is out of range).
    var inRange = true
    /// The strap never answers (another phone holds it).
    var silent = false
    var endedBusy = false
    var backgroundRunActive = false
    private(set) var session: HelioSession?
    private(set) var transport: FakeStrapTransport?
    private(set) var connects = 0
    private(set) var disconnects = 0

    init(device: FakeZeppDevice, keyStore: MemoryKeyStore, store: LocalStore?, clock: @escaping () -> Date) {
        self.device = device
        self.keyStore = keyStore
        self.store = store
        self.clock = clock
    }

    var strapTimeline: SyncDeviceID? {
        strapID.map { SyncDeviceID.timeline(for: .zeppOS(model: HelioSession.displayName), identityID: $0) }
    }

    func connectForBackground() -> Bool {
        connects += 1
        guard let strapID else { return false }
        guard inRange else { return true }
        let transport = FakeStrapTransport(device: device)
        transport.silent = silent
        let session = HelioSession(transport: transport, identityID: strapID, key: keyStore.load(), keyStore: keyStore,
                                   sink: store.map { HelioStoreSink(store: $0) }, findState: findState,
                                   clock: clock, autoTick: false)
        session.backgroundRunOwnsSyncs = backgroundRunActive
        transport.session = session
        self.transport = transport
        self.session = session
        session.start()
        return true
    }

    func disconnectForBackground() {
        disconnects += 1
        if session?.phase == .strapBusy { endedBusy = true }
        session?.stopFind()
        session?.abortSync()
        session?.linkLost()
        session = nil
        transport = nil
    }
}

@MainActor
final class HelioBackgroundSyncTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = testNow
    private var defaults: UserDefaults!
    private let suite = "test.HelioBackgroundSyncTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        containers.removeAll()
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

    private func rows(_ store: LocalStore) throws -> [String] {
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "\($0.deviceID) \($0.kindRaw) \($0.start.timeIntervalSince1970) \($0.value)" }
        let steps = try store.context.fetch(FetchDescriptor<StoredStepSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "step \($0.start.timeIntervalSince1970) \($0.end.timeIntervalSince1970) \($0.delta)" }
        let dailies = try store.context.fetch(FetchDescriptor<StoredDaily>()).map { "daily \($0.day.timeIntervalSince1970) \($0.steps)" }
        let nights = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            .map { "night \($0.night.timeIntervalSince1970) asleep \($0.asleepMin) deep \($0.deepMin) rem \($0.remMin) temp \($0.skinTempC)" }
        return (samples + steps + dailies + nights).sorted()
    }

    /// What the service handed to Apple Health.
    private struct FlushCall {
        let timeline: SyncDeviceID
        let nights: Int
        let finalized: Bool
        let rowsAtFlush: Int
    }

    /// The service over `link`. `pause` moves the simulated strap along (default: deliver everything
    /// queued, one second passes); the Health pass is recorded instead of written.
    private func service(_ link: FakeBackgroundLink, store: LocalStore, flushes: @escaping (FlushCall) -> Void = { _ in },
                         pause: (@MainActor () -> Void)? = nil) -> HelioBackgroundSyncService {
        HelioBackgroundSyncService(
            link: link, keyStore: link.keyStore, observability: ObservabilityStore(defaults),
            flush: { [unowned self] timeline, nights, finalized in
                let count = (try? self.rows(store).count) ?? 0
                flushes(FlushCall(timeline: timeline, nights: nights.count, finalized: finalized, rowsAtFlush: count))
                var result = HealthKitWriter.FlushResult()
                result.samples = count
                return result
            },
            now: { [unowned self] in self.clock },
            pause: { [unowned self] in
                if let pause { pause() } else { link.transport?.drain() }
                self.clock = self.clock.addingTimeInterval(1)
                link.session?.tick(now: self.clock)
                await Task.yield()
            },
            grace: { link.transport?.drain() })
    }

    private func lastRecord() -> TaskRecord? { ObservabilityStore(defaults).records().last }

    // MARK: a background run with the strap chosen: drain → store → Health → run log

    func testABackgroundRunDrainsTheStrapStoresRowsFlushesHealthAndLogsIt() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)

        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(run.result?.interrupted, false)
        XCTAssertTrue(run.success)
        XCTAssertEqual(link.connects, 1, "connect by identifier once")
        XCTAssertEqual(link.disconnects, 0, "a finished run leaves the idle link up")
        XCTAssertTrue(device.authenticated)
        XCTAssertEqual(device.timeSetCount, 1, "decision 9: the clock is set on the background connection too")
        XCTAssertEqual(Set(device.fetchAcks), [0x09], "decision 8: keep-on-strap for every round")
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)

        // Rows on the strap's timeline, as a foreground sync stores them.
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertTrue(samples.allSatisfy { $0.deviceID == "zeppos:5B1E4C2A-0000-4000-8000-0000000000C3" })
        XCTAssertEqual(samples.filter { $0.kindRaw == "heartRate" }.count, 50)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).count, 1)

        // Health: one flush, after the rows were committed, with the night; not finalized (BGTask).
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(flushes.first?.timeline, link.strapTimeline)
        XCTAssertEqual(flushes.first?.nights, 1)
        XCTAssertEqual(flushes.first?.finalized, false)
        XCTAssertEqual(flushes.first?.rowsAtFlush, try rows(store).count)
        XCTAssertNotNil(run.flushMS)

        // The run log: the ring's background log, labelled for the strap.
        let record = try XCTUnwrap(lastRecord())
        XCTAssertEqual(record.kind, .appRefresh)
        XCTAssertTrue(record.success)
        XCTAssertTrue(record.detail?.hasPrefix("helio strap: synced") == true, record.detail ?? "")
        XCTAssertTrue(ObservabilityStore(defaults).metricRecords().contains {
            $0.source == "bgphase" && $0.detail.hasPrefix("device=helio kind=appRefresh ending=synced")
        })
        XCTAssertNotNil(ObservabilityStore(defaults).bgLastRun)
        // The session is handed back: a later foreground sync on it flushes by itself again.
        XCTAssertEqual(link.session?.backgroundRunOwnsSyncs, false)
        XCTAssertFalse(link.backgroundRunActive)
    }

    func testTheSleepFocusRunFinalizesTheStrapsNights() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: true)
        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [true])
        XCTAssertEqual(lastRecord()?.kind, .sleepFocus)
    }

    func testAnAlreadyConnectedStrapIsSyncedWithoutReconnecting() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        // A foreground connection that already synced and stayed up.
        _ = link.connectForBackground()
        link.transport?.drain()
        XCTAssertEqual(link.session?.syncsFinished, 1)
        let startsBefore = device.fetchStarts.count

        let run = await service(link, store: store).run(kind: .processing, timeout: RingBackgroundSyncService.processingTimeout)
        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(link.connects, 1, "no second connect")
        XCTAssertEqual(link.session?.syncsFinished, 2, "a fresh sync on the open link")
        XCTAssertGreaterThan(device.fetchStarts.count, startsBefore)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    // MARK: expiration mid-round → 03 09, committed rows kept, next run resumes, no duplicates

    func testExpiryMidRoundAcksKeepKeepsCommittedRowsAndTheNextRunResumesWithoutDuplicates() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // One event per pause. iOS expires the task once the sleep-session round (the second type,
        // after activity's two rounds) has asked for its data: activity is committed, that round is open.
        var expired = false
        let operation = Task { @MainActor in
            await service(link, store: store, flushes: { flushes.append($0) }, pause: {
                link.transport?.drainSteps(1)
                let dataRequests = link.transport?.writes.filter { $0.characteristic == .activityControl && $0.bytes == [0x02] }.count ?? 0
                if !expired, dataRequests == 3, link.session?.fetchAcksSent.count == 2 {
                    expired = true
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }).run(kind: .appRefresh, timeout: 3600)
        }
        let run = await operation.value

        XCTAssertTrue(expired, "the test reached the open round")
        XCTAssertEqual(run.ending, .expired)
        XCTAssertFalse(run.success)
        XCTAssertEqual(link.disconnects, 1, "disconnected cleanly")
        XCTAssertNil(link.session)
        XCTAssertEqual(device.fetchStarts.count, 3)
        XCTAssertEqual(device.fetchAcks, [0x09, 0x09, 0x09], "the open round got its 03 09; nothing was deleted")
        XCTAssertEqual(run.result?.interrupted, true)
        XCTAssertTrue(flushes.isEmpty, "no Health flush once iOS has ended the task")
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: iOS ended the task") == true)

        // What was committed before the expiry stays: activity. The open round's night isn't stored.
        let timeline = try XCTUnwrap(link.strapTimeline)
        let afterFirst = try rows(store)
        XCTAssertTrue(afterFirst.contains { $0.contains(" heartRate ") })
        XCTAssertFalse(afterFirst.contains { $0.hasPrefix("night") })
        XCTAssertFalse(afterFirst.contains { $0.contains(" temperature ") })
        let cursors = store.helioFetchCursors(device: timeline)
        XCTAssertNotNil(cursors[.activity])
        XCTAssertNil(cursors[.sleepSession], "the open round's watermark never moved")

        // The next run resumes from the stored cursors and ends with exactly the rows one clean sync gives.
        clock = clock.addingTimeInterval(600)
        let plan = HelioFetchPlan.plan(cursors: cursors, now: clock)
        let startsBefore = device.fetchStarts.count
        let next = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(next.ending, .synced)
        var firstStarts: [[UInt8]] = []
        for start in device.fetchStarts[startsBefore...] where !firstStarts.contains(where: { $0[1] == start[1] }) {
            firstStarts.append(start)
        }
        XCTAssertEqual(firstStarts, plan.map { ZeppFetchCommand.start($0.type, since: $0.since, timeZone: .current) },
                       "every type's first round starts from its persisted cursor")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])

        let reference = try makeStore()
        let referenceLink = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: reference, clock: { [unowned self] in self.clock })
        _ = await service(referenceLink, store: reference).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(try rows(store), try rows(reference), "no duplicates, nothing missing")
        XCTAssertEqual(flushes.count, 1, "the second run flushed Health")
    }

    func testRunningOutOfBudgetAbandonsTheRoundFlushesWhatWasCommittedAndDisconnects() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // Two events a second: the ~20 s fetch window of an app-refresh task ends mid-sync.
        let run = await service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(2) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .outOfTime)
        XCTAssertEqual(link.disconnects, 1)
        XCTAssertFalse(device.fetchStarts.isEmpty, "the cut came during the fetch")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        // Every round the app saw opened was acked 03 09; a start whose reply hadn't arrived yet opened
        // nothing on the app's side (the strap keeps what it wasn't told to delete, §6.3).
        XCTAssertLessThanOrEqual(device.fetchStarts.count - device.fetchAcks.count, 1)
        XCTAssertEqual(flushes.count, 1, "what was committed still reaches Health inside the reserve")
        XCTAssertEqual(flushes.first?.rowsAtFlush, try rows(store).count)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: out of time") == true)
    }

    func testAStrapOutOfRangeKeepsThePendingConnectArmed() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        link.inRange = false
        let run = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .outOfTime)
        XCTAssertEqual(link.connects, 1, "one connect, no retry loop")
        XCTAssertEqual(link.disconnects, 0, "nothing to disconnect; the standing connect stays for restoration")
        XCTAssertTrue(try rows(store).isEmpty)
    }

    func testInTheBackgroundAStuckAckEndsWithTheBudgetAndTheNextRunSyncs() async throws {
        // review-223 U1 in a background task: the budget trips long before the 90 s stall timeout.
        let store = try makeStore()
        let device = makeStrap()
        device.announcedLengths[.autoStress] = 4 << 20
        device.unansweredAckTypes = [.autoStress]
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let stuck = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(stuck.ending, .outOfTime)
        XCTAssertEqual(link.disconnects, 1, "disconnected cleanly")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertGreaterThan(try rows(store).count, 0, "what was committed before the stuck round stays")

        device.unansweredAckTypes = []
        device.announcedLengths = [:]
        clock = clock.addingTimeInterval(600)
        let next = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(next.ending, .synced)
        XCTAssertEqual(next.result?.interrupted, false)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    // MARK: rejected / missing key, busy strap → no retry, no writes, a logged reason

    func testAMissingOrRejectedKeyEndsTheRunBeforeAnyRadioWork() async throws {
        let store = try makeStore()
        var flushes: [FlushCall] = []

        let noKey = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(nil), store: store, clock: { [unowned self] in self.clock })
        let first = await service(noKey, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(first.ending, .keyNeeded)
        XCTAssertEqual(noKey.connects, 0, "no connect, so no central is created")
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: key needed") == true)
        XCTAssertEqual(lastRecord()?.success, false)

        let keys = MemoryKeyStore(keyHex)
        keys.markRejected()
        let rejected = FakeBackgroundLink(device: makeStrap(), keyStore: keys, store: store, clock: { [unowned self] in self.clock })
        let second = await service(rejected, store: store, flushes: { flushes.append($0) }).run(kind: .processing, timeout: 150)
        XCTAssertEqual(second.ending, .keyRejected)
        XCTAssertEqual(rejected.connects, 0)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: key rejected") == true)

        let noStrap = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        noStrap.strapID = nil
        let third = await service(noStrap, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(third.ending, .noSavedStrap)
        XCTAssertEqual(noStrap.connects, 0)

        XCTAssertTrue(flushes.isEmpty, "no Health writes")
        XCTAssertTrue(try rows(store).isEmpty, "no store writes")
    }

    func testAKeyTheStrapRejectsInTheBackgroundIsNotRetried() async throws {
        let store = try makeStore()
        let device = makeStrap(authKey: "ffeeddccbbaa99887766554433221100")
        let keys = MemoryKeyStore(keyHex)
        let link = FakeBackgroundLink(device: device, keyStore: keys, store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(run.ending, .keyRejected)
        XCTAssertTrue(keys.isRejected, "decision 7: marked, so no later run tries it")
        XCTAssertEqual(link.connects, 1)
        XCTAssertEqual(link.disconnects, 1, "the link is dropped, not left retrying")
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, 2, "one 04 and one 05, once")

        let again = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(again.ending, .keyRejected)
        XCTAssertEqual(link.connects, 1, "no retry")
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, 2)
        XCTAssertTrue(flushes.isEmpty)
        XCTAssertTrue(try rows(store).isEmpty)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: key rejected") == true)
    }

    func testABusyStrapEndsTheRunAndIsNotRetried() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        link.silent = true
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(run.ending, .strapBusy, "no auth reply within 10 s")
        XCTAssertTrue(link.endedBusy)
        XCTAssertEqual(link.disconnects, 1)
        let again = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(again.ending, .strapBusy)
        XCTAssertEqual(link.connects, 1, "no retry loop")
        XCTAssertTrue(flushes.isEmpty)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: strap busy") == true)
    }

    // MARK: one device at a time (decision 1)

    func testABackgroundWakeRunsOnlyTheChosenDevicesDrain() throws {
        XCTAssertEqual(BackgroundDrain(.ringConn), .ring)
        XCTAssertEqual(BackgroundDrain(.helioStrap), .strap)
        XCTAssertEqual(BackgroundDrain(ActiveDeviceChoiceStore.persisted(defaults)), .ring,
                       "nothing chosen: the ring, as for every existing user")
    }

    func testWithTheRingChosenTheStrapsConnectionCreatesNoCentral() throws {
        // The live connection reads the process-wide choice; this test sets it and restores it.
        let standard = UserDefaults.standard
        let savedChoice = standard.object(forKey: ActiveDeviceChoiceStore.key)
        let savedStrap = standard.object(forKey: HelioConnection.savedPeripheralKey)
        defer {
            standard.set(savedChoice, forKey: ActiveDeviceChoiceStore.key)
            standard.set(savedStrap, forKey: HelioConnection.savedPeripheralKey)
        }
        standard.set(ActiveDeviceChoice.ringConn.rawValue, forKey: ActiveDeviceChoiceStore.key)
        standard.set("5B1E4C2A-0000-4000-8000-0000000000D4", forKey: HelioConnection.savedPeripheralKey)

        let connection = HelioConnection(keyStore: MemoryKeyStore(keyHex))
        XCTAssertFalse(connection.connectForBackground(), "the strap isn't the chosen device")
        XCTAssertFalse(connection.hasCentral, "so its central is never created")
        XCTAssertNil(connection.session)
    }
}
