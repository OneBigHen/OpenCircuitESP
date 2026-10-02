import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 50 (#253): a strap night reaches Apple Health even when a later sync keeps the stored night.
// 50a: the sink hands the STORED night to the sync's flush when the merge keeps it over a re-delivery.
// 50b: every strap flush also offers stored strap nights that never got a mirror record and have a
// later stored night after them. Every key, reading, id and time is synthetic.
//
// The writer itself can't write in the simulator (no Health access), so "the flush mirrors it" is
// shown in two halves: the night is in what `HelioConnection.flushStrap` hands the writer, ready to
// write, and the writer's own `mirrorSettledNight` gets past every bail to its write (`.failed`, the
// write being refused, never `.unchanged`). Then, with the record a successful write leaves, the
// same call is the signature no-op and neither 50a nor 50b offers the night again.

// MARK: - Fixtures

private let sMidnight: TimeInterval = 1_789_862_400          // 2026-09-20T00:00:00Z
private let sNow = Date(timeIntervalSince1970: sMidnight + 12 * 3600)
private let sKeyHex = "00112233445566778899aabbccddeeff"
private func hour(_ h: Double) -> Date { Calendar.current.startOfDay(for: sNow).addingTimeInterval(h * 3600) }

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// Stage bytes (ZEPP_PROTOCOL.md §6.6): light, deep, awake, REM.
private let light: UInt8 = 0x04, deep: UInt8 = 0x05, awake: UInt8 = 0x07, rem: UInt8 = 0x08

/// One strap sleep session record over local hours of `hour(0)`'s day (minute fields count from the
/// previous local midnight, `ZeppSleepSession.absolute`).
private func session(_ stages: [(Double, Double, UInt8)]) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    func minute(_ h: Double) -> UInt16 { UInt16(((h + 24) * 60).rounded()) }
    let midnight = UInt32(hour(0).timeIntervalSince1970)
    put(le32(midnight), at: 0x000)
    put(le32(midnight), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(minute(stages.first!.0)), at: 0x00A)
    put(le16(minute(stages.last!.1)), at: 0x00C)
    r[0x016] = 81
    r[0x054] = UInt8(stages.count)
    for (i, stage) in stages.enumerated() { put(le16(minute(stage.0)) + le16(minute(stage.1)) + [stage.2], at: 0x056 + 5 * i) }
    return r
}

/// The night as first delivered: 23:00–07:00, all asleep (480 min).
private let firstDelivery: [(Double, Double, UInt8)] = [(-1, 2, light), (2, 3, deep), (3, 4, rem), (4, 7, light)]
/// The same night re-delivered by a later sync: five minutes wider at each end (past the merge's
/// one-epoch "same coverage" tolerance) and 15 asleep minutes fewer. The shape #253 measured: thinner
/// and slightly wider, so the merge keeps the stored night.
private let reDelivery: [(Double, Double, UInt8)] = [
    (-1 - 5.0 / 60, -1, awake), (-1, 2, light), (2, 3, deep), (3, 3.5, rem), (3.5, 3.75, awake), (3.75, 7, light),
    (7, 7 + 5.0 / 60, awake),
]

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func makeStrap(_ stages: [(Double, Double, UInt8)]) -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(sKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
    device.services = services
    device.deviceInfoReply = deviceInfoReply
    device.dataPacketLength = 200
    device.fetchData = [.sleepSession: (stamp(hour(0).timeIntervalSince1970 - 86_400), session(stages))]
    return device
}

@MainActor
private final class Transport: HelioTransport {
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
private final class Keys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(sKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class StrapNightHealthTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = sNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D050"
    /// Night keys whose mirror record a test may have written (`MirroredNightOverlay` lives in the
    /// standard defaults), cleared before and after each test.
    private var touchedNights: [Date] = []

    override func setUp() {
        super.setUp()
        touchedNights = (-12...2).map { hour(Double($0) * 24) }
        touchedNights.forEach(clearMirror)
    }

    override func tearDown() {
        touchedNights.forEach(clearMirror)
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func clearMirror(_ night: Date) {
        UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(Calendar.current.startOfDay(for: night).timeIntervalSince1970)")
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    /// One strap sync at `now` delivering `stages` as one session, through the production path; the result.
    private func sync(_ stages: [(Double, Double, UInt8)], at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let transport = Transport(device: makeStrap(stages))
        let keys = Keys()
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: HelioStoreSink(store: store), findState: HelioFindState(),
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = session
        session.start()
        transport.drain()
        let result = try XCTUnwrap(session.lastSyncResult)
        XCTAssertEqual(result.interrupted, false)
        return result
    }

    private func rows(_ store: LocalStore) throws -> [StoredSleepSummary] {
        try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.inBedStart)]))
    }

    private func storedHypnogram(_ store: LocalStore) throws -> [SleepSegment] {
        SleepHypnogramCodec.decode(try XCTUnwrap(try rows(store).first).hypnogramData)
    }

    /// What `mirrorSettledNight` records once its write succeeded: the signature and the span.
    private func recordMirror(_ segments: [SleepSegment], store: LocalStore) throws {
        let row = try XCTUnwrap(try store.sleepSummaryOverlapping(start: segments.map(\.start).min()!, end: segments.map(\.end).max()!))
        store.setMirroredNight(night: row.night, signature: HealthKitWriter.sleepSignature(segments),
                               spanStart: row.inBedStart, spanEnd: row.inBedEnd)
    }

    private func isUnchanged(_ outcome: HealthKitWriter.MirrorOutcome) -> Bool {
        if case .unchanged = outcome { return true }
        return false
    }

    /// The first sync stores the night 13 minutes after it ended, inside the settle margin.
    private func firstSync(_ store: LocalStore) throws -> HelioSyncResult {
        let first = try sync(firstDelivery, at: hour(7 + 13.0 / 60), store: store)
        XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(7))], "stored and handed over")
        XCTAssertFalse(SleepHealthGate.isReadyToWrite(latestSegmentEnd: hour(7), now: clock, finalized: false),
                       "and held behind the margin, as designed")
        XCTAssertEqual(try rows(store).map(\.asleepMin), [480])
        return first
    }

    // MARK: 50a: the reported case, end to end at sink + flush level

    func testAStoredNightKeptOverAThinnerReDeliveryReachesTheFlushAndTheMirror() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)

        // A later sync, after the margin, re-delivers it thinner and wider: the merge keeps the stored night.
        let second = try sync(reDelivery, at: hour(8), store: store)
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(try rows(store).count, 1)
        XCTAssertEqual(row.asleepMin, 480, "the stored night was kept")
        XCTAssertEqual(row.inBedStart, hour(-1))
        XCTAssertEqual(row.inBedEnd, hour(7))

        // The sync's result carries the STORED night.
        let stored = try storedHypnogram(store)
        XCTAssertEqual(second.nights.map(\.segments), [stored], "the stored night is handed to the flush")
        XCTAssertEqual(second.nights.first?.window, DateInterval(start: hour(-1), end: hour(7)))
        XCTAssertEqual(second.nights.first?.strapScore, 81)

        // The flush offers it to the writer once, ready to write.
        let input = HelioConnection.strapNights(second.nights.map(\.segments), store: store, timeline: timeline, now: clock)
        XCTAssertEqual(input, [stored])
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: stored.map(\.end).max(), now: clock, finalized: false))
        let writer = HealthKitWriter()
        let outcome = await writer.mirrorSettledNight(local: store, segments: stored)
        XCTAssertFalse(isUnchanged(outcome), "the writer gets past every bail to its write")

        // With the record that write leaves: the signature is the stored hypnogram's.
        try recordMirror(stored, store: store)
        XCTAssertEqual(store.mirroredNight(night: row.night)?.signature, HealthKitWriter.sleepSignature(stored))
    }

    /// A second flush after the night is mirrored writes nothing: neither path offers it again, and the
    /// writer's own mirror is the signature no-op.
    func testASecondFlushAfterTheMirrorWritesNothing() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        _ = try sync(reDelivery, at: hour(8), store: store)
        let stored = try storedHypnogram(store)
        try recordMirror(stored, store: store)

        let third = try sync(reDelivery, at: hour(9), store: store)
        XCTAssertEqual(third.nights.count, 0, "a mirrored night is not handed over again")
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: clock), [])
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: stored)
        XCTAssertTrue(isUnchanged(outcome), "the same night again is the signature no-op")
    }

    // MARK: 50a hands nothing over when…

    /// …the strap's re-delivered copy hasn't settled: the stored night ended 21 minutes ago, but the
    /// re-delivery runs five minutes later, so the margin is judged on its end. Five minutes on, it is.
    func testNothingIsHandedOverUntilTheReDeliveredCopyHasSettledToo() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let early = try sync(reDelivery, at: hour(7 + 21.0 / 60), store: store)
        XCTAssertTrue(SleepHealthGate.isSettled(latestSegmentEnd: hour(7), now: clock), "the stored row alone has settled")
        XCTAssertEqual(early.nights.count, 0)
        XCTAssertEqual(try rows(store).map(\.asleepMin), [480], "kept, not re-saved")

        let settled = try sync(reDelivery, at: hour(7 + 26.0 / 60), store: store)
        XCTAssertEqual(settled.nights.map(\.segments), [try storedHypnogram(store)])
    }

    /// …the night already has a Health mirror record (the mirror keeps a written night current), whether
    /// the record's span is the stored night's (28f's guard keeps the re-delivery out) or the re-delivery's.
    func testNothingIsHandedOverForANightWithAMirrorRecord() throws {
        for spanOfReDelivery in [false, true] {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try firstSync(store)
            let row = try XCTUnwrap(try rows(store).first)
            let span = spanOfReDelivery ? DateInterval(start: hour(-1 - 5.0 / 60), end: hour(7 + 5.0 / 60))
                                        : DateInterval(start: row.inBedStart, end: row.inBedEnd)
            store.setMirroredNight(night: row.night, signature: "written", spanStart: span.start, spanEnd: span.end)
            let second = try sync(reDelivery, at: hour(8), store: store)
            XCTAssertEqual(second.nights.count, 0, "record span of the re-delivery: \(spanOfReDelivery)")
            XCTAssertEqual(store.mirroredNight(night: row.night)?.signature, "written")
            clearMirror(row.night)
        }
    }

    /// …the night is manually edited.
    func testNothingIsHandedOverForAnEditedNight() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let row = try XCTUnwrap(try rows(store).first)
        row.isManuallyEdited = true
        try store.context.save()
        let second = try sync(reDelivery, at: hour(8), store: store)
        XCTAssertEqual(second.nights.count, 0)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: clock), [])
    }

    /// …the night is the ring's (28a): the ring went to bed with it, and the strap's re-delivery of it
    /// hands nothing over.
    func testNothingIsHandedOverForTheRingsNight() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(7.5))]))
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  extras: extras), .inserted)
        let second = try sync(reDelivery, at: hour(8), store: store)
        XCTAssertEqual(second.nights.count, 0)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: clock), [])
    }

    /// …the stored night has no hypnogram (it can't be offered as stored, and nothing is invented).
    func testNothingIsHandedOverForAStoredNightWithoutAHypnogram() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  device: timeline), .inserted)
        XCTAssertEqual(SleepHypnogramCodec.decode(try XCTUnwrap(try rows(store).first).hypnogramData), [])
        let second = try sync(reDelivery, at: hour(8), store: store)
        XCTAssertEqual(try rows(store).map(\.asleepMin), [480], "the merge kept the stored night")
        XCTAssertEqual(second.nights.count, 0)
    }

    // MARK: Ring-only: unchanged

    /// An empty ownership log (a ring-only install): the strap's sync stores no night and hands none
    /// over, and the flush input is exactly what it was given, even with the ring's stranded-looking
    /// nights in the store.
    func testRingOnlyTheSyncResultAndTheFlushInputAreUnchanged() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        try saveNight(store, from: -49, to: -41, device: .ringConn)
        try saveNight(store, from: -25, to: -17, device: .ringConn)
        let first = try sync(firstDelivery, at: hour(8), store: store)
        XCTAssertEqual(first.nights.count, 0)
        let given = [[SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]]
        XCTAssertEqual(HelioConnection.strapNights(given, store: store, timeline: timeline, now: hour(8)), given)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(8)), [])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(8)), [])
    }

    // MARK: 50b: the backstop in every strap flush

    /// A stored strap night `[from, to]` (local hours of `hour(0)`'s day) with its hypnogram.
    private func saveNight(_ store: LocalStore, from: Double, to: Double, device: SyncDeviceID? = nil) throws {
        let segments = [SleepSegment(start: hour(from), end: hour(from + 3), stage: .asleepCore),
                        SleepSegment(start: hour(from + 3), end: hour(to), stage: .asleepDeep)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        let outcome = try store.saveSleepSummary(SleepStaging.summary(segments),
                                                 night: SleepNightKey.night(inBedStart: hour(from), inBedEnd: hour(to)),
                                                 inBedStart: hour(from), inBedEnd: hour(to), sleepOnset: hour(from), sleepWake: hour(to),
                                                 extras: extras, device: device ?? timeline)
        XCTAssertEqual(outcome, .inserted)
    }

    private func hypnogram(_ store: LocalStore, endingAt to: Double) throws -> [SleepSegment] {
        let row = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(to) })
        return SleepHypnogramCodec.decode(row.hypnogramData)
    }

    /// A stranded strap night (no mirror record) with a later stored night after it is offered; the
    /// newest night isn't; one the sync already carries isn't offered twice.
    func testAStrandedStrapNightWithALaterNightIsOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let stranded = try hypnogram(store, endingAt: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(9)), [stranded])
        let tonight = try hypnogram(store, endingAt: 7)
        XCTAssertEqual(HelioConnection.strapNights([tonight], store: store, timeline: timeline, now: hour(9)), [tonight, stranded])
        XCTAssertEqual(HelioConnection.strapNights([stranded], store: store, timeline: timeline, now: hour(9)), [stranded],
                       "a night the sync carries is not offered twice")
        // The night 50a and 50b exist for, a day later: the next night stored, last night offered.
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: stranded.map(\.end).max(), now: hour(9), finalized: false))
    }

    /// The newest stored night is never offered, however long ago it ended: it can be a stale partial
    /// copy of a night still in progress (a sync whose sleep round ran out of time, here 23:00–03:00).
    /// Mirrored, 28f's "the written night stands" would keep the full night out for good.
    func testTheNewestNightIsNeverOfferedEvenAStalePartialOne() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 3)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(11)), [])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(11)), [])
        // And with an earlier night stored too, still only the earlier one.
        try saveNight(store, from: -25, to: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(11)), [try hypnogram(store, endingAt: -17)])
    }

    func testAStrandedNightWithAMirrorRecordIsNotOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        try recordMirror(try hypnogram(store, endingAt: -17), store: store)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    func testAnEditedNightIsNotOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let edited = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(-17) })
        edited.isManuallyEdited = true
        try store.context.save()
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    /// The ring went to bed with the earlier night (the switch to the strap came after it): it is the
    /// ring's, and the strap's flush never offers it.
    func testARingOwnedNightIsNotOffered() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(-12))]))
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17, device: .ringConn)
        try saveNight(store, from: -1, to: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    /// Older than 7 days: stays in the app.
    func testANightOlderThanSevenDaysIsNotOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -24 * 8 - 1, to: -24 * 8 + 7)
        try saveNight(store, from: -24 * 6 - 1, to: -24 * 6 + 7)
        try saveNight(store, from: -1, to: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)),
                       [try hypnogram(store, endingAt: -24 * 6 + 7)], "the 6-day-old night only")
    }

    /// The backstop for the reported case after its re-delivery window closed: no sync carries the
    /// night any more, the next night is stored, and the flush offers it as stored.
    func testTheBackstopOffersTheReportedNightOnceTheNextNightIsStored() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let stored = try storedHypnogram(store)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(12)), [],
                       "the newest night waits for 50a, never 50b")
        try saveNight(store, from: 23, to: 31)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(33)), [stored])
    }
}
