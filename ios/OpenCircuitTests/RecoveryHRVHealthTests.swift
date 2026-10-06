import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 59 (#277): on iOS 27+ every HRV reading the app mirrors to Apple Health is ALSO saved to
// HealthKit's RMSSD type (Health's Recovery HRV). This host has no iOS 27 runtime, so the RMSSD type
// never resolves here; the RMSSD path runs through a writer handed a stand-in type
// (`HealthKitWriter(recoveryHRVType:)`, DEBUG only). The stand-in is `.timeInDaylight` only because it
// has a time unit, as the RMSSD type does (ms): nothing here ever asks HealthKit for it.
//
// Every reading, time and id is synthetic: round values on a fixed made-up day.

private let rDay: TimeInterval = 1_789_862_400                     // 2026-09-20T00:00:00Z
private func at(_ hours: Double) -> Date { Date(timeIntervalSince1970: rDay + hours * 3600) }
private let standIn = HKQuantityType(.timeInDaylight)
private let sdnnType = HKQuantityType(.heartRateVariabilitySDNN)
private let ms = HKUnit.secondUnit(with: .milli)

/// Records what reached the save seam, per type, and fails the types it's told to.
@MainActor
private final class SaveRecorder {
    var saved: [HKQuantitySample] = []
    var failing: Set<HKQuantityType> = []

    func install(on writer: HealthKitWriter) {
        writer.quantitySaveOverride = { [unowned self] batch in
            if let type = batch.first?.quantityType, self.failing.contains(type) {
                throw NSError(domain: "RecoveryHRVHealthTests", code: 1)
            }
            self.saved += batch
        }
    }

    func of(_ type: HKQuantityType) -> [HKQuantitySample] { saved.filter { $0.quantityType == type } }
    func reset() { saved = [] }
}

@MainActor
final class RecoveryHRVHealthTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000E277"
    private var strapTimeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }
    private let suite = "RecoveryHRVHealthTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ownership.install(DeviceOwnershipLog())        // a ring-only install unless a test says otherwise
        WorkoutHealthExclusions().clear(device: .ringConn)
        WorkoutHealthExclusions().clear(device: strapTimeline)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        WorkoutHealthExclusions().clear(device: .ringConn)
        WorkoutHealthExclusions().clear(device: strapTimeline)
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

    private func hrv(_ hours: Double, _ value: Double = 40) -> QuantitySample {
        QuantitySample(kind: .hrvSDNN, start: at(hours), value: value)
    }

    private func healthCursorNames(_ store: LocalStore, device: SyncDeviceID = .ringConn) throws -> Set<String> {
        Set(try store.context.fetch(FetchDescriptor<StoredCursor>())
            .filter { $0.deviceID == device.rawValue }
            .compactMap { SyncCursorKey.name(fromKey: $0.kindRaw, device: device) }
            .filter { $0.hasPrefix("hk:") })
    }

    // MARK: T-A: below iOS 27 nothing changes

    /// The probe the brief asked for first, kept: on this runtime (iOS 26.5) the optional lookup of the
    /// raw identifier is nil, so every rule below that reads the type is master's behaviour.
    func testTheRawRMSSDIdentifierDoesNotResolveBelowIOS27() throws {
        if #available(iOS 27, *) { throw XCTSkip("this runtime has the RMSSD type") }
        XCTAssertEqual(HealthKitWriter.recoveryHRVIdentifier.rawValue, "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD")
        XCTAssertNil(HealthKitWriter.resolveRecoveryHRVType())
        XCTAssertNil(HealthKitWriter.systemRecoveryHRVType)
        XCTAssertNil(HealthKitWriter().recoveryHRVType)
        XCTAssertNil(HealthKitHistoryInspector().recoveryHRVType)
        XCTAssertFalse(RecoveryHRVCopy.showsSwitch(recoveryHRVType: HealthKitWriter().recoveryHRVType), "no switch")
    }

    /// The resolver asks the optional lookup with the raw identifier, and returns what it answers.
    func testTheResolverUsesTheRawIdentifierThroughTheOptionalLookup() {
        var asked: [HKQuantityTypeIdentifier] = []
        XCTAssertNil(HealthKitWriter.resolveRecoveryHRVType { asked.append($0); return nil })
        XCTAssertEqual(HealthKitWriter.resolveRecoveryHRVType { _ in standIn }, standIn)
        XCTAssertEqual(asked, [HealthKitWriter.recoveryHRVIdentifier])
    }

    /// No type: one stored HRV row is written exactly as on master (the regular type, tagged, naming the
    /// same device), no new watermark row appears, and a stale "off" switch value changes nothing.
    func testWithoutTheTypeAnHRVRowIsWrittenExactlyAsOnMaster() async throws {
        for writesRegular in [true, false] {
            let store = try makeStore()
            _ = try store.ingest([hrv(2, 47)], device: .ringConn)
            let writer = HealthKitWriter(recoveryHRVType: nil)
            let recorder = SaveRecorder()
            recorder.install(on: writer)
            let pending = try store.pendingHealthSamples()
            let outcome = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil,
                                                    writesRegularHRV: writesRegular)
            XCTAssertEqual(recorder.saved.count, 1, "switch \(writesRegular)")
            let sample = try XCTUnwrap(recorder.saved.first)
            let master = try XCTUnwrap(HealthKitWriter.quantitySample(pending[0], device: sample.device))
            XCTAssertEqual(sample.quantityType, sdnnType)
            XCTAssertEqual(sample.quantityType, master.quantityType)
            XCTAssertEqual(sample.quantity.doubleValue(for: ms), 47)
            XCTAssertEqual(sample.metadata?[HealthKitWriter.hrvStatisticMetadataKey] as? String, "RMSSD")
            XCTAssertEqual(sample.startDate, at(2))
            XCTAssertEqual(outcome.regular.written, pending)
            XCTAssertTrue(outcome.recoveryHRV.written.isEmpty)
            XCTAssertTrue(outcome.recoveryHRV.failed.isEmpty)
            XCTAssertEqual(try healthCursorNames(store), ["hk:hrvSDNN"], "no Recovery HRV watermark")
        }
    }

    /// The flush's plan with no type is the pending set, untouched, whatever the switch says.
    func testThePlanWithoutTheTypeIsThePendingSetUntouched() {
        let pending = [QuantitySample(kind: .heartRate, start: at(1), value: 60), hrv(2)]
        for writesRegular in [true, false] {
            for kinds in [nil, HelioHealthPolicy.healthMirroredKinds(writesHRV: true)] {
                let plan = HealthKitWriter.scalarWritePlan(regularPending: pending, recoveryHRVPending: { [hrv(2)] },
                                                           mirroredKinds: kinds, recoveryHRVType: nil,
                                                           writesRegularHRV: writesRegular)
                XCTAssertEqual(plan, .init(regular: pending, recoveryHRV: []))
            }
        }
    }

    // MARK: T-B: the iOS 27 plumbing, through a stand-in type

    /// One stored HRV row: one regular sample (SDNN, tagged) and one Recovery HRV sample (the type, no
    /// tag), with the same start, end, value and device.
    func testOneHRVRowYieldsARegularAndARecoverySample() async throws {
        let store = try makeStore()
        _ = try store.ingest([hrv(2, 47)], device: .ringConn)
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        let recorder = SaveRecorder()
        recorder.install(on: writer)
        let outcome = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)

        let regular = try XCTUnwrap(recorder.of(sdnnType).first)
        let recovery = try XCTUnwrap(recorder.of(standIn).first)
        XCTAssertEqual(recorder.saved.count, 2)
        XCTAssertEqual(regular.metadata?[HealthKitWriter.hrvStatisticMetadataKey] as? String, "RMSSD")
        XCTAssertNil(recovery.metadata?[HealthKitWriter.hrvStatisticMetadataKey], "the type is the statistic")
        XCTAssertNil(recovery.metadata?[HKMetadataKeySyncIdentifier])
        XCTAssertEqual(recovery.startDate, regular.startDate)
        XCTAssertEqual(recovery.endDate, regular.endDate)
        XCTAssertEqual(recovery.quantity.doubleValue(for: ms), 47, "never converted")
        XCTAssertEqual(recovery.quantity.doubleValue(for: ms), regular.quantity.doubleValue(for: ms))
        XCTAssertEqual(recovery.device, regular.device)
        XCTAssertEqual(outcome.regular.written.count, 1)
        XCTAssertEqual(outcome.recoveryHRV.written.count, 1)
    }

    /// The pure builder names exactly the device it's given, as the regular copy's builder does, and
    /// builds nothing for a row that isn't HRV.
    func testTheRecoverySampleNamesTheRegularCopysDevice() throws {
        let strap = HKDevice(name: "Helio Strap", manufacturer: "Amazfit", model: nil, hardwareVersion: nil,
                             firmwareVersion: nil, softwareVersion: nil, localIdentifier: strapTimeline.rawValue,
                             udiDeviceIdentifier: nil)
        let reading = hrv(3, 52)
        let regular = try XCTUnwrap(HealthKitWriter.quantitySample(reading, device: strap))
        let recovery = try XCTUnwrap(HealthKitWriter.recoveryHRVSample(reading, type: standIn, device: strap))
        XCTAssertEqual(recovery.device?.localIdentifier, strapTimeline.rawValue)
        XCTAssertEqual(recovery.device, regular.device)
        XCTAssertEqual(recovery.quantityType, standIn)
        XCTAssertNil(recovery.metadata)
        XCTAssertNil(HealthKitWriter.recoveryHRVSample(QuantitySample(kind: .heartRate, start: at(3), value: 60),
                                                      type: standIn, device: strap))
    }

    /// The switch off: only the Recovery HRV sample, and every other kind's regular copy as before.
    func testSwitchOffWritesOnlyTheRecoverySampleForHRV() async throws {
        let store = try makeStore()
        _ = try store.ingest([QuantitySample(kind: .heartRate, start: at(1), value: 60), hrv(2)], device: .ringConn)
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        let recorder = SaveRecorder()
        recorder.install(on: writer)
        _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: false)
        XCTAssertEqual(recorder.of(standIn).count, 1)
        XCTAssertEqual(recorder.of(sdnnType).count, 0)
        XCTAssertEqual(recorder.of(HKQuantityType(.heartRate)).count, 1)
    }

    /// The strap with `writesHRV` off mirrors no HRV at all: no regular copy and no Recovery HRV.
    func testTheStrapWithHRVWithheldWritesNoRecoveryHRVEither() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try store.ingest([QuantitySample(kind: .heartRate, start: at(1), value: 60), hrv(2)], device: strapTimeline)
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        let recorder = SaveRecorder()
        recorder.install(on: writer)
        let outcome = await writer.flushScalars(store: store, device: strapTimeline,
                                                mirroredKinds: HelioHealthPolicy.healthMirroredKinds(writesHRV: false),
                                                writesRegularHRV: true)
        XCTAssertEqual(recorder.saved.map(\.quantityType), [HKQuantityType(.heartRate)])
        XCTAssertTrue(outcome.recoveryHRV.written.isEmpty)
        XCTAssertNil(try store.recoveryHRVHealthWatermark(device: strapTimeline))

        // And with the shipped policy (`writesHRV` on), the strap's reading reaches both.
        recorder.reset()
        let shipped = await writer.flushScalars(store: store, device: strapTimeline,
                                                mirroredKinds: HelioHealthPolicy.healthMirroredKinds(),
                                                writesRegularHRV: true)
        XCTAssertEqual(recorder.of(standIn).count, 1)
        XCTAssertEqual(recorder.of(sdnnType).count, 1)
        XCTAssertEqual(shipped.recoveryHRV.written.map(\.start), [at(2)])
    }

    /// The plan itself withholds Recovery HRV for a policy without HRV, with the type resolved, and
    /// never even runs the fetch. The same policy with HRV offers the rows (control).
    func testThePlanWithAResolvedTypeWithholdsRecoveryHRVForAPolicyWithoutHRV() {
        let pending = [QuantitySample(kind: .heartRate, start: at(1), value: 60)]
        var fetches = 0
        let fetch: () -> [QuantitySample] = { fetches += 1; return [self.hrv(2), self.hrv(3)] }
        for writesRegular in [true, false] {
            let withheld = HealthKitWriter.scalarWritePlan(
                regularPending: pending, recoveryHRVPending: fetch,
                mirroredKinds: HelioHealthPolicy.healthMirroredKinds(writesHRV: false),
                recoveryHRVType: standIn, writesRegularHRV: writesRegular)
            XCTAssertEqual(withheld, .init(regular: pending, recoveryHRV: []))
        }
        XCTAssertEqual(fetches, 0, "no fetch behind a closed gate")

        let mirrored = HealthKitWriter.scalarWritePlan(
            regularPending: pending, recoveryHRVPending: fetch,
            mirroredKinds: HelioHealthPolicy.healthMirroredKinds(writesHRV: true),
            recoveryHRVType: standIn, writesRegularHRV: true)
        XCTAssertEqual(mirrored.recoveryHRV, [hrv(2), hrv(3)])
        XCTAssertEqual(fetches, 1)
    }

    /// Through the flush: a strap whose `writesHRV` is off saves no Recovery HRV and creates no
    /// `hk:recoveryHRV` row, with HRV rows in the store, whatever the switch says. The rows stay
    /// pending for the day the policy mirrors HRV.
    func testAStrapFlushWithHRVWithheldSavesNoRecoveryHRVAndCreatesNoWatermark() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try store.ingest([hrv(1), QuantitySample(kind: .heartRate, start: at(2), value: 60), hrv(3), hrv(4)],
                             device: strapTimeline)
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        let recorder = SaveRecorder()
        recorder.install(on: writer)
        for writesRegular in [true, false] {
            let outcome = await writer.flushScalars(store: store, device: strapTimeline,
                                                    mirroredKinds: HelioHealthPolicy.healthMirroredKinds(writesHRV: false),
                                                    writesRegularHRV: writesRegular)
            XCTAssertTrue(outcome.recoveryHRV.written.isEmpty)
            XCTAssertTrue(outcome.recoveryHRV.failed.isEmpty)
        }
        XCTAssertTrue(recorder.of(standIn).isEmpty)
        XCTAssertTrue(recorder.of(sdnnType).isEmpty)
        XCTAssertFalse(try healthCursorNames(store, device: strapTimeline).contains("hk:recoveryHRV"))
        XCTAssertNil(try store.recoveryHRVHealthWatermark(device: strapTimeline))
        XCTAssertEqual(try store.pendingRecoveryHRVHealthSamples(device: strapTimeline).map(\.start), [at(1), at(3), at(4)])
    }

    // MARK: T-C: independent watermarks

    /// Recovery HRV fails: the regular watermark advances, Recovery HRV's doesn't, and the next pass
    /// offers only the Recovery HRV rows. Then the inverse.
    func testEachSinkKeepsItsOwnWatermarkThroughTheOthersFailure() async throws {
        let store = try makeStore()
        _ = try store.ingest([hrv(1), hrv(2), hrv(3)], device: .ringConn)
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        let recorder = SaveRecorder()
        recorder.install(on: writer)

        recorder.failing = [standIn]
        var outcome = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertEqual(outcome.regular.written.count, 3)
        XCTAssertEqual(outcome.recoveryHRV.failed, [.hrvSDNN])
        XCTAssertTrue(outcome.regular.failed.isEmpty, "not reported as the regular copy's failure")
        XCTAssertNil(try store.recoveryHRVHealthWatermark(), "not moved past an unsaved row")
        XCTAssertTrue(try store.pendingHealthSamples().isEmpty)

        recorder.failing = []
        recorder.reset()
        outcome = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertEqual(recorder.of(sdnnType).count, 0, "the regular copies are not written twice")
        XCTAssertEqual(recorder.of(standIn).map(\.startDate), [at(1), at(2), at(3)])
        XCTAssertEqual(try store.recoveryHRVHealthWatermark(), at(3))

        // The inverse: the regular save fails on new rows while Recovery HRV lands.
        _ = try store.ingest([hrv(4), hrv(5)], device: .ringConn)
        recorder.failing = [sdnnType]
        recorder.reset()
        outcome = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertEqual(outcome.regular.failed, [.hrvSDNN])
        XCTAssertEqual(recorder.of(standIn).map(\.startDate), [at(4), at(5)])
        XCTAssertEqual(try store.recoveryHRVHealthWatermark(), at(5))
        XCTAssertEqual(try store.pendingHealthSamples().map(\.start), [at(4), at(5)], "the regular watermark stayed")

        recorder.failing = []
        recorder.reset()
        _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertEqual(recorder.of(sdnnType).map(\.startDate), [at(4), at(5)])
        XCTAssertEqual(recorder.of(standIn).count, 0, "Recovery HRV is not written twice")
    }

    /// The watermark moves only after the save returned: during the save it is still where it was.
    func testTheWatermarkIsSavedOnlyAfterTheSaveSucceeds() async throws {
        let store = try makeStore()
        _ = try store.ingest([hrv(1), hrv(2)], device: .ringConn)
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        var duringSave: [Date?] = []
        writer.quantitySaveOverride = { batch in
            if batch.first?.quantityType == standIn { duringSave.append(try store.recoveryHRVHealthWatermark()) }
        }
        _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertEqual(duringSave, [nil])
        XCTAssertEqual(try store.recoveryHRVHealthWatermark(), at(2))
    }

    /// A Recovery HRV watermark is forward only, per device, and never touches `hk:hrvSDNN`.
    func testTheRecoveryWatermarkIsForwardOnlyAndPerDevice() throws {
        let store = try makeStore()
        try store.markRecoveryHRVHealthWritten([hrv(5)])
        try store.markRecoveryHRVHealthWritten([hrv(3)])
        XCTAssertEqual(try store.recoveryHRVHealthWatermark(), at(5))
        XCTAssertNil(try store.recoveryHRVHealthWatermark(device: strapTimeline))
        try store.markRecoveryHRVHealthWritten([QuantitySample(kind: .heartRate, start: at(9), value: 60)])
        XCTAssertEqual(try store.recoveryHRVHealthWatermark(), at(5), "only HRV rows move it")
        XCTAssertEqual(try healthCursorNames(store), ["hk:recoveryHRV"])
        XCTAssertEqual(LocalStore.recoveryHRVHealthCursorName, "hk:recoveryHRV")
    }

    /// The launch repair resets a future-stuck Recovery HRV watermark to the newest HRV row, like
    /// `hk:hrvSDNN`, instead of deleting it (which would re-offer the whole backfill, a second copy).
    func testTheFutureCursorRepairResetsTheRecoveryWatermarkToTheNewestHRVRow() throws {
        let store = try makeStore()
        _ = try store.ingest([hrv(1), hrv(2)], device: .ringConn)
        try store.markRecoveryHRVHealthWritten([hrv(24 * 10)])
        XCTAssertEqual(try store.repairFutureSyncCursors(now: at(3)), 1)
        XCTAssertEqual(try store.recoveryHRVHealthWatermark(), at(2))
        XCTAssertEqual(LocalStore.healthWatermarkSourceKind("recoveryHRV"), MetricKind.hrvSDNN.rawValue)
        XCTAssertEqual(LocalStore.healthWatermarkSourceKind("heartRate"), "heartRate")
    }

    // MARK: T-D: the backfill

    /// No Recovery HRV watermark: the first pass offers every retained row that passes the gates, once,
    /// even with the regular watermark far ahead; the second offers nothing.
    func testTheFirstPassBackfillsEveryRetainedRowOnceDespiteAFarAheadRegularWatermark() async throws {
        let store = try makeStore()
        var rows: [QuantitySample] = []
        for night in 0..<25 { for i in 0..<4 { rows.append(hrv(Double(-24 * night - i - 2), Double(40 + i))) } }
        rows.sort { $0.start < $1.start }
        _ = try store.ingest(rows, device: .ringConn)
        try store.markHealthWritten(try store.pendingHealthSamples())        // every regular copy already written
        XCTAssertTrue(try store.pendingHealthSamples().isEmpty)

        XCTAssertEqual(try store.pendingRecoveryHRVHealthSamples(), rows)
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        let recorder = SaveRecorder()
        recorder.install(on: writer)
        _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertEqual(recorder.of(standIn).map(\.startDate), rows.map(\.start))
        XCTAssertEqual(recorder.of(standIn).map { $0.quantity.doubleValue(for: ms) }, rows.map(\.value))
        XCTAssertTrue(recorder.of(sdnnType).isEmpty)

        recorder.reset()
        _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertTrue(recorder.saved.isEmpty, "a second pass offers nothing")
        XCTAssertTrue(try store.pendingRecoveryHRVHealthSamples().isEmpty)
    }

    // MARK: T-E: the gates, in parity

    /// Time the device doesn't own (decision 28), a workout's own readings, and `value <= 0` stay out of
    /// Recovery HRV exactly as out of the regular copy: on fresh watermarks the Recovery HRV set is the
    /// regular set's HRV rows, for both devices.
    func testRecoveryHRVPassesExactlyTheRegularCopysGates() throws {
        // The strap was chosen at hour 10; the ring owns everything before.
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(10))]))
        let store = try makeStore()
        let ringRows = [hrv(2), hrv(4, 0), hrv(6, -5), hrv(12), hrv(14)]           // 12, 14: the strap's time
        let strapRows = [hrv(3), hrv(11), hrv(13, 0), hrv(15)]                      // 3: the ring's time
        // A workout on each timeline, with its own (lasting) readings and an HRV row inside it.
        let ringWorkout = DateInterval(start: at(1), end: at(1.5))
        let strapWorkout = DateInterval(start: at(16), end: at(16.5))
        WorkoutHealthExclusions().add(ringWorkout, device: .ringConn)
        WorkoutHealthExclusions().add(strapWorkout, device: strapTimeline)
        let ringWorkoutHR = QuantitySample(kind: .heartRate, start: at(1.1), end: at(1.1).addingTimeInterval(2), value: 150)
        let strapWorkoutHR = QuantitySample(kind: .heartRate, start: at(16.1), end: at(16.1).addingTimeInterval(1), value: 150)
        _ = try store.ingest(ringRows + [ringWorkoutHR, hrv(1.2)], device: .ringConn)
        _ = try store.ingest(strapRows + [strapWorkoutHR, hrv(16.2)], device: strapTimeline)

        for (device, kinds) in [(SyncDeviceID.ringConn, nil as [MetricKind]?),
                                (strapTimeline, HelioHealthPolicy.healthMirroredKinds())] {
            let regular = try store.pendingHealthSamples(device: device, kinds: kinds)
            let recovery = try store.pendingRecoveryHRVHealthSamples(device: device)
            XCTAssertEqual(recovery, regular.filter { $0.kind == .hrvSDNN }, "\(device.rawValue)")
            XCTAssertFalse(regular.contains { $0.kind == .heartRate && $0.end > $0.start }, "workout readings excluded")
            XCTAssertTrue(recovery.allSatisfy { $0.value > 0 })
        }
        XCTAssertEqual(try store.pendingRecoveryHRVHealthSamples(device: .ringConn).map(\.start), [at(1.2), at(2)])
        XCTAssertEqual(try store.pendingRecoveryHRVHealthSamples(device: strapTimeline).map(\.start),
                       [at(11), at(15), at(16.2)])
    }

    /// A ring-only install with an empty ownership log: every positive HRV row, as the regular copy.
    func testARingOnlyInstallIsUnchanged() throws {
        let store = try makeStore()
        _ = try store.ingest([hrv(1), hrv(2, 0), hrv(3)], device: .ringConn)
        XCTAssertEqual(try store.pendingRecoveryHRVHealthSamples().map(\.start), [at(1), at(3)])
        XCTAssertEqual(try store.pendingRecoveryHRVHealthSamples(),
                       try store.pendingHealthSamples().filter { $0.kind == .hrvSDNN })
    }

    // MARK: T-F: authorization

    /// The type is in the share set exactly when it resolves, and so in the read half derived from it.
    func testTheShareSetGainsTheTypeExactlyWhenItResolves() {
        let without = HealthKitWriter(recoveryHRVType: nil).allTypes
        let with = HealthKitWriter(recoveryHRVType: standIn).allTypes
        XCTAssertEqual(without, HealthKitWriter().allTypes, "unresolved: the shipped set")
        XCTAssertFalse(without.contains(standIn))
        XCTAssertEqual(with, without.union([standIn]), "one type added, nothing else")
        XCTAssertTrue(HealthKitWriter(recoveryHRVType: standIn).authorizationReadTypes.contains(standIn))
        XCTAssertFalse(with.contains { $0 is HKCorrelationType })
    }

    /// Writable: the raw identifier is none of the Apple-computed types the app documents as refused for
    /// sharing (#110, the read-only sleeping-wrist temperature). Its shareability on iOS 27 itself was
    /// measured against the real framework (decision 59), not here.
    func testTheRecoveryIdentifierIsNotAKnownReadOnlyType() {
        let readOnly: Set<String> = [HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
                                     HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue]
        XCTAssertFalse(readOnly.contains(HealthKitWriter.recoveryHRVIdentifier.rawValue))
    }

    func testTheFriendlyNameIsRecoveryHRV() {
        XCTAssertEqual(HealthKitWriter.friendlyName(for: standIn, recoveryHRVType: standIn), "Recovery HRV")
        XCTAssertEqual(HealthKitWriter.friendlyName(for: sdnnType, recoveryHRVType: standIn), "HRV")
        XCTAssertEqual(HealthKitWriter.friendlyNames(for: [standIn, sdnnType], recoveryHRVType: standIn),
                       ["HRV", "Recovery HRV"])
    }

    /// Denying only Recovery HRV is a partial grant naming it, never "unauthorized" (heart rate decides
    /// that, as `isShareAuthorized` does).
    func testADeniedRecoveryTypeIsAPartialGrantAndNotUnauthorized() {
        let types = HealthKitWriter(recoveryHRVType: standIn).allTypes
        let state = HealthKitWriter.resolveShareState(authorizableTypes: types) { type in
            type.isEqual(standIn) ? .sharingDenied : .sharingAuthorized
        }
        guard case .partial(let denied) = state else { return XCTFail("expected .partial, got \(state)") }
        XCTAssertEqual(denied, [standIn])
        XCTAssertEqual(HealthKitWriter.friendlyNames(for: denied, recoveryHRVType: standIn), ["Recovery HRV"])
    }

    // MARK: T-G: failure bookkeeping (59e)

    /// The regular copy succeeding in the same pass leaves Recovery HRV's failure recorded; a later
    /// Recovery HRV success clears it. It is never reported as the regular HRV's failure.
    func testARecoveryFailureSurvivesARegularSuccessAndClearsOnItsOwn() {
        HealthKitWriter.recordFlushOutcome(written: [.hrvSDNN, .heartRate], failed: [],
                                           recoveryHRVWritten: false, recoveryHRVFailed: true,
                                           now: at(1), defaults)
        XCTAssertEqual(HealthKitWriter.recoveryHRVWriteFailure(defaults), at(1))
        XCTAssertTrue(HealthKitWriter.healthWriteFailures(defaults).isEmpty, "not the regular HRV's failure")
        XCTAssertEqual(HealthKitWriter.healthWriteFailureNames(defaults), ["Recovery HRV"])

        HealthKitWriter.recordFlushOutcome(written: [.hrvSDNN], failed: [], now: at(2), defaults)
        XCTAssertEqual(HealthKitWriter.recoveryHRVWriteFailure(defaults), at(1), "a regular success doesn't clear it")

        HealthKitWriter.recordFlushOutcome(written: [], failed: [.hrvSDNN], recoveryHRVWritten: true,
                                           now: at(3), defaults)
        XCTAssertNil(HealthKitWriter.recoveryHRVWriteFailure(defaults))
        XCTAssertEqual(Set(HealthKitWriter.healthWriteFailures(defaults).keys), [.hrvSDNN])
        XCTAssertEqual(HealthKitWriter.healthWriteFailureNames(defaults), ["HRV"])

        HealthKitWriter.recordFlushOutcome(written: [.hrvSDNN], failed: [], now: at(4), defaults)
        XCTAssertTrue(HealthKitWriter.healthWriteFailureNames(defaults).isEmpty)
        XCTAssertNil(defaults.object(forKey: "hk.failures.byMetric"))
    }

    /// The flush result keeps the two apart, and a Recovery HRV write alone counts as a write.
    func testTheFlushResultCountsRecoveryHRVApart() {
        var r = HealthKitWriter.FlushResult()
        XCTAssertFalse(r.wroteAnything)
        r.recoveryHRVSamples = 3
        XCTAssertTrue(r.wroteAnything)
        XCTAssertEqual(r.samples, 0)
        XCTAssertFalse(r.recoveryHRVFailed)
        XCTAssertTrue(r.failures.isEmpty)
    }

    /// The flush log lines gain Recovery HRV's result and nothing else: empty on a pass with nothing
    /// to say, so every line is byte-identical below iOS 27.
    func testTheLogSuffixNamesRecoveryHRVOnlyWhenThereIsSomethingToSay() {
        var r = HealthKitWriter.FlushResult()
        r.samples = 5
        XCTAssertEqual(r.recoveryHRVLogSuffix, "")
        r.recoveryHRVSamples = 12
        XCTAssertEqual(r.recoveryHRVLogSuffix, " recoveryHRV=12")
        r.recoveryHRVSamples = 0
        r.recoveryHRVFailed = true
        XCTAssertEqual(r.recoveryHRVLogSuffix, " recoveryHRV=failed")
        r.recoveryHRVSamples = 12
        XCTAssertEqual(r.recoveryHRVLogSuffix, " recoveryHRV=12 recoveryHRV=failed")
    }

    /// The card's lead is the old string exactly when no Recovery HRV was saved, and names Recovery HRV
    /// (never adding it into `samples`) when it was, alone when nothing else saved.
    func testTheSyncCardLeadNamesWhatWasWritten() {
        var r = HealthKitWriter.FlushResult()
        r.samples = 7
        XCTAssertEqual(r.syncedToHealthLead, "Synced to Health: 7 samples")
        r.recoveryHRVFailed = true
        XCTAssertEqual(r.syncedToHealthLead, "Synced to Health: 7 samples", "a failure isn't a write")
        r.recoveryHRVSamples = 12
        XCTAssertEqual(r.syncedToHealthLead, "Synced to Health: 7 samples, 12 Recovery HRV")
        r.samples = 0
        XCTAssertEqual(r.syncedToHealthLead, "Synced to Health: 12 Recovery HRV")
        r.recoveryHRVSamples = 0
        XCTAssertEqual(r.syncedToHealthLead, "Synced to Health: 0 samples", "unchanged when Recovery HRV wrote nothing")
    }

    /// With the regular-HRV switch off where Recovery HRV exists, a regular-HRV failure stamped before
    /// it can't clear, so it's left out of the warning's names; the map keeps it, and turning the switch
    /// on again shows it as today. Below iOS 27 (no type) the switch value changes nothing.
    func testAFrozenRegularHRVFailureIsNotNamedWhileTheSwitchIsOff() {
        HealthKitWriter.recordFlushOutcome(written: [], failed: [.hrvSDNN, .spo2], recoveryHRVFailed: true,
                                           now: at(1), defaults)
        XCTAssertEqual(HealthKitWriter.healthWriteFailureNames(defaults, recoveryHRVType: standIn),
                       ["HRV", "Recovery HRV", "SpO₂"])
        defaults.set(false, forKey: RecoveryHRVDefaults.writesRegularCopyKey)
        XCTAssertEqual(HealthKitWriter.healthWriteFailureNames(defaults, recoveryHRVType: standIn),
                       ["Recovery HRV", "SpO₂"])
        XCTAssertEqual(HealthKitWriter.healthWriteFailureNames(defaults, recoveryHRVType: nil),
                       ["HRV", "Recovery HRV", "SpO₂"], "no type: the switch doesn't exist")
        XCTAssertEqual(Set(HealthKitWriter.healthWriteFailures(defaults).keys), [.hrvSDNN, .spo2], "kept in the map")
        defaults.set(true, forKey: RecoveryHRVDefaults.writesRegularCopyKey)
        XCTAssertEqual(HealthKitWriter.healthWriteFailureNames(defaults, recoveryHRVType: standIn),
                       ["HRV", "Recovery HRV", "SpO₂"])
    }

    // MARK: T-H: the switch

    func testTheSwitchDefaultsOnWithNoStoredKey() {
        // Nothing stored (the registered default lives in the process-wide registration domain, so
        // `object(forKey:)` can already see it once any test registered it).
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[RecoveryHRVDefaults.writesRegularCopyKey])
        XCTAssertTrue(RecoveryHRVDefaults.writesRegularCopy(defaults))
        defaults.set(false, forKey: RecoveryHRVDefaults.writesRegularCopyKey)
        XCTAssertFalse(RecoveryHRVDefaults.writesRegularCopy(defaults))
    }

    /// Off keeps Recovery HRV running; on again offers what was held back, through the regular copy's own
    /// unchanged watermark, and Recovery HRV isn't written twice.
    func testSwitchOffThenOnOffersWhatWasHeldBack() async throws {
        let store = try makeStore()
        let writer = HealthKitWriter(recoveryHRVType: standIn)
        let recorder = SaveRecorder()
        recorder.install(on: writer)
        _ = try store.ingest([hrv(1)], device: .ringConn)
        _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        recorder.reset()

        // Days with the switch off.
        for day in 1...3 {
            _ = try store.ingest([hrv(Double(24 * day))], device: .ringConn)
            _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: false)
        }
        XCTAssertEqual(recorder.of(standIn).map(\.startDate), [at(24), at(48), at(72)])
        XCTAssertTrue(recorder.of(sdnnType).isEmpty)

        recorder.reset()
        _ = await writer.flushScalars(store: store, device: .ringConn, mirroredKinds: nil, writesRegularHRV: true)
        XCTAssertEqual(recorder.of(sdnnType).map(\.startDate), [at(24), at(48), at(72)])
        XCTAssertTrue(recorder.of(standIn).isEmpty)
    }

    func testTheSwitchRowIsShownOnlyWhereTheTypeResolves() {
        XCTAssertFalse(RecoveryHRVCopy.showsSwitch(recoveryHRVType: nil))
        XCTAssertTrue(RecoveryHRVCopy.showsSwitch(recoveryHRVType: standIn))
    }

    /// 59f: the text says what the switch does, and promises nothing about Health's Recovery HRV screen.
    func testTheSwitchCopySaysWhatItDoesAndPromisesNoScreen() {
        let text = (RecoveryHRVCopy.switchTitle + " " + RecoveryHRVCopy.switchFooter).lowercased()
        XCTAssertTrue(text.contains("heart rate variability"))
        XCTAssertTrue(text.contains("apps that don't read recovery hrv"))
        for promise in ["screen", "will show", "will appear", "displays", "you'll see"] {
            XCTAssertFalse(text.contains(promise), promise)
        }
    }

    // MARK: T-I: the inspector

    /// Recovery HRV nights are counted through the same helper as the regular HRV's, in ms.
    func testTheInspectorCountsRecoveryNightsThroughTheSameHelper() {
        let nights = [HealthKitHistoryInspector.NightWindow(key: at(0), window: DateInterval(start: at(-2), end: at(6))),
                      HealthKitHistoryInspector.NightWindow(key: at(24), window: DateInterval(start: at(22), end: at(30))),
                      HealthKitHistoryInspector.NightWindow(key: at(48), window: DateInterval(start: at(46), end: at(54)))]
        func samples(_ type: HKQuantityType) -> [HKQuantitySample] {
            [at(1), at(2), at(25), at(40)].map {
                HKQuantitySample(type: type, quantity: HKQuantity(unit: ms, doubleValue: 40), start: $0, end: $0)
            }
        }
        let recoveryUnit = HealthKitHistoryInspector.canonicalUnit(for: standIn, recoveryHRVType: standIn)
        let sdnnUnit = HealthKitHistoryInspector.canonicalUnit(for: sdnnType, recoveryHRVType: standIn)
        XCTAssertEqual(recoveryUnit, ms)
        XCTAssertEqual(sdnnUnit, ms)
        XCTAssertEqual(HealthKitHistoryInspector.coveredNightCount(samples: samples(standIn), nights: nights,
                                                                   unit: recoveryUnit, minimumValue: 0), 2)
        XCTAssertEqual(HealthKitHistoryInspector.coveredNightCount(samples: samples(sdnnType), nights: nights,
                                                                   unit: sdnnUnit, minimumValue: 0), 2)
        XCTAssertEqual(HealthKitHistoryInspector.recoveryHRVCoverage(nightsWithData: 2).title, "Sleep Recovery HRV")
        XCTAssertFalse(HealthKitHistoryInspector.recoveryHRVCoverage(nightsWithData: 2).supportsCurrentBaseline)
    }
}
