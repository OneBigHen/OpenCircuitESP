import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The Shortcuts actions (#260, decision 52) end to end against the simulated strap (`FakeZeppDevice`)
// and the app's own `HelioSession`: the buzz's start and stop, the wake alarm's one-slot write and its
// pending apply at the next connection, coexistence with a history sync, and decision 1's gating.
// Every key, id, time and reading is synthetic.

private let wsMidnight: TimeInterval = 1_789_862_400   // 2026-09-20T00:00:00Z
private let wsKeyHex = "00112233445566778899aabbccddeeff"
private let wsStrapPrivateKey = Array(UInt8(0x81)...UInt8(0x98))
private let wsStrapRandom = Array(UInt8(0xf0)...UInt8(0xff))
private let wsServices: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]

private func wsStamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// 60 worn activity minutes from 23:00 (5 steps, HR 55), and 60 temperature minutes at 33.50 °C.
private func wsStrap(withHistory: Bool = false) -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(wsKeyHex)!, privateKey: wsStrapPrivateKey, random: wsStrapRandom,
                                writeLength: 244)
    device.services = wsServices
    // A device-info reply (§5.3), so setup doesn't wait out the step timeout: made-up versions.
    device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
    device.dataPacketLength = 200
    if withHistory {
        let start = wsMidnight - 3600
        device.fetchData = [
            .activity: (wsStamp(start), (0..<60).flatMap { _ in [0x01, 0x08, 5, 55, 0, 0, 0, 0] as [UInt8] }),
            .temperature: (wsStamp(start), (0..<60).flatMap { _ in [0xff, 0x7f, 0x16, 0x0d, 0x5a, 0x5a, 0x5a, 0x5a] as [UInt8] }),
        ]
    }
    return device
}

/// `HelioTransport` over `FakeZeppDevice`; deliveries are queued and handed over by `drain()`, as
/// CoreBluetooth hands them over on a later run-loop turn.
@MainActor
private final class WSTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var maxWriteLength = 244
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []
    private let available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }
    func write(_ write: ZeppWrite) {
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) { inbox.append((characteristic, nil, enabled)) }
    func read(_ characteristic: ZeppCharacteristic) {
        if characteristic == .batteryLevel { inbox.append((characteristic, [64], false)) }
    }

    /// Deliver one queued event; false when nothing was queued.
    @discardableResult
    func step() -> Bool {
        guard !inbox.isEmpty else { return false }
        let (characteristic, bytes, enabled) = inbox.removeFirst()
        if let bytes {
            session?.received(characteristic, bytes)
        } else {
            session?.notificationStateChanged(characteristic, enabled: enabled, failed: false)
        }
        return true
    }

    func drain() {
        var guardCount = 0
        while step(), guardCount < 100_000 { guardCount += 1 }
    }
}

@MainActor
private final class WSKeyStore: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(wsKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

/// The strap's connection as the actions see it. `connectForShortcut` brings up `onConnect`'s session.
@MainActor
private final class WSLink: ShortcutStrapLink {
    var session: HelioSession?
    var endedBusy = false
    private(set) var connects = 0
    var onConnect: (() -> Void)?

    func connectForShortcut() -> Bool {
        connects += 1
        onConnect?()
        return true
    }
}

@MainActor
final class WearableShortcutTests: XCTestCase {
    private let strapID = "5B1E4C2A-0000-4000-8000-0000000000E7"
    private var clock = Date(timeIntervalSince1970: wsMidnight + 12 * 3600)
    private var defaults: UserDefaults!
    private let suite = "test.WearableShortcutTests"
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()

    /// The transport the clock's pause moves along (the current connection's).
    private var transport: WSTransport?
    /// Called on each pause before the strap is moved along (a test's own event, e.g. a link drop).
    private var onPause: (() -> Void)?
    private var pauses = 0

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
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

    /// A session over `device`, wired like `HelioConnection.makeSession` wires it (the applier attached
    /// before `start()`), and started. `settle`: drain until it is set up.
    private func makeSession(_ device: FakeZeppDevice, applier: StrapWakeAlarmApplier, findState: HelioFindState,
                             store: LocalStore? = nil, autoSync: Bool = false, settle: Bool = true,
                             finished: @escaping (HelioSyncResult) -> Void = { _ in }) -> HelioSession {
        let transport = WSTransport(device: device)
        let keys = WSKeyStore()
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: store.map { HelioStoreSink(store: $0) }, findState: findState,
                                   onSyncFinished: { result, _ in finished(result) },
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: autoSync)
        transport.session = session
        self.transport = transport
        applier.attach(to: session)
        session.start()
        if settle { transport.drain() }
        return session
    }

    private func applier() -> StrapWakeAlarmApplier {
        StrapWakeAlarmApplier(store: StrapWakeAlarmStore(defaults: defaults), now: { [unowned self] in self.clock })
    }

    /// The actions over `link`, with the strap chosen and saved, and a 250 ms pause that ticks the
    /// session and delivers what the strap sent.
    private func actions(_ link: WSLink, applier: StrapWakeAlarmApplier, device: ActiveDeviceChoice = .helioStrap,
                         savedStrap: Bool = true, cancelled: @escaping () -> Bool = { false },
                         protectedData: Bool = true) -> WearableShortcuts {
        WearableShortcuts(WearableShortcutEnvironment(
            device: { device },
            savedStrapID: { [strapID] in savedStrap ? strapID : nil },
            strapKey: { .saved },
            strapLink: { link },
            ringSession: { nil },
            applier: applier,
            now: { [unowned self] in self.clock },
            pause: { [unowned self] in
                self.pauses += 1
                self.onPause?()
                self.clock = self.clock.addingTimeInterval(0.25)
                link.session?.tick(now: self.clock)
                self.transport?.drain()
            },
            isCancelled: { cancelled() },
            protectedDataAvailable: { protectedData }))
    }

    private func pairs(_ device: FakeZeppDevice) -> [UInt8] { device.findOpcodes.filter { $0 == 0x03 || $0 == 0x06 } }

    // MARK: the buzz (52a)

    func testTheBuzzSendsStartThenStopBeforeTheActionReturns() async throws {
        let device = wsStrap()
        let link = WSLink()
        link.session = makeSession(device, applier: applier(), findState: HelioFindState())
        let started = clock
        let result = await actions(link, applier: applier()).vibrate(times: 1)
        XCTAssertEqual(result.outcome, "vibrated 1")
        XCTAssertEqual(result.dialog, "Vibrated your Amazfit Helio Strap.")
        XCTAssertEqual(pairs(device), [0x03, 0x06], "the stop was sent before the action returned")
        XCTAssertFalse(device.isBuzzing)
        XCTAssertGreaterThanOrEqual(clock.timeIntervalSince(started), 2 + WearableShortcuts.stopMargin,
                                    "the 2 s buzz, then the margin for the 06 to leave the radio")
        XCTAssertEqual(link.connects, 0, "a ready session is used as it is")
    }

    func testThreeTimesGivesThreeStartStopPairs() async throws {
        let device = wsStrap()
        let link = WSLink()
        link.session = makeSession(device, applier: applier(), findState: HelioFindState())
        let result = await actions(link, applier: applier()).vibrate(times: 3)
        XCTAssertEqual(result.outcome, "vibrated 3")
        XCTAssertEqual(result.dialog, "Vibrated your Amazfit Helio Strap 3 times.")
        XCTAssertEqual(pairs(device), [0x03, 0x06, 0x03, 0x06, 0x03, 0x06])
        XCTAssertFalse(device.isBuzzing)
        let clamped = await actions(link, applier: applier()).vibrate(times: 9)
        XCTAssertEqual(clamped.outcome, "vibrated 5", "Times is 1 to 5")
    }

    func testALinkDropMidBuzzLeavesTheStopOwedToTheNextConnection() async throws {
        let device = wsStrap()
        let findState = HelioFindState()
        let link = WSLink()
        let first = makeSession(device, applier: applier(), findState: findState)
        link.session = first
        onPause = { [unowned self] in
            guard self.pauses == 2 else { return }
            first.linkLost()   // the strap walks out of range a moment into the buzz
            link.session = nil
        }
        let result = await actions(link, applier: applier()).vibrate(times: 3)
        onPause = nil
        XCTAssertEqual(result.outcome, "link dropped mid-buzz")
        XCTAssertTrue(result.dialog.contains("sends the stop as soon as it reconnects"), result.dialog)
        XCTAssertTrue(device.isBuzzing, "the stop couldn't go out")
        XCTAssertEqual(pairs(device), [0x03], "no second buzz after the drop")

        // Decision 18's owed stop, unchanged: the next authenticated connection sends it first.
        let next = makeSession(device, applier: applier(), findState: findState)
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(Array(device.findOpcodes.suffix(2)), [0x06, 0x01], "the owed stop, then the capabilities request")
        XCTAssertEqual(next.findPhase, .stopped(.linkLost))
    }

    func testABuzzBringsTheSavedStrapUpThenActs() async throws {
        let device = wsStrap()
        let link = WSLink()
        link.onConnect = { [unowned self] in
            link.session = self.makeSession(device, applier: self.applier(), findState: HelioFindState(), settle: false)
        }
        let result = await actions(link, applier: applier()).vibrate(times: 1)
        XCTAssertEqual(link.connects, 1)
        XCTAssertEqual(result.outcome, "vibrated 1")
        XCTAssertEqual(pairs(device), [0x03, 0x06])
    }

    func testAStrapThatNeverComesUpIsReportedAfterTwentySeconds() async throws {
        let link = WSLink()
        let started = clock
        let result = await actions(link, applier: applier()).vibrate(times: 1)
        XCTAssertEqual(link.connects, 1)
        XCTAssertEqual(WearableShortcuts.reachTimeout, 15, "review-261 Q4: reach + the alarm write stay under 30 s")
        XCTAssertEqual(result.outcome, "unreachable: timed out")
        XCTAssertEqual(clock.timeIntervalSince(started), WearableShortcuts.reachTimeout, accuracy: 0.3)
        XCTAssertTrue(result.dialog.hasPrefix("Couldn't reach your Amazfit Helio Strap"), result.dialog)
    }

    func testABusyStrapIsNotReconnectedByAnAutomation() async throws {
        let link = WSLink()
        link.endedBusy = true
        let result = await actions(link, applier: applier()).vibrate(times: 1)
        XCTAssertEqual(link.connects, 0, "decision 7: no retry loop, even from a Shortcut")
        XCTAssertEqual(result.outcome, "unreachable: busy")
    }

    // MARK: the wake alarm (52b, 52c)

    func testARequestSavedWhileAwayIsWrittenAtTheNextConnectionAfterTheClockAndTheList() throws {
        let applier = applier()
        applier.store.pending = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 6, minute: 30, days: .once)),
                                                      strapID: strapID, madeAt: clock)
        let device = wsStrap()
        device.alarmRecords = [0: [0x04, 0x00, 0x09, 0x00, 0x60, 0x00, 0x00, 0x00, 0x01, 0x00]]   // the person's own
        _ = makeSession(device, applier: applier, findState: HelioFindState())

        XCTAssertEqual(device.timeSetCount, 1)
        XCTAssertEqual(device.alarmCommands, [
            [0x09],                                                                     // setup's read
            [0x03, 0x01, 0x04, 0x01, 0x06, 0x1e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],   // ONE slot: the lowest free
            [0x09],                                                                     // the re-read
        ])
        let timeIndex = try XCTUnwrap(device.receivedEndpoints.firstIndex(of: ZeppEndpoint.time))
        let alarmIndices = device.receivedEndpoints.indices.filter { device.receivedEndpoints[$0] == ZeppEndpoint.alarms }
        XCTAssertLessThan(timeIndex, alarmIndices[0], "the clock is set before the list is read")
        XCTAssertNil(applier.store.pending, "applied")
        XCTAssertEqual(applier.store.managed,
                       ManagedStrapAlarm(strapID: strapID, alarm: ZeppAlarm(slot: 1, hour: 6, minute: 30, days: .once)))
        XCTAssertEqual(device.alarmRecords[0], [0x04, 0x00, 0x09, 0x00, 0x60, 0x00, 0x00, 0x00, 0x01, 0x00], "untouched")
    }

    func testAWriteTheStrapRefusesKeepsTheRequestPendingForTheNextConnection() throws {
        let applier = applier()
        let request = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 7, minute: 0, days: .weekdays)), strapID: strapID, madeAt: clock)
        applier.store.pending = request
        let device = wsStrap()
        device.alarmAckStatus = 0x02
        _ = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertEqual(device.alarmCommands.count, 2, "the read, one write, and no blind retry")
        XCTAssertEqual(applier.outcome(for: request.id), .writeFailed)
        XCTAssertEqual(applier.store.pending, request, "kept")
        XCTAssertNil(applier.store.managed)

        device.alarmAckStatus = 0x01
        _ = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertNil(applier.store.pending)
        XCTAssertEqual(applier.store.managed?.slot, 0)
    }

    func testAnExpiredOnceRequestIsDroppedAtTheNextConnectionAndNothingIsSent() throws {
        let applier = applier()
        // Asked for 06:30 once at 12:00; the strap only comes back the morning after next, at 08:00.
        let request = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 6, minute: 30, days: .once)), strapID: strapID, madeAt: clock)
        applier.store.pending = request
        clock = clock.addingTimeInterval(44 * 3600)
        let device = wsStrap()
        _ = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertEqual(device.alarmCommands, [[0x09]], "decision 52e: the strap is untouched")
        XCTAssertNil(applier.store.pending, "dropped")
        XCTAssertNil(applier.store.managed)
        XCTAssertEqual(applier.outcome(for: request.id), .noWrite(.expired))
    }

    func testAPersonsOwnAlarmAtTheRequestedTimeClearsTheManagedSlot() async throws {
        let applier = applier()
        let device = wsStrap()
        device.alarmRecords = [
            0: [0x04, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00],   // ours: 07:00 once
            3: [0x04, 0x03, 0x06, 0x1e, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00],   // theirs: 06:30 once
        ]
        applier.store.managed = ManagedStrapAlarm(strapID: strapID, alarm: ZeppAlarm(slot: 0, hour: 7, minute: 0))
        let link = WSLink()
        link.session = makeSession(device, applier: applier, findState: HelioFindState())
        let result = await actions(link, applier: applier).setWakeAlarm(hour: 6, minute: 30, days: .once)
        XCTAssertEqual(result.outcome, "already on the strap; managed slot cleared")
        XCTAssertEqual(device.alarmCommands.filter { $0.first == 0x03 || $0.first == 0x05 }, [[0x05, 0x01, 0x00]],
                       "decision 52f: only the managed slot, deleted")
        XCTAssertEqual(device.alarmRecords[3], [0x04, 0x03, 0x06, 0x1e, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00], "theirs untouched")
        XCTAssertNil(applier.store.managed)
        XCTAssertNil(applier.store.pending)
    }

    func testNothingPendingWritesNothingAtConnection() throws {
        let device = wsStrap()
        _ = makeSession(device, applier: applier(), findState: HelioFindState())
        XCTAssertEqual(device.alarmCommands, [[0x09]], "§15.1: setup only reads")
    }

    func testSetWakeAlarmOnAReadyStrapSetsItNowAndASecondRunChangesNothing() async throws {
        let applier = applier()
        let device = wsStrap()
        let link = WSLink()
        link.session = makeSession(device, applier: applier, findState: HelioFindState())
        let result = await actions(link, applier: applier).setWakeAlarm(hour: 6, minute: 45, days: .once)
        XCTAssertEqual(result.outcome, "set")
        XCTAssertTrue(result.dialog.hasPrefix("Set a wake alarm on your Amazfit Helio Strap"), result.dialog)
        XCTAssertEqual(device.alarmCommands.filter { $0.first == 0x03 }.count, 1)
        XCTAssertEqual(applier.store.managed?.hour, 6)

        let again = await actions(link, applier: applier).setWakeAlarm(hour: 6, minute: 45, days: .once)
        XCTAssertEqual(again.outcome, "already set")
        XCTAssertEqual(device.alarmCommands.filter { $0.first == 0x03 }.count, 1, "no write")

        // A new time rewrites the same slot; then Clear deletes it.
        let moved = await actions(link, applier: applier).setWakeAlarm(hour: 7, minute: 15, days: .weekdays)
        XCTAssertEqual(moved.outcome, "set")
        XCTAssertEqual(device.alarmCommands.filter { $0.first == 0x03 }.map { $0[3] }, [0, 0], "slot 0 both times")
        let cleared = await actions(link, applier: applier).clearWakeAlarm()
        XCTAssertEqual(cleared.outcome, "cleared")
        XCTAssertEqual(device.alarmCommands.filter { $0.first == 0x05 }, [[0x05, 0x01, 0x00]])
        XCTAssertNil(applier.store.managed)
        XCTAssertTrue(device.alarmRecords.isEmpty)
    }

    func testSetWakeAlarmWithTheStrapAwayIsSavedFirstAndAppliedAtTheNextConnection() async throws {
        let applier = applier()
        let link = WSLink()   // connect is armed, nothing answers
        let result = await actions(link, applier: applier).setWakeAlarm(hour: 6, minute: 0, days: .everyDay)
        XCTAssertEqual(result.outcome, "pending: timed out")
        XCTAssertTrue(result.dialog.hasPrefix("Saved."), result.dialog)
        XCTAssertNotNil(applier.store.pending)

        let device = wsStrap()
        _ = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertNil(applier.store.pending)
        XCTAssertEqual(applier.store.managed?.daysRaw, ZeppAlarmDays.everyDay.rawValue)
    }

    func testClearWithNoManagedAlarmTouchesNothingAndDoesNotConnect() async throws {
        let applier = applier()
        let link = WSLink()
        let result = await actions(link, applier: applier).clearWakeAlarm()
        XCTAssertEqual(result.outcome, "nothing to clear")
        XCTAssertEqual(link.connects, 0)
        XCTAssertNil(applier.store.pending)
    }

    // MARK: a sync in progress (#233 coalescing: act through the session that's there)

    /// Review-261 F1 (its P2's shape): one notification at a time, the buzz's start, the alarm's add and
    /// the buzz's stop all go out inside the first fetch round, before its ack.
    func testABuzzAndAnAlarmWriteInsideTheFirstRoundLeaveTheSyncWhole() throws {
        // The control: the same strap's sync with nothing else on the link.
        let controlStore = try makeStore()
        let control = makeSession(wsStrap(withHistory: true), applier: applier(), findState: HelioFindState(),
                                  store: controlStore, autoSync: true)
        let expected = try XCTUnwrap(control.lastSyncResult)
        XCTAssertGreaterThan(expected.roundsStored, 0)
        let expectedRows = try controlStore.context.fetchCount(FetchDescriptor<StoredSample>())

        let store = try makeStore()
        let applier = applier()
        let device = wsStrap(withHistory: true)
        let session = makeSession(device, applier: applier, findState: HelioFindState(), store: store, autoSync: true,
                                  settle: false)
        let wire = try XCTUnwrap(transport)
        var steps = 0
        while device.fetchStarts.isEmpty, steps < 10_000, wire.step() { steps += 1 }
        wire.step()   // the start reply: the first round's data is now flowing
        XCTAssertEqual(session.phase, .syncing)
        XCTAssertTrue(device.fetchAcks.isEmpty, "inside the first round")

        XCTAssertNil(session.buzz(), "buzz start")
        applier.store.pending = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 6, minute: 30, days: .once)),
                                                      strapID: strapID, madeAt: clock)
        XCTAssertEqual(applier.applyPending(on: session), .writing, "alarm add")
        clock = clock.addingTimeInterval(2.25)
        session.tick(now: clock)   // the session's own tick sends the buzz's stop
        XCTAssertEqual(pairs(device), [0x03, 0x06])
        XCTAssertEqual(device.alarmCommands.filter { $0.first == 0x03 }.count, 1)
        XCTAssertTrue(device.fetchAcks.isEmpty, "all three before the first round's ack")
        XCTAssertEqual(session.phase, .syncing)

        wire.drain()
        XCTAssertEqual(session.syncsFinished, 1)
        let result = try XCTUnwrap(session.lastSyncResult)
        XCTAssertFalse(result.interrupted)
        XCTAssertEqual(result.roundsFailed, 0)
        XCTAssertEqual(result.roundsStored, expected.roundsStored, "every round the control stored")
        XCTAssertEqual(result.typesEmpty, expected.typesEmpty)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<StoredSample>()), expectedRows, "the same rows")
        XCTAssertEqual(Set(session.fetchAcksSent), [0x09], "every round acked keep")
        XCTAssertEqual(device.failures, [])
        XCTAssertEqual(applier.store.managed?.slot, 0, "the alarm write was confirmed")
    }

    // MARK: review-261 findings

    /// B1 (P9): the person deletes the managed alarm on the Alarms screen and adds their own identical
    /// one, which lands in the same slot. It is theirs: never claimed, rewritten or deleted.
    func testP9TheReusedManagedSlotHoldingThePersonsOwnAlarmIsNeverClaimed() async throws {
        let applier = applier()
        let device = wsStrap()
        let link = WSLink()
        let session = makeSession(device, applier: applier, findState: HelioFindState())
        link.session = session
        let set = await actions(link, applier: applier).setWakeAlarm(hour: 7, minute: 0, days: .once)
        XCTAssertEqual(set.outcome, "set")
        XCTAssertEqual(applier.store.managed?.slot, 0)

        XCTAssertNil(session.deleteAlarm(slot: 0))
        transport?.drain()
        XCTAssertNil(applier.store.managed, "a write OpenCircuit didn't make to the managed slot forgets the record")
        XCTAssertNil(session.addAlarm(hour: 7, minute: 0, days: .once))
        transport?.drain()
        let theirs = try XCTUnwrap(device.alarmRecords[0], "theirs took the lowest free slot, 0")

        let commands = device.alarmCommands.count
        let clear = await actions(link, applier: applier).clearWakeAlarm()
        XCTAssertEqual(clear.outcome, "nothing to clear")
        XCTAssertEqual(device.alarmCommands.count, commands, "nothing deleted")

        let moved = await actions(link, applier: applier).setWakeAlarm(hour: 6, minute: 0, days: .once)
        XCTAssertEqual(moved.outcome, "set")
        XCTAssertEqual(applier.store.managed?.slot, 1, "a NEW slot")
        XCTAssertEqual(device.alarmRecords[0], theirs, "theirs untouched")
    }

    /// S2 (P10): the link drops between the write's ack and the re-read. The strap holds the alarm; the
    /// next connection adopts it instead of leaving an unmanaged every-day alarm behind.
    func testP10ALinkDropBeforeTheReReadLeavesACandidateTheNextConnectionAdopts() async throws {
        let applier = applier()
        applier.store.pending = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 7, minute: 0, days: .everyDay)),
                                                      strapID: strapID, madeAt: clock)
        let device = wsStrap()
        let first = makeSession(device, applier: applier, findState: HelioFindState(), settle: false)
        let wire = try XCTUnwrap(transport)
        var steps = 0
        while device.alarmCommands.count < 3, steps < 10_000, wire.step() { steps += 1 }   // read, write, re-read sent
        XCTAssertEqual(device.alarmCommands.count, 3)
        first.linkLost()   // out of range before the list comes back
        XCTAssertEqual(device.alarmRecords.keys.sorted(), [0], "the strap applied it")
        XCTAssertNil(applier.store.managed)
        XCTAssertEqual(applier.store.candidate,
                       ManagedStrapAlarm(strapID: strapID, alarm: ZeppAlarm(slot: 0, hour: 7, minute: 0, days: .everyDay)))
        XCTAssertNotNil(applier.store.pending, "kept")

        let before = device.alarmCommands.count
        let link = WSLink()
        link.session = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertEqual(Array(device.alarmCommands[before...]), [[0x09]], "adopted at the list read: nothing written again")
        XCTAssertEqual(applier.store.managed?.slot, 0)
        XCTAssertNil(applier.store.candidate)
        XCTAssertNil(applier.store.pending)

        let moved = await actions(link, applier: applier).setWakeAlarm(hour: 6, minute: 0, days: .everyDay)
        XCTAssertEqual(moved.outcome, "set")
        XCTAssertEqual(device.alarmRecords.keys.sorted(), [0], "moved, not a second every-day alarm")
        XCTAssertEqual(device.alarmRecords[0]?[2], 6)
    }

    /// S2 (P13): another central changes another slot mid-write, so the re-read can't confirm the
    /// others unchanged. The candidate is adopted at the next list read.
    func testP13AnotherCentralChangingAnotherSlotMidWriteLeavesACandidate() throws {
        let applier = applier()
        let request = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 7, minute: 0, days: .once)), strapID: strapID,
                                            madeAt: clock)
        applier.store.pending = request
        let device = wsStrap()
        let session = makeSession(device, applier: applier, findState: HelioFindState(), settle: false)
        let wire = try XCTUnwrap(transport)
        var steps = 0
        while device.alarmCommands.count < 2, steps < 10_000, wire.step() { steps += 1 }   // the write is out
        XCTAssertEqual(session.phase, .settingUp)
        device.alarmRecords[5] = [0x04, 0x05, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]   // another central: 09:00
        wire.drain()
        XCTAssertEqual(applier.outcome(for: request.id), .notConfirmed)
        XCTAssertNil(applier.store.managed)
        XCTAssertEqual(applier.store.candidate?.slot, 0)

        _ = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertEqual(applier.store.managed, ManagedStrapAlarm(strapID: strapID, alarm: ZeppAlarm(slot: 0, hour: 7, minute: 0)))
        XCTAssertNil(applier.store.candidate)
        XCTAssertNil(applier.store.pending)
        XCTAssertEqual(device.alarmRecords[5]?[2], 9, "the other central's alarm untouched")
    }

    /// S2: a candidate whose slot no longer holds exactly what was written is dropped, never adopted;
    /// and B1's rule applies to it: the person's own write to its slot drops it.
    func testACandidateIsDroppedWhenItsSlotChangedOrThePersonWritesIt() throws {
        let applier = applier()
        func unconfirmedWrite(_ device: FakeZeppDevice) throws -> HelioSession {
            applier.store.pending = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 7, minute: 0, days: .once)),
                                                          strapID: strapID, madeAt: clock)
            let session = makeSession(device, applier: applier, findState: HelioFindState(), settle: false)
            let wire = try XCTUnwrap(transport)
            var steps = 0
            while device.alarmCommands.count < 2, steps < 10_000, wire.step() { steps += 1 }
            device.alarmRecords[5] = [0x04, 0x05, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
            wire.drain()
            XCTAssertEqual(applier.store.candidate?.slot, 0)
            return session
        }

        // Its slot changed before the next connection (someone edited it in Zepp): dropped, and the
        // pending 07:00 goes into a free slot instead.
        let changed = wsStrap()
        _ = try unconfirmedWrite(changed)
        changed.alarmRecords[0] = [0x04, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
        _ = makeSession(changed, applier: applier, findState: HelioFindState())
        XCTAssertNil(applier.store.candidate)
        XCTAssertEqual(applier.store.managed?.slot, 1)
        XCTAssertEqual(changed.alarmRecords[0]?[2], 8, "the edited slot untouched")

        // The person deletes its slot on the Alarms screen, on the same connection.
        applier.store.managed = nil
        let edited = wsStrap()
        let session = try unconfirmedWrite(edited)
        XCTAssertNil(session.deleteAlarm(slot: 0))
        transport?.drain()
        XCTAssertNil(applier.store.candidate)
    }

    /// S1 (P7): a Clear while the first Set's write is still out follows the write with the delete,
    /// instead of saying "cancelled" while the alarm lands.
    func testP7AClearDuringAnInFlightFirstSetDeletesItAfterTheWrite() async throws {
        let applier = applier()
        let request = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 7, minute: 0, days: .everyDay)), strapID: strapID,
                                            madeAt: clock)
        applier.store.pending = request
        let device = wsStrap()
        let session = makeSession(device, applier: applier, findState: HelioFindState(), settle: false)
        let wire = try XCTUnwrap(transport)
        var steps = 0
        while device.alarmCommands.count < 2, steps < 10_000, wire.step() { steps += 1 }   // the set's write is out
        XCTAssertTrue(applier.isWriting(request.id))
        XCTAssertNil(applier.store.managed)

        let link = WSLink()
        link.session = session
        let clear = await actions(link, applier: applier).clearWakeAlarm()
        XCTAssertEqual(clear.outcome, "cleared")
        XCTAssertEqual(device.alarmCommands.filter { $0.first == 0x03 || $0.first == 0x05 }.map { $0[0] }, [0x03, 0x05],
                       "the delete followed the write")
        XCTAssertTrue(device.alarmRecords.isEmpty)
        XCTAssertNil(applier.store.managed)
        XCTAssertNil(applier.store.pending)
    }

    /// S4 (P3): iOS cancels a Times = 5 action during the first buzz. The running buzz gets its stop,
    /// no further buzz starts, and the result says how many ran.
    func testP3ACancelledMultiBuzzStartsNoMoreAndSaysHowManyRan() async throws {
        let device = wsStrap()
        let link = WSLink()
        link.session = makeSession(device, applier: applier(), findState: HelioFindState())
        var cancelled = false
        onPause = { cancelled = true }
        let result = await actions(link, applier: applier(), cancelled: { cancelled }).vibrate(times: 5)
        onPause = nil
        XCTAssertEqual(pairs(device), [0x03, 0x06], "the running buzz stopped; none started after the cancel")
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(result.outcome, "cancelled after 1 of 5")
        XCTAssertEqual(result.dialog, "Vibrated your Amazfit Helio Strap 1 of 5 times; iOS ended the action before the rest.")
    }

    /// S5: a pending request names its strap. One for another strap is dropped at the connection.
    func testARequestMadeForAnotherStrapIsDroppedAtTheConnection() throws {
        let applier = applier()
        let request = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 6, minute: 30, days: .everyDay)),
                                            strapID: "5B1E4C2A-0000-4000-8000-0000000000F0", madeAt: clock)
        applier.store.pending = request
        let device = wsStrap()
        _ = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertEqual(device.alarmCommands, [[0x09]], "nothing sent")
        XCTAssertNil(applier.store.pending)
        XCTAssertEqual(applier.outcome(for: request.id), .noWrite(.otherStrap))
    }

    /// F2: before the first unlock after a restart the device choice reads as the ring and the key as
    /// missing, so every action asks for an unlock and persists nothing.
    func testBeforeTheFirstUnlockEveryActionAsksForAnUnlockAndPersistsNothing() async throws {
        let applier = applier()
        let link = WSLink()
        let locked = actions(link, applier: applier, protectedData: false)
        let buzz = await locked.vibrate(times: 1)
        let set = await locked.setWakeAlarm(hour: 6, minute: 30, days: .once)
        let clear = await locked.clearWakeAlarm()
        for result in [buzz, set, clear] {
            XCTAssertEqual(result.dialog, "Unlock your iPhone once after restarting, then try again.")
            XCTAssertEqual(result.outcome, "protected data unavailable")
        }
        XCTAssertEqual(link.connects, 0)
        XCTAssertNil(defaults.data(forKey: StrapWakeAlarmStore.key))
    }

    /// N2: a connection-time apply leaves the Alarms screen's notice alone; the screen's own edit still sets it.
    func testAConnectionTimeApplyLeavesTheAlarmsScreensNoticeAlone() throws {
        let applier = applier()
        applier.store.pending = StrapWakeAlarmRequest(.set(StrapWakeAlarmTime(hour: 6, minute: 30, days: .once)),
                                                      strapID: strapID, madeAt: clock)
        let device = wsStrap()
        let session = makeSession(device, applier: applier, findState: HelioFindState())
        XCTAssertNotNil(applier.store.managed, "applied")
        XCTAssertNil(session.alarmNotice)
        XCTAssertNil(session.addAlarm(hour: 9, minute: 0, days: .weekend))
        transport?.drain()
        XCTAssertEqual(session.alarmNotice, "Saved on the strap.")
    }

    // MARK: decision 1: no central, no switch, no connect unless the strap is chosen AND saved

    func testWithTheRingChosenOrNoSavedStrapNoActionCreatesACentralOrSwitchesAnything() async throws {
        let standard = UserDefaults.standard
        let savedChoice = standard.object(forKey: ActiveDeviceChoiceStore.key)
        let savedStrap = standard.object(forKey: HelioConnection.savedPeripheralKey)
        let savedAlarm = standard.object(forKey: StrapWakeAlarmStore.key)
        defer {
            standard.set(savedChoice, forKey: ActiveDeviceChoiceStore.key)
            standard.set(savedStrap, forKey: HelioConnection.savedPeripheralKey)
            standard.set(savedAlarm, forKey: StrapWakeAlarmStore.key)
        }
        XCTAssertFalse(HelioConnection.shared.hasCentral, "the test host has the ring chosen")

        for (choice, saved) in [(ActiveDeviceChoice.ringConn, true), (.ringConn, false), (.helioStrap, false)] {
            standard.set(choice.rawValue, forKey: ActiveDeviceChoiceStore.key)
            if saved {
                standard.set(strapID, forKey: HelioConnection.savedPeripheralKey)
            } else {
                standard.removeObject(forKey: HelioConnection.savedPeripheralKey)
            }
            standard.removeObject(forKey: StrapWakeAlarmStore.key)
            let logBefore = standard.data(forKey: DeviceOwnershipStore.key)
            let live = WearableShortcuts(.live)

            let buzz = await live.vibrate(times: 2)
            let set = await live.setWakeAlarm(hour: 6, minute: 30, days: .once)
            let clear = await live.clearWakeAlarm()

            let label = "\(choice) saved=\(saved)"
            XCTAssertFalse(HelioConnection.shared.hasCentral, "\(label): no central")
            XCTAssertNil(HelioConnection.shared.session, label)
            XCTAssertEqual(ActiveDeviceChoiceStore.persisted(), choice, "\(label): nothing switched")
            XCTAssertEqual(standard.data(forKey: DeviceOwnershipStore.key), logBefore, "\(label): ownership log untouched")
            XCTAssertNil(standard.data(forKey: StrapWakeAlarmStore.key), "\(label): nothing persisted for a strap")
            for result in [buzz, set, clear] {
                XCTAssertFalse(result.dialog.contains("ring or strap"), result.dialog)
                XCTAssertFalse(result.dialog.isEmpty, label)
            }
            switch choice {
            case .ringConn:
                XCTAssertTrue(buzz.dialog.contains("RingConn ring"), buzz.dialog)
                XCTAssertEqual(set.dialog, "Your RingConn ring doesn't store alarms on itself. A Gen 3 ring has "
                               + "OpenCircuit's own wake-up alarm instead: Profile ▸ Device Info ▸ Vibration & alarm.")
                XCTAssertEqual(clear.dialog, "Your RingConn ring doesn't store alarms on itself, so there's nothing to clear.")
            case .helioStrap:
                for result in [buzz, set, clear] {
                    XCTAssertEqual(result.dialog, "No Amazfit Helio Strap is set up in OpenCircuit yet. Set it up in the app first.")
                }
            }
        }
    }
}
