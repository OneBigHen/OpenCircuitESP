import BackgroundTasks
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
// write, and the writer's own `mirrorSettledNight` gets past every bail to its write: any outcome but
// `.unchanged` (without Health access the write itself is refused). Then, with the record a successful
// write leaves, the same call is the signature no-op and neither 50a nor 50b offers the night again.

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
    /// The sleep schedule's wake time every test runs with unless it passes its own (decision 57 B):
    /// 09:00, so the 07:00 fixtures end EARLY (before 08:00, the wake time less the slack) and their
    /// newest night takes the 3-hour path. Set in the standard defaults the production read uses, and
    /// put back afterwards.
    static let scheduleWake = 9 * 60
    private var savedWake: Any?

    override func setUp() {
        super.setUp()
        touchedNights = (-12...2).map { hour(Double($0) * 24) }
        touchedNights.forEach(clearMirror)
        savedWake = UserDefaults.standard.object(forKey: SleepScheduleDefaults.wakeMinutes)
        UserDefaults.standard.set(Self.scheduleWake, forKey: SleepScheduleDefaults.wakeMinutes)
    }

    override func tearDown() {
        if let savedWake {
            UserDefaults.standard.set(savedWake, forKey: SleepScheduleDefaults.wakeMinutes)
        } else {
            UserDefaults.standard.removeObject(forKey: SleepScheduleDefaults.wakeMinutes)
        }
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
    /// nil `stages`: the strap has stopped re-delivering the night (#262), so the sync carries no sleep.
    private func sync(_ stages: [(Double, Double, UInt8)]?, at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let device = makeStrap(stages ?? firstDelivery)
        if stages == nil { device.fetchData = [:] }
        let transport = Transport(device: device)
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

    /// Whether the writer stopped before its write step: nothing to do, or a refusal (#259 split the
    /// refusals out as `.declined`).
    private func isUnchanged(_ outcome: HealthKitWriter.MirrorOutcome) -> Bool {
        switch outcome {
        case .unchanged, .declined: return true
        case .wrote, .failed: return false
        }
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

    /// A newest night that ended far before the scheduled wake (here 23:00–03:00) isn't offered for 3
    /// hours after it ended (decision 57a): it can be the first part of a night still in progress.
    /// Mirrored, 28f's "the written night stands" would keep the full night out for good.
    func testAnEarlyEndingNewestNightIsNotOfferedWithinThreeHoursOfItsEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 3)
        let justBefore = hour(3).addingTimeInterval(LocalStore.strapNewestNightHealthBuffer - 1)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: justBefore), [])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: justBefore), [])
        // And with an earlier night stored too, only the earlier one.
        try saveNight(store, from: -25, to: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: justBefore), [try hypnogram(store, endingAt: -17)])
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

    /// #259: a night mirrored before a time-zone change is not offered again after it. Its record is
    /// under the start of its day in the zone it was stored in, which the current zone's day key no
    /// longer names.
    func testATimeZoneChangeDoesNotReOfferAMirroredNight() throws {
        ownership.install(.strapOwnsAllTime)
        let savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = savedZone }
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        try recordMirror(try hypnogram(store, endingAt: -17), store: store)
        let key = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(-17) }).night
        defer { UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(key.timeIntervalSince1970)") }
        let now = hour(9)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [])

        NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertNil(store.mirroredNight(night: key),
                     "this test only means something while the current zone's key misses the record")
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [],
                       "the night Apple Health already holds is not offered again")
    }

    /// #259: a stored night the writer declined is not offered on every flush after, until its
    /// stored hypnogram changes.
    func testANightTheWriterDeclinedIsNotOfferedAgainUntilItChanges() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let row = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(-17) })
        defer { StrapNightDeclinedOverlay.clear(storedNight: row.night) }
        let stranded = try hypnogram(store, endingAt: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded])

        // A declined offer that is NOT the stored hypnogram notes nothing.
        store.noteStrapNightDeclined(Array(stranded.prefix(1)))
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded])

        store.noteStrapNightDeclined(stranded)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [],
                       "the same stored night would meet the same refusal")

        // The stored night changes: a different offer, so it is offered again.
        let changed = [SleepSegment(start: hour(-25), end: hour(-21), stage: .asleepCore),
                       SleepSegment(start: hour(-21), end: hour(-17), stage: .asleepREM)]
        row.hypnogramData = SleepHypnogramCodec.encode(changed)
        try store.context.save()
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [changed])
    }

    /// #259: the writer reports a refusal the same staging would meet again (here, thinner than the
    /// card) as `declined`, not `unchanged`, so the strap flush can note it.
    func testTheWriterReportsAThinnerStagingAsDeclined() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        let thinner = Array(try hypnogram(store, endingAt: -17).prefix(1))
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: thinner)
        guard case .declined = outcome else { return XCTFail("expected .declined, got \(outcome)") }
    }

    /// #259: a future-dated night (a device clock set ahead) does not become the newest-night guard
    /// and hold back every night before it. The guard reads every device's nights alike, so the
    /// future row here is the strap's; the suspected source is a ring with a mis-set clock.
    func testAFutureKeyedNightDoesNotStallTheBackstop() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        try saveNight(store, from: 47, to: 55)        // keyed two days ahead of `now`
        let stranded = try hypnogram(store, endingAt: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded],
                       "last night is still the newest real night, so it alone is held back")
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
    /// night any more, the next night is stored, and the flush offers it as stored (the path a later
    /// night opens, unchanged by decision 57).
    func testTheBackstopOffersTheReportedNightOnceTheNextNightIsStored() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let stored = try storedHypnogram(store)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(9)), [],
                       "the newest night, two hours on, waits")
        try saveNight(store, from: 23, to: 31)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(33)), [stored])
    }
}

// MARK: - Decision 57 (#262): the newest night, once it has clearly stopped growing
//
// Two paths (option B). A newest night that ended near the scheduled wake (at or after the wake time
// less an hour, before noon) goes once its settle margin has passed; one that ended earlier waits 3
// hours. Unless a test passes its own, the wake time is `scheduleWake` (09:00), so the 07:00 fixtures
// below are EARLY ends and exercise the 3-hour path.

/// What the app asked iOS for (decision 57b's margin refresh).
private final class MarginRecorder: BGTaskScheduling {
    private(set) var submitted: BGTaskRequest?
    func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool { true }
    func cancel(taskRequestWithIdentifier identifier: String) {}
    func submit(_ taskRequest: BGTaskRequest) throws { submitted = taskRequest }
}

extension StrapNightHealthTests {
    private var buffer: TimeInterval { LocalStore.strapNewestNightHealthBuffer }

    func testTheNewestNightBufferIsThreeHours() {
        XCTAssertEqual(LocalStore.strapNewestNightHealthBuffer, 3 * 3600, "Juan's choice (57a); don't shorten it without asking")
    }

    /// An early end (07:00, the wake time 09:00), 2:59:59 on, with no later night: its margin has long
    /// passed, and it is still not offered.
    func testAnEarlyEndingNewestNightIsNotOfferedTwoFiftyNineFiftyNineAfterItsEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        let now = hour(7).addingTimeInterval(3 * 3600 - 1)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: now), [])
    }

    /// An early end, 3:00:01 on, with no later night: offered, once, ready to write; mirrored, never again.
    func testAnEarlyEndingNewestNightIsOfferedOnceThreeHoursAndASecondAfterItsEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        let now = hour(7).addingTimeInterval(3 * 3600 + 1)
        let tonight = try hypnogram(store, endingAt: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [tonight])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: now), [tonight])
        XCTAssertEqual(HelioConnection.strapNights([tonight], store: store, timeline: timeline, now: now), [tonight],
                       "a night the sync carries is not offered twice")
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: tonight.map(\.end).max(), now: now, finalized: false))
        try recordMirror(tonight, store: store)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [], "mirrored: not offered again")
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: now.addingTimeInterval(86_400)), [])
    }

    /// An early end: the buffer runs from the later of the row's end and its hypnogram's last segment.
    func testAnEarlyEndingNewestNightsBufferRunsFromItsLatestEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(3), stage: .asleepCore),
                        SleepSegment(start: hour(3), end: hour(7.5), stage: .asleepDeep)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  extras: extras, device: timeline), .inserted)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7.5).addingTimeInterval(buffer - 1)), [])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7.5).addingTimeInterval(buffer + 1)), [segments])
    }

    // The newest night keeps every other rule of the backstop, 3:00:01 on.

    func testTheNewestNightIsNotOfferedWithAMirrorRecord() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        let row = try XCTUnwrap(try rows(store).first)
        store.setMirroredNight(night: row.night, signature: "written", spanStart: row.inBedStart, spanEnd: row.inBedEnd)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    func testTheNewestNightIsNotOfferedWhenEdited() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        try XCTUnwrap(try rows(store).first).isManuallyEdited = true
        try store.context.save()
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    /// The ring went to bed with it (the switch to the strap came after): the ring's, never the strap's.
    func testTheNewestNightIsNotOfferedWhenTheRingOwnsIt() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(7.5))]))
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7, device: .ringConn)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    func testTheNewestNightIsNotOfferedWithoutAHypnogram() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  device: timeline), .inserted)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    func testTheNewestNightIsNotOfferedOutsideTheLookback() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -24 * 8 - 1, to: -24 * 8 + 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    /// An empty ownership log (a ring-only install): nothing, however long ago the night ended.
    func testRingOnlyTheNewestNightIsNeverOffered() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7, device: .ringConn)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
        XCTAssertNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.1)))
    }

    /// A later night exists: the older night is offered as before, at any time; only the newest waits.
    func testWithALaterNightTheOlderNightIsOfferedAsBefore() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let stranded = try hypnogram(store, endingAt: -17)
        let tonight = try hypnogram(store, endingAt: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7.5)), [stranded])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer - 1)), [stranded])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [stranded, tonight])
    }

    /// #262's shape with an EARLY end (07:00, the wake time 09:00): a wake stores the night 13 minutes
    /// after it ended, then the strap stops re-delivering it, so no sync carries it again. Nothing
    /// offers it for 3 hours, and the first flush after that offers it as stored, past every bail of the
    /// writer to its write.
    func testAnEarlyEndingNightReachesTheFlushThreeHoursOnWithoutAReDelivery() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let stored = try storedHypnogram(store)
        let quiet = try sync(nil, at: hour(7.25), store: store)
        XCTAssertEqual(quiet.nights.count, 0, "the strap no longer re-delivers it")
        for t in [hour(7.25), hour(8), hour(10).addingTimeInterval(-1)] {
            XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: t), [], "at \(t)")
        }
        let later = try sync(nil, at: hour(10).addingTimeInterval(1), store: store)
        let input = HelioConnection.strapNights(later.nights.map(\.segments), store: store, timeline: timeline, now: clock)
        XCTAssertEqual(input, [stored])
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: stored)
        XCTAssertFalse(isUnchanged(outcome), "the writer gets past every bail to its write")
        try recordMirror(stored, store: store)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(11)), [])
    }

    /// Decision 57b: the app opened two minutes after a background wake stored the night. Its sync no
    /// longer carries the night, and before 57b its flush's verdict was nil, which cleared the wake's
    /// margin refresh; the app's `schedule()` on leaving the front then replaced it for good. Now the
    /// flush asks for the same refresh, and it survives the app leaving the front.
    func testAForegroundSyncThatNoLongerCarriesTheNightReArmsItsMarginRefresh() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let first = try firstSync(store)
        let marginEnd = hour(7).addingTimeInterval(SleepHealthGate.settleMargin)
        XCTAssertEqual(HelioConnection.nightRefreshAim(result: first, timeline: timeline, store: store,
                                                       flushStartedAt: clock, now: clock), marginEnd)

        let opened = try sync(nil, at: hour(7.25), store: store)
        XCTAssertEqual(opened.nights.count, 0)
        XCTAssertNil(StrapNightRefresh.aim(nights: opened.nights, focusEndedAt: nil, flushStartedAt: clock, afterWokeUp: false),
                     "the sync's own nights alone ask for nothing")
        let aim = HelioConnection.nightRefreshAim(result: opened, timeline: timeline, store: store, flushStartedAt: clock, now: clock)
        XCTAssertEqual(aim, marginEnd)

        let suite = "StrapNightHealthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = MarginRecorder()
        let now = clock
        let scheduler = BackgroundRefreshScheduler(scheduler: recorder, now: { now }, window: { _ in nil })
        StrapNightRefresh.record(aim, scheduler: scheduler, defaults: defaults)
        XCTAssertEqual(recorder.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertTrue(recorder.submitted is BGAppRefreshTaskRequest)
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, marginEnd)
        scheduler.schedule()
        XCTAssertNotEqual(recorder.submitted?.earliestBeginDate, marginEnd, "the app leaving the front replaced it")
        XCTAssertTrue(StrapNightRefresh.resubmit(scheduler, strapChosen: true, now: now, defaults: defaults))
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, marginEnd, "and it is back")
    }

    /// 57b asks for nothing once the stored night has settled (it then waits for 57a's buffer, on any
    /// flush), nor for a night that isn't the strap's to write.
    func testTheStoredNightAsksForNoRefreshOnceSettledOrNotTheStrapsToWrite() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let settled = try sync(nil, at: hour(7.5), store: store)
        XCTAssertNil(HelioConnection.nightRefreshAim(result: settled, timeline: timeline, store: store, flushStartedAt: clock, now: clock))
        XCTAssertNotNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.25)))

        let row = try XCTUnwrap(try rows(store).first)
        row.isManuallyEdited = true
        try store.context.save()
        XCTAssertNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.25)), "edited")
        row.isManuallyEdited = false
        try store.context.save()
        store.setMirroredNight(night: row.night, signature: "written", spanStart: row.inBedStart, spanEnd: row.inBedEnd)
        XCTAssertNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.25)), "mirrored")
    }
}

// MARK: - Review-snh: a held night must still be the stored row when the sync ends

/// Sleep A, 23:00–02:00 (180 min asleep), stored by a sync shortly after a mid-night wake.
private let sleepA: [(Double, Double, UInt8)] = [(-1, 0.5, light), (0.5, 1, deep), (1, 2, light)]
/// A re-delivered: five minutes wider each side and 15 asleep minutes fewer, so the merge keeps A.
private let sleepAAgain: [(Double, Double, UInt8)] = [
    (-1 - 5.0 / 60, -1, awake), (-1, 0.5, light), (0.5, 0.75, awake), (0.75, 1, deep), (1, 2, light), (2, 2 + 5.0 / 60, awake),
]
/// Sleep B, 03:30–07:00 (210 min asleep): 85 minutes after A, so 28f keeps it apart; it ends in the
/// same key's wake window and is fuller, so it replaces A's row in place.
private let sleepB: [(Double, Double, UInt8)] = [(3.5, 5, light), (5, 6, rem), (6, 7, light)]

extension StrapNightHealthTests {
    /// One strap sync at `now` delivering each of `sessions` as its own session record.
    private func syncSessions(_ sessions: [[(Double, Double, UInt8)]], at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let device = makeStrap(sessions[0])
        device.fetchData[.sleepSession] = (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(session))
        let transport = Transport(device: device)
        let keys = Keys()
        let helio = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                 sink: HelioStoreSink(store: store), findState: HelioFindState(),
                                 clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = helio
        helio.start()
        transport.drain()
        let result = try XCTUnwrap(helio.lastSyncResult)
        XCTAssertEqual(result.interrupted, false)
        return result
    }

    /// Runs `body` with local times in a fixed zone (New York), and clears the mirror records it may leave.
    private func inFixedZone(_ body: () async throws -> Void) async rethrows {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let nights = (-2...2).map { hour(Double($0) * 24) }
        nights.forEach(clearMirror)
        defer {
            nights.forEach(clearMirror)
            NSTimeZone.default = saved
        }
        try await body()
    }

    private func window(_ segments: [SleepSegment]) -> DateInterval? {
        guard let start = segments.map(\.start).min(), let end = segments.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// A was stored at 02:15, inside the margin. The morning sync carries A again (kept as thinner) and B.
    private func storeAThenSyncAAgainAndB(at now: Date, store: LocalStore) throws -> HelioSyncResult {
        let first = try syncSessions([sleepA], at: hour(2.25), store: store)
        XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))], "A stored, held by the margin")
        let morning = try syncSessions([sleepAAgain, sleepB], at: now, store: store)
        let rows = try rows(store)
        XCTAssertEqual(rows.count, 1, "one row for the key")
        XCTAssertEqual(rows.first?.inBedStart, hour(3.5), "B replaced A's row in place")
        XCTAssertEqual(rows.first?.inBedEnd, hour(7))
        return morning
    }

    /// Review-snh test 1: the sync carrying A again and B hands the flush B, and no night that isn't a
    /// current stored row's (the stale A, which B replaced in this same sync). This also pins the
    /// re-flush churn: `ContentView.flushHealth` re-flushes `lastSyncResult.nights` until the next sync,
    /// and `[B, staleA]` there would write B, delete A, write A and delete B on every such flush.
    func testASyncWhoseLaterSleepReplacedTheKeptNightHandsOverOnlyTheStoredRow() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndB(at: hour(7.5), store: store)
            let current = try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }
            XCTAssertTrue(morning.nights.contains { $0.window == DateInterval(start: hour(3.5), end: hour(7)) }, "B is handed over")
            XCTAssertEqual(morning.nights.filter { !current.contains($0.window) }.map(\.window), [], "no stale A")
        }
    }

    /// Review-snh test 2: at 07:10 B hasn't settled. Nothing for the key is ready to write, so nothing
    /// reaches the writer's write step and no mirror record is left. A flush at 07:30 (ContentView's,
    /// over the last sync's result) offers exactly B, ready.
    func testBeforeTheReplacingSleepSettlesNothingIsWrittenForTheKey() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndB(at: hour(7 + 10.0 / 60), store: store)
            let key = try XCTUnwrap(try rows(store).first).night

            let input = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: clock)
            let ready = input.filter { SleepHealthGate.isReadyToWrite(latestSegmentEnd: $0.map(\.end).max(), now: clock, finalized: false) }
            XCTAssertEqual(ready.compactMap(window), [], "no night for the key is ready at 07:10")
            for night in ready {
                let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: night)
                XCTAssertTrue(isUnchanged(outcome), "nothing reaches the write step")
            }
            let flush = await HelioConnection.flushStrap(HealthKitWriter(), store: store, timeline: timeline,
                                                         nights: morning.nights.map(\.segments), now: clock)
            XCTAssertEqual(flush.sleepSegments, 0)
            XCTAssertNil(store.mirroredNight(night: key), "no mirror record")

            let later = hour(7.5)
            let laterInput = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: later)
            XCTAssertEqual(laterInput, [try storedHypnogram(store)], "exactly B, as stored")
            XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: hour(7), now: later, finalized: false))
        }
    }

    /// Review-snh test 3: both settled at 07:30. The flush input is exactly B's stored hypnogram: one
    /// night for the key.
    func testWhenBothHaveSettledTheFlushInputIsTheReplacingSleepAlone() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndB(at: hour(7.5), store: store)
            let input = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: clock)
            let stored = try storedHypnogram(store)
            XCTAssertEqual(window(stored), DateInterval(start: hour(3.5), end: hour(7)))
            XCTAssertEqual(input, [stored])
        }
    }
}

// MARK: - Decision 57 option B (#262): the fast path near the scheduled wake, and what stays on 3 hours

/// Juan's night of 2026-10-03, synthetic stages: 00:24–09:08.
private let morningNight: [(Double, Double, UInt8)] = [(0.4, 3, light), (3, 5, deep), (5, 7, rem), (7, 9 + 8.0 / 60, light)]

extension StrapNightHealthTests {
    private var margin: TimeInterval { SleepHealthGate.settleMargin }

    /// Round 3's risk, through the production path: a sync at 02:15, after a mid-night wake, stores
    /// 23:00–02:00, and 57b aims the margin refresh at 02:20. That refresh's sync carries no night. With
    /// any usual wake time, 02:00 is an early end, so it is NOT offered then (back to bed at 02:30, the
    /// morning's longer sleep would otherwise be kept out for good by "the written night stands"). The
    /// shipped paths are unchanged: a real re-delivery (50a) hands it over as on master, and so does
    /// the 3-hour backstop.
    func testAMidNightAwakeningIsNotWrittenByTheMarginRefresh() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let first = try syncSessions([sleepA], at: hour(2.25), store: store)
            XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))], "stored, held by the margin")
            let marginEnd = hour(2).addingTimeInterval(margin)
            XCTAssertEqual(HelioConnection.nightRefreshAim(result: first, timeline: timeline, store: store, flushStartedAt: clock, now: clock),
                           marginEnd, "57b aims the refresh at 02:20")
            let storedA = try storedHypnogram(store)

            let retry = try sync(nil, at: marginEnd.addingTimeInterval(1), store: store)
            XCTAssertEqual(retry.nights.count, 0)
            for wake in [SleepScheduleDefaults.defaultWakeMinutes, 7 * 60, Self.scheduleWake] {
                XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: clock, wakeMinutes: wake), [], "wake \(wake)")
            }
            XCTAssertEqual(HelioConnection.strapNights(retry.nights.map(\.segments), store: store, timeline: timeline, now: clock), [],
                           "the flush of the 02:20 refresh offers nothing")
            XCTAssertNil(HelioConnection.nightRefreshAim(result: retry, timeline: timeline, store: store, flushStartedAt: clock, now: clock))

            // As on master: a real re-delivery, settled, is handed over by 50a.
            let reDelivered = try syncSessions([sleepAAgain], at: hour(2.5), store: store)
            XCTAssertEqual(reDelivered.nights.map(\.segments), [storedA])

            // And the 3-hour backstop, unchanged: 05:00 on.
            let wake = SleepScheduleDefaults.defaultWakeMinutes
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(5).addingTimeInterval(-1), wakeMinutes: wake), [])
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(5).addingTimeInterval(1), wakeMinutes: wake), [storedA])
        }
    }

    /// Juan's case on the fast path: a background wake stores 00:24–09:08 at 09:11 and aims the margin
    /// refresh at 09:28; the app opened at 09:13 syncs no night (the strap stopped re-delivering). With
    /// the wake time 09:00 (09:08 is after 08:00), the first flush at 09:28 offers it as stored, ready
    /// to write, past every bail of the writer. Mirrored, never again.
    func testANightEndingNearTheScheduledWakeIsOfferedWhenItsMarginCloses() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let end = hour(9 + 8.0 / 60)
        let first = try sync(morningNight, at: hour(9 + 11.0 / 60), store: store)
        XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(0.4), end: end)])
        let marginEnd = end.addingTimeInterval(margin)
        XCTAssertEqual(HelioConnection.nightRefreshAim(result: first, timeline: timeline, store: store, flushStartedAt: clock, now: clock), marginEnd)
        let stored = try storedHypnogram(store)

        let opened = try sync(nil, at: hour(9 + 13.0 / 60), store: store)
        XCTAssertEqual(opened.nights.count, 0)
        XCTAssertEqual(HelioConnection.nightRefreshAim(result: opened, timeline: timeline, store: store, flushStartedAt: clock, now: clock), marginEnd)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: marginEnd.addingTimeInterval(-1)), [],
                       "not before its margin closes")
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: marginEnd), [stored], "09:28")
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: marginEnd, wakeMinutes: SleepScheduleDefaults.defaultWakeMinutes),
                       [stored], "and with the schedule never set (06:30)")
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: stored.map(\.end).max(), now: marginEnd, finalized: false))
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: stored)
        XCTAssertFalse(isUnchanged(outcome), "the writer gets past every bail to its write")
        try recordMirror(stored, store: store)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: marginEnd.addingTimeInterval(60)), [])
    }

    /// The fast path's boundary: a 07:00 end at 07:20 (its margin just closed) is offered when 07:00 is
    /// at or after the wake time less an hour, and not otherwise; before its margin closes, never.
    func testTheFastPathFollowsTheScheduledWakeAndItsSlack() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        let tonight = try hypnogram(store, endingAt: 7)
        let closes = hour(7).addingTimeInterval(margin)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: closes, wakeMinutes: 8 * 60), [tonight], "07:00 is exactly 08:00 less an hour")
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: closes, wakeMinutes: 8 * 60 + 1), [], "a minute early")
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: closes, wakeMinutes: SleepScheduleDefaults.defaultWakeMinutes), [tonight])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: closes, wakeMinutes: Self.scheduleWake), [])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: closes.addingTimeInterval(-1),
                                                       wakeMinutes: SleepScheduleDefaults.defaultWakeMinutes), [], "margin not closed")
    }

    /// The time-of-day rule itself: from the wake time less an hour up to noon (28d's wake window).
    func testTheEndNearTheScheduledWakeRule() {
        let wake = SleepScheduleDefaults.defaultWakeMinutes   // 06:30
        XCTAssertFalse(LocalStore.strapNightEndsNearScheduledWake(hour(5.5).addingTimeInterval(-60), wakeMinutes: wake))
        XCTAssertTrue(LocalStore.strapNightEndsNearScheduledWake(hour(5.5), wakeMinutes: wake))
        XCTAssertTrue(LocalStore.strapNightEndsNearScheduledWake(hour(11 + 59.0 / 60), wakeMinutes: wake))
        XCTAssertFalse(LocalStore.strapNightEndsNearScheduledWake(hour(12), wakeMinutes: wake), "noon: past the wake window")
        XCTAssertFalse(LocalStore.strapNightEndsNearScheduledWake(hour(23), wakeMinutes: wake), "a late-evening clock (another zone) is no morning")
        XCTAssertFalse(LocalStore.strapNightEndsNearScheduledWake(hour(2), wakeMinutes: wake))
    }

    /// The fast path keeps every other rule of the backstop: mirrored, edited, the ring's or without a
    /// hypnogram, a night ending near the wake is not offered when its margin closes.
    func testTheFastPathKeepsEveryOtherGuard() throws {
        let wake = SleepScheduleDefaults.defaultWakeMinutes
        let closes = hour(7).addingTimeInterval(margin)
        for guardName in ["mirrored", "edited", "ring", "no hypnogram"] {
            ownership.install(guardName == "ring" ? DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(7.5))]) : .strapOwnsAllTime)
            let store = try makeStore()
            if guardName == "no hypnogram" {
                let segments = [SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
                XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                          inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                          device: timeline), .inserted)
            } else {
                try saveNight(store, from: -1, to: 7, device: guardName == "ring" ? .ringConn : nil)
            }
            let row = try XCTUnwrap(try rows(store).first)
            if guardName == "mirrored" {
                store.setMirroredNight(night: row.night, signature: "written", spanStart: row.inBedStart, spanEnd: row.inBedEnd)
            }
            if guardName == "edited" {
                row.isManuallyEdited = true
                try store.context.save()
            }
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: closes, wakeMinutes: wake), [], guardName)
            clearMirror(row.night)
        }
    }
}
