import CoreLocation
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The strap's workout (#227): the recorder against a fake live-HR source, a fake Health writer and
// an in-memory journal, plus the HelioSession half against the simulated strap. Every key, reading
// and time is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_789_862_400 + 10 * 3600)   // 2026-09-20T10:00:00Z
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// MARK: - Fakes

@MainActor
private final class FakeHRSource: StrapWorkoutHeartRateSource {
    let timeline: SyncDeviceID
    var isLinkConnected = true
    var ready = true
    var syncing = false
    var canStreamHeartRate = true
    var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var syncRequests = 0
    private(set) var orphanStops = 0

    init(timeline: SyncDeviceID = .timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-A")) {
        self.timeline = timeline
    }

    func startWorkoutHeartRate() { starts += 1 }
    func stopWorkoutHeartRate() { stops += 1 }
    func stopOrphanedHeartRate() { orphanStops += 1 }
    func syncHistory(manual: Bool) { syncRequests += 1 }

    /// The strap sends one reading.
    func send(_ bpm: Int, at date: Date) { heartRateObserver?(bpm, date) }
}

@MainActor
private final class FakeHealthWriter: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    var accept = true
    func save(_ write: StrapWorkoutWrite) async -> Bool {
        writes.append(write)
        return accept
    }
}

@MainActor
private final class MemoryJournal: StrapWorkoutJournalStoring {
    var journal: StrapWorkoutJournal?
    var samples: [HRSample] = []
    var landing: [StrapWorkoutLandingBatch] = []
    func loadJournal() -> StrapWorkoutJournal? { journal }
    func saveJournal(_ journal: StrapWorkoutJournal) { self.journal = journal }
    func appendSamples(_ samples: [HRSample]) { self.samples += samples }
    func loadSamples() -> [HRSample] { samples }
    func clearRunning() { journal = nil; samples = [] }
    func loadLanding() -> [StrapWorkoutLandingBatch] { landing }
    func saveLanding(_ batches: [StrapWorkoutLandingBatch]) { landing = batches }
}

@MainActor
private final class FakeLocation: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    private(set) var started: [Bool] = []
    private(set) var pausedCalls: [Bool] = []
    private(set) var stopped = 0
    func start(route: Bool) { started.append(route); gpsActive = true }
    func setPaused(_ paused: Bool) { pausedCalls.append(paused) }
    func stop() { stopped += 1; gpsActive = false }
}

@MainActor
private final class FakeHRStore: StrapWorkoutHRStore {
    var covered: Date?
    private(set) var inserted: [HRSample] = []
    func activityCoveredThrough(timeline: SyncDeviceID) -> Date? { covered }
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws { inserted += samples }
}

// MARK: - Recorder tests

@MainActor
final class StrapWorkoutRecorderTests: XCTestCase {
    private var now = t0
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)   // max HR 180

    private struct Rig {
        let recorder: StrapWorkoutRecorder
        let health: FakeHealthWriter
        let journal: MemoryJournal
        let location: FakeLocation
        let store: FakeHRStore
    }

    private func makeRig(source: @escaping @MainActor () -> (any StrapWorkoutHeartRateSource)?,
                         journal: MemoryJournal? = nil, store: FakeHRStore? = nil) -> Rig {
        let journal = journal ?? MemoryJournal()
        let store = store ?? FakeHRStore()
        let health = FakeHealthWriter()
        let location = FakeLocation()
        let profile = self.profile
        let recorder = StrapWorkoutRecorder(source: source, health: health, journal: journal, hrStore: { store },
                                            location: location, liveActivity: nil, profile: { profile },
                                            indoorKeepAlive: { false },
                                            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        return Rig(recorder: recorder, health: health, journal: journal, location: location, store: store)
    }

    /// One reading a second from `from` (exclusive) through `to` (inclusive), ticking the recorder
    /// each second as production does.
    private func stream(_ rig: Rig, _ source: FakeHRSource?, from: TimeInterval, to: TimeInterval, bpm: Int) async {
        var s = from + 1
        while s <= to {
            now = at(s)
            source?.send(bpm, at: now)
            await rig.recorder.tick(now: now)
            s += 1
        }
    }

    // MARK: start → pause → resume → end

    func testStartPauseResumeEndWritesOneWorkoutWithTheActiveDurationAndZones() async throws {
        let source = FakeHRSource()
        let rig = makeRig(source: { source })
        rig.recorder.selectedSport = .runningIndoor
        XCTAssertTrue(rig.recorder.canStart(source))
        rig.recorder.start()
        XCTAssertTrue(rig.recorder.isRecording)
        XCTAssertEqual(source.starts, 1, "the workout's stream starts with the workout")
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink, "history syncs wait while it runs")
        XCTAssertEqual(rig.location.started, [], "indoor without the keep-alive opt-in: no location session")

        await stream(rig, source, from: 0, to: 300, bpm: 152)            // 84 % of 180: anaerobic
        rig.recorder.pause()
        XCTAssertTrue(rig.recorder.isPaused)
        await stream(rig, source, from: 300, to: 420, bpm: 100)          // shown, never recorded
        XCTAssertEqual(rig.recorder.currentHR, 100, "the live number keeps showing while paused")
        XCTAssertEqual(rig.recorder.activeSeconds, 300, "the clock stands still while paused")
        rig.recorder.resume()
        await stream(rig, source, from: 420, to: 600, bpm: 152)
        XCTAssertEqual(rig.recorder.activeSeconds, 480)
        XCTAssertEqual(rig.location.pausedCalls, [true, false])

        await rig.recorder.end()

        XCTAssertEqual(rig.health.writes.count, 1, "exactly one HKWorkout write")
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.summary.activeSeconds, 480)
        XCTAssertEqual(write.summary.pauses, [DateInterval(start: at(300), end: at(420))], "Health gets the pause")
        XCTAssertEqual(write.samples.count, 480, "the 120 readings during the pause are not the workout's")
        XCTAssertEqual(write.summary.summary.hrSampleCount, 480)
        XCTAssertEqual(write.summary.summary.avgHR, 152)
        XCTAssertEqual(write.summary.summary.zoneBreakdown.anaerobicSeconds, 480, accuracy: 0.001)
        XCTAssertEqual(write.summary.summary.zoneBreakdown.totalZoneSeconds, 480, accuracy: 0.001)
        XCTAssertEqual(write.timeline, source.timeline, "attributed through the strap's own timeline")
        XCTAssertEqual(write.route.count, 0)
        guard case .finished(let summary, let saved) = rig.recorder.state else { return XCTFail("not finished") }
        XCTAssertTrue(saved)
        XCTAssertEqual(summary, write.summary)

        XCTAssertEqual(source.stops, 1, "End stops the workout's stream")
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink)
        XCTAssertEqual(source.syncRequests, 1, "the sync the workout held back runs at End")
        XCTAssertNil(rig.journal.journal, "nothing left to recover")
        XCTAssertEqual(rig.journal.landing.first?.samples.count, 480, "queued for LocalStore until the strap's history covers it")
        XCTAssertEqual(rig.store.inserted.count, 0, "the strap's history hasn't covered the workout yet")

        // The strap syncs past the workout: the readings land, and only then.
        rig.store.covered = at(601)
        rig.recorder.landPendingHeartRate()
        XCTAssertEqual(rig.store.inserted.count, 480)
        XCTAssertEqual(rig.journal.landing, [])

        rig.recorder.reset()
        XCTAssertEqual(rig.recorder.state, .idle)
    }

    func testEndingWhilePausedEndsWhereItStoppedRunning() async throws {
        let source = FakeHRSource()
        let rig = makeRig(source: { source })
        rig.recorder.selectedSport = .yoga
        rig.recorder.start()
        await stream(rig, source, from: 0, to: 200, bpm: 120)
        rig.recorder.pause()
        await stream(rig, source, from: 200, to: 260, bpm: 90)
        await rig.recorder.end()
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.summary.summary.endDate, at(200))
        XCTAssertEqual(write.summary.activeSeconds, 200)
        XCTAssertEqual(write.summary.pauses, [])
    }

    func testStartWaitsForTheStrapsSyncAndNeedsAStream() {
        let source = FakeHRSource()
        let rig = makeRig(source: { source })
        source.syncing = true
        XCTAssertFalse(rig.recorder.canStart(source), "like the ring's Start, not while a sync holds the link")
        rig.recorder.start()
        XCTAssertEqual(rig.recorder.state, .idle)
        source.syncing = false
        source.canStreamHeartRate = false
        XCTAssertFalse(rig.recorder.canStart(source), "no key, no stream: no workout")
        XCTAssertFalse(rig.recorder.canStart(nil))
    }

    func testCancelWritesNothing() async {
        let source = FakeHRSource()
        let rig = makeRig(source: { source })
        rig.recorder.start()
        await stream(rig, source, from: 0, to: 30, bpm: 120)
        rig.recorder.cancel()
        XCTAssertEqual(rig.health.writes.count, 0)
        XCTAssertEqual(rig.journal.landing, [])
        XCTAssertNil(rig.journal.journal)
        XCTAssertEqual(rig.recorder.state, .idle)
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink)
    }

    func testOutdoorStartsTheRouteAndTheRouteGoesToHealth() async throws {
        let source = FakeHRSource()
        let rig = makeRig(source: { source })
        rig.recorder.selectedSport = .runningOutdoor
        rig.recorder.start()
        XCTAssertEqual(rig.location.started, [true])
        rig.location.route = [CLLocation(latitude: 1, longitude: 1), CLLocation(latitude: 1.001, longitude: 1)]
        rig.location.distanceMeters = 111
        await stream(rig, source, from: 0, to: 60, bpm: 140)
        await rig.recorder.end()
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.route.count, 2)
        XCTAssertTrue(write.summary.summary.hasRoute)
        XCTAssertEqual(write.summary.summary.distanceMeters, 111)
        XCTAssertEqual(rig.location.stopped, 1)
    }

    // MARK: The app is killed

    func testAWorkoutInterruptedByAKillIsOfferedBackAndClosesAtItsLastReading() async throws {
        let journal = MemoryJournal()
        let source = FakeHRSource()
        do {
            let first = makeRig(source: { source }, journal: journal)
            first.recorder.selectedSport = .runningIndoor
            first.recorder.start()
            await stream(first, source, from: 0, to: 905, bpm: 140)
            // Readings are journaled every tick; the heartbeat last re-stamped at 900 s. Then the
            // process dies: nothing else runs.
            XCTAssertEqual(journal.journal?.lastAliveAt, at(900))
            XCTAssertEqual(journal.samples.count, 905)
        }
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "a dead process holds nothing")

        now = at(4000)   // relaunch, an hour later
        let second = makeRig(source: { source }, journal: journal)
        second.recorder.resolveOrphan()
        let recovered = try XCTUnwrap(second.recorder.recoverable)
        XCTAssertEqual(recovered.end, at(905), "its last journaled reading, never stretched to now")
        XCTAssertEqual(recovered.activeSeconds, 905)
        XCTAssertEqual(recovered.samples.count, 905)

        let saved = await second.recorder.saveRecovered()
        XCTAssertTrue(saved)
        XCTAssertEqual(second.health.writes.count, 1)
        let write = try XCTUnwrap(second.health.writes.first)
        XCTAssertEqual(write.summary.activeSeconds, 905)
        XCTAssertEqual(write.samples.count, 905)
        XCTAssertEqual(write.summary.summary.zoneBreakdown.totalZoneSeconds, 905, accuracy: 0.001)
        XCTAssertNil(journal.journal, "a second launch can't offer (and write) it twice")
        XCTAssertEqual(source.orphanStops, 1, "the dead process's stream is closed with 04 00")
        XCTAssertNil(second.recorder.recoverable)

        let third = makeRig(source: { source }, journal: journal)
        third.recorder.resolveOrphan()
        XCTAssertNil(third.recorder.recoverable)
    }

    func testDiscardAndNotNow() async throws {
        let journal = MemoryJournal()
        let source = FakeHRSource()
        do {
            let first = makeRig(source: { source }, journal: journal)
            first.recorder.start()
            await stream(first, source, from: 0, to: 20, bpm: 140)
        }
        let second = makeRig(source: { source }, journal: journal)
        second.recorder.resolveOrphan()
        XCTAssertNotNil(second.recorder.recoverable)
        second.recorder.postponeRecovered()
        XCTAssertNotNil(journal.journal, "Not now: asked again next launch")
        second.recorder.resolveOrphan()
        second.recorder.discardRecovered()
        XCTAssertNil(journal.journal)
        XCTAssertEqual(source.orphanStops, 1)
        XCTAssertEqual(second.health.writes.count, 0)
    }

    // MARK: The link drops mid-workout

    func testALinkDropKeepsTheWorkoutRunningMarksTheGapAndAdoptsTheReconnectedStrap() async throws {
        let first = FakeHRSource()
        var current: FakeHRSource? = first
        let rig = makeRig(source: { current })
        rig.recorder.selectedSport = .runningIndoor
        rig.recorder.start()
        await stream(rig, first, from: 0, to: 200, bpm: 152)

        // The link drops: HelioConnection drops the session and keeps a standing connect.
        first.isLinkConnected = false
        current = nil
        await stream(rig, nil, from: 200, to: 260, bpm: 0)
        XCTAssertTrue(rig.recorder.isRecording, "the workout keeps running")
        XCTAssertTrue(rig.recorder.linkDown)
        XCTAssertEqual(rig.recorder.activeSeconds, 260)

        // It reconnects: a new session, set up but not yet ready, then ready.
        let second = FakeHRSource()
        second.ready = false
        current = second
        await stream(rig, nil, from: 260, to: 300, bpm: 0)
        XCTAssertEqual(second.starts, 0, "not before the new session is ready")
        second.ready = true
        now = at(301)
        await rig.recorder.tick(now: now)
        XCTAssertEqual(second.starts, 1, "the reconnected strap's stream is started again")
        XCTAssertFalse(rig.recorder.linkDown)
        first.send(99, at: at(301))   // the old session is detached: ignored
        await stream(rig, second, from: 301, to: 600, bpm: 152)

        await rig.recorder.end()
        XCTAssertEqual(rig.health.writes.count, 1)
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.summary.activeSeconds, 600, "a gap is not a pause")
        XCTAssertEqual(write.summary.gaps, [DateInterval(start: at(201), end: at(301))], "the gap is marked")
        XCTAssertEqual(write.samples.count, 200 + 299)
        XCTAssertFalse(write.samples.contains { $0.bpm == 99 })
        // 199 one-second holds + the last pre-drop reading held to the 30 s cap; 299 after.
        XCTAssertEqual(write.summary.summary.zoneBreakdown.anaerobicSeconds, 199 + 30 + 299, accuracy: 0.001,
                       "the gap is never filled in")
        XCTAssertEqual(second.stops, 1)
        XCTAssertEqual(first.stops, 0, "the dead session isn't written to")
    }
}

// MARK: - HelioSession: the workout's stream

private let keyHex = "00112233445566778899aabbccddeeff"

@MainActor
private final class WorkoutStrapTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
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
    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 100_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes { session?.received(characteristic, bytes) }
            else { session?.notificationStateChanged(characteristic, enabled: enabled, failed: false) }
        }
    }

    /// Plaintext single-chunk commands the phone sent to the heart-rate endpoint (`0x001D`).
    var heartRateCommands: [[UInt8]] {
        writes.filter { $0.characteristic == .chunkedWrite }.compactMap { w in
            let b = w.bytes
            guard b.count > 11, b[0] == 0x03, b[1] & 0x01 != 0, b[1] & 0x08 == 0,
                  UInt16(b[9]) | (UInt16(b[10]) << 8) == ZeppEndpoint.heartRate else { return nil }
            return Array(b[11...])
        }
    }
}

@MainActor
private final class WorkoutKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
final class StrapWorkoutSessionTests: XCTestCase {
    private var clock = t0
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeSink() throws -> HelioStoreSink {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return HelioStoreSink(store: LocalStore(container.mainContext))
    }

    private func connect(sink: HelioStoreSink? = nil,
                         workoutHolds: @escaping @MainActor () -> Bool = { false }) -> (HelioSession, WorkoutStrapTransport) {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0),
                           (0x0043, 0), (0x0047, 0), (0x004B, 0), (0x0082, 0)]
        // Made-up versions (§5.3), so setup doesn't wait out the device-info step.
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        let transport = WorkoutStrapTransport(device: device)
        let keys = WorkoutKeys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000A2",
                                   key: keys.load(), keyStore: keys, sink: sink, findState: HelioFindState(),
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: false,
                                   workoutHoldsLink: workoutHolds)
        transport.session = session
        session.start()
        transport.drain()
        return (session, transport)
    }

    func testTheWorkoutStreamRunsPastTheMeasureBudgetAndThroughBackgrounding() {
        let (session, transport) = connect()
        XCTAssertTrue(session.ready)
        XCTAssertTrue(session.canStreamHeartRate)
        var readings: [Int] = []
        session.heartRateObserver = { bpm, _ in readings.append(bpm) }
        session.startWorkoutHeartRate()
        XCTAssertEqual(session.liveHeartRateOwner, .workout)
        XCTAssertEqual(transport.heartRateCommands, [ZeppHeartRateControl.start])
        let live = StrapLiveHeartRate(session: session)
        XCTAssertFalse(live.measuring, "a workout's stream is not a Measure")
        XCTAssertTrue(live.disabled, "Measure can't take the stream from a workout")
        live.toggle()
        XCTAssertTrue(session.liveHeartRateRunning)

        // Ten minutes, a reading and a tick every second: well past the Measure's 90 s.
        for s in 1...600 {
            clock = at(TimeInterval(s))
            session.received(.heartRateMeasurement, [0x00, 130])
            session.tick(now: clock)
        }
        XCTAssertTrue(session.liveHeartRateRunning, "no time limit (SPEC-GAP: §7.1 sets none)")
        XCTAssertEqual(readings.count, 600)
        XCTAssertEqual(transport.heartRateCommands.filter { $0 == ZeppHeartRateControl.keepRunning }.count, 600,
                       "04 02 every second")
        session.appDidEnterBackground()
        XCTAssertTrue(session.liveHeartRateRunning, "backgrounding stops a Measure, not a workout")

        session.stopWorkoutHeartRate()
        XCTAssertFalse(session.liveHeartRateRunning)
        XCTAssertEqual(transport.heartRateCommands.last, ZeppHeartRateControl.stop)
    }

    /// §18.1 route 1, §18.8: `04 01` (after enabling 0x2A37), `04 02` each second, `04 00` and unsubscribe
    /// at the end, and NOTHING on the workout endpoint `0x0019` (no start/end, never phone GPS, §18.5).
    func testRouteOneNeverTouchesTheWorkoutEndpoint() {
        let (session, transport) = connect()
        session.startWorkoutHeartRate()
        XCTAssertEqual(transport.notifyChanges.last.map { [$0.0 == .heartRateMeasurement, $0.1] }, [true, true])
        for s in 1...5 {
            clock = at(TimeInterval(s))
            session.received(.heartRateMeasurement, [0x00, 0x8f])
            session.tick(now: clock)
        }
        session.stopWorkoutHeartRate()
        XCTAssertEqual(transport.heartRateCommands,
                       [ZeppHeartRateControl.start] + Array(repeating: ZeppHeartRateControl.keepRunning, count: 5)
                       + [ZeppHeartRateControl.stop])
        XCTAssertEqual(transport.notifyChanges.last.map { [$0.0 == .heartRateMeasurement, $0.1] }, [true, false])
        XCTAssertFalse(transport.device.receivedEndpoints.contains(0x0019), "route 1 sends nothing on 0x0019")
    }

    func testClosingAnInterruptedWorkoutSendsOneStopUnlessAStreamRuns() {
        let (session, transport) = connect()
        session.stopOrphanedHeartRate()
        XCTAssertEqual(transport.heartRateCommands, [ZeppHeartRateControl.stop])
        session.startLiveHeartRate(duration: StrapLiveHeartRate.duration)
        session.stopOrphanedHeartRate()
        XCTAssertTrue(session.liveHeartRateRunning, "a Measure running on this connection is left alone")
        XCTAssertEqual(transport.heartRateCommands, [ZeppHeartRateControl.stop, ZeppHeartRateControl.start])
    }

    func testAStalledWorkoutStreamIsStartedAgain() {
        let (session, transport) = connect()
        session.startWorkoutHeartRate()
        clock = at(1)
        session.received(.heartRateMeasurement, [0x00, 120])
        for s in 2...25 {
            clock = at(TimeInterval(s))
            session.tick(now: clock)
        }
        // Silent from 1 s: restarted at 11 s and again at 21 s, never more often than every 10 s.
        XCTAssertEqual(transport.heartRateCommands.filter { $0 == ZeppHeartRateControl.start }.count, 3)
    }

    func testAMeasureIsTakenOverByAWorkoutWithoutARestart() {
        let (session, transport) = connect()
        session.startLiveHeartRate(duration: StrapLiveHeartRate.duration)
        session.startWorkoutHeartRate()
        XCTAssertEqual(session.liveHeartRateOwner, .workout)
        XCTAssertEqual(transport.heartRateCommands.filter { $0 == ZeppHeartRateControl.start }.count, 1)
        clock = at(StrapLiveHeartRate.duration + 5)
        session.received(.heartRateMeasurement, [0x00, 120])
        session.tick(now: clock)
        XCTAssertTrue(session.liveHeartRateRunning, "the Measure's 90 s no longer applies")
    }

    func testSyncsWaitWhileAWorkoutHoldsTheLink() throws {
        var holds = true
        let (session, transport) = connect(sink: try makeSink(), workoutHolds: { holds })
        session.syncHistory(manual: true)
        XCTAssertFalse(session.syncing)
        XCTAssertEqual(session.syncStatus, "Syncs after the workout ends")
        XCTAssertFalse(transport.notifyChanges.contains { $0.0 == .activityControl })
        holds = false
        session.syncHistory(manual: false)
        XCTAssertTrue(session.syncing, "and runs once it ends")
    }
}

// MARK: - LocalStore: workout readings never move the strap's watermarks

@MainActor
final class StrapWorkoutStoreTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-B")

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
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

    func testWorkoutReadingsLandWithoutMovingEitherWatermarkAndOnlyOnce() throws {
        let store = try makeStore()
        let readings = (1...120).map { HRSample(bpm: 150, start: at(Double($0) - 1), end: at(Double($0))) }
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        try store.insertWorkoutHeartRate(readings, timeline: timeline)   // a retried landing
        let rows = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertEqual(rows.count, 120, "no duplicates")
        XCTAssertTrue(rows.allSatisfy { $0.deviceID == timeline.rawValue && $0.kindRaw == MetricKind.heartRate.rawValue })
        XCTAssertNil(try store.loadCursor(device: timeline).last(.heartRate), "the ingest watermark is untouched")

        // The strap's own history from BEFORE the workout still goes in afterwards.
        let earlier = [QuantitySample(kind: .heartRate, start: at(-3600), value: 70)]
        XCTAssertEqual(try store.ingest(earlier, device: timeline).count, 1)
        XCTAssertNil(store.activityCoveredThrough(timeline: timeline))
    }
}
