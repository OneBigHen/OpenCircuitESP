import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// #241 / decision 46: ending a ring workout must leave the ring's unsynced heart rate alone.
//
// The defect these were written against (build 62): the End path handed the workout's readings to
// `LocalStore.ingest`, parking the ring's `(ringconn, heartRate)` ingest cursor at the workout's
// last reading. The history channel is shut for the whole workout, so the drain that re-arms at End
// carries everything the ring buffered since the last sync — all of it older than that cursor, all
// of it dropped in silence. A morning workout before the morning sync cost the whole night.
//
// The Health mirror had the same shape: a flush between End and that drain wrote the workout's rows
// and moved `hk:heartRate` to the workout's end, so the back-filled older rows could never be
// offered to Apple Health afterwards either.
//
// Every reading here is synthetic.

@MainActor
final class RingWorkoutHeartRateTests: XCTestCase {

    /// The workout: 2026-09-20T10:00:00Z → 10:10:00Z.
    private let t0 = Date(timeIntervalSince1970: 1_789_862_400 + 10 * 3600)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(DeviceOwnershipLog())        // a ring-only install: the ring owns all time
        WorkoutHealthExclusions().clear(device: .ringConn)
    }

    override func tearDown() {
        WorkoutHealthExclusions().clear(device: .ringConn)
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

    // MARK: Fixtures

    /// What `WorkoutSessionManager.collectHRSnapshot` collects: one reading per ~10 s `0x4e` sport
    /// frame, each stamped over the two seconds leading up to the lock (`start: at-2, end: at`).
    private var workoutReadings: [HRSample] {
        stride(from: 10.0, through: 600.0, by: 10).map { HRSample(bpm: 150, start: at($0 - 2), end: at($0)) }
    }

    /// The night the ring buffered and never got to sync: 22:00 → 06:00 the previous evening, one
    /// INSTANT per 150-s epoch, which is what `BulkSleep.samples` builds.
    private var unsyncedNight: [QuantitySample] {
        stride(from: -12 * 3600.0, to: -4 * 3600.0, by: 150)
            .map { QuantitySample(kind: .heartRate, start: at($0), value: 58) }
    }

    /// The ring's own all-day history for the workout window, which the same drain carries.
    private var ringHistoryInsideTheWorkout: [QuantitySample] {
        stride(from: 0.0, to: 600.0, by: 150).map { QuantitySample(kind: .heartRate, start: at($0), value: 149) }
    }

    private func heartRateRows(_ store: LocalStore) throws -> [StoredSample] {
        let kindRaw = MetricKind.heartRate.rawValue
        return try store.context
            .fetch(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == kindRaw },
                                                 sortBy: [SortDescriptor(\.start, order: .forward)]))
    }

    /// The End path, as `WorkoutSessionManager.stop()` runs it.
    private func endWorkout(_ store: LocalStore) async throws {
        try await store.landRingWorkoutHeartRate(workoutReadings)
    }

    /// The drain that re-arms once the workout releases the link.
    @discardableResult
    private func drain(_ store: LocalStore) throws -> [QuantitySample] {
        try store.ingest(unsyncedNight + ringHistoryInsideTheWorkout)
    }

    // MARK: The store's ingest watermark

    /// THE REGRESSION. On build 62 this stored 0 of the night's 192 readings.
    func testTheDrainAfterAWorkoutStillStoresTheNightsBufferedHeartRate() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        XCTAssertNil(try store.loadCursor().last(.heartRate), "the workout moves no ingest watermark")

        let ingested = try drain(store)
        XCTAssertEqual(ingested.count, unsyncedNight.count + ringHistoryInsideTheWorkout.count,
                       "every reading from before AND during the workout lands")
        let rows = try heartRateRows(store)
        XCTAssertEqual(rows.count, workoutReadings.count + unsyncedNight.count + ringHistoryInsideTheWorkout.count)
        XCTAssertEqual(Set(rows.map(\.start)).count, rows.count, "nothing duplicated")
        XCTAssertEqual(rows.filter { $0.start < self.at(0) }.count, unsyncedNight.count, "the whole night")
    }

    /// Re-running End is still a no-op — the job the cursor gate used to do, now done by
    /// deduplication on `start`.
    func testReRunningTheEndPathIsANoOp() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        let after = try heartRateRows(store).map { [$0.start, $0.end] }
        let spans = WorkoutHealthExclusions().intervals(device: .ringConn)

        try await endWorkout(store)
        XCTAssertEqual(try heartRateRows(store).map { [$0.start, $0.end] }, after)
        XCTAssertEqual(WorkoutHealthExclusions().intervals(device: .ringConn), spans, "one span, not two")
        XCTAssertNil(try store.loadCursor().last(.heartRate))
    }

    /// A drain that re-delivers readings at the same instants the workout stored does not duplicate
    /// them either (the ring stamps its history on 150-s epoch boundaries, so this is defensive).
    func testHistoryAtTheSameInstantsAsWorkoutReadingsDoesNotDuplicate() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        let collisions = workoutReadings.prefix(5).map {
            QuantitySample(kind: .heartRate, start: $0.start, value: Double($0.bpm))
        }
        _ = try store.ingest(Array(collisions))
        try await endWorkout(store)
        XCTAssertEqual(try heartRateRows(store).count, workoutReadings.count + collisions.count,
                       "the drain's own rows land; the workout's are not re-inserted")
    }

    /// Chunking exists only for the scene-update watchdog, so it must not change the outcome.
    func testTheResultIsChunkSizeInvariant() async throws {
        var counts: [Int] = []
        for size in [1, 7, 64, 10_000] {
            WorkoutHealthExclusions().clear(device: .ringConn)
            let store = try makeStore()
            try await store.landRingWorkoutHeartRate(workoutReadings, chunkSize: size)
            counts.append(try heartRateRows(store).count)
            XCTAssertEqual(WorkoutHealthExclusions().intervals(device: .ringConn).count, 1)
        }
        XCTAssertEqual(counts, Array(repeating: workoutReadings.count, count: 4))
    }

    func testAChunkedLandingYieldsBetweenEverySave() async throws {
        let store = try makeStore()
        var turns = 0
        try await store.landRingWorkoutHeartRate(workoutReadings, chunkSize: 10) { turns += 1 }
        XCTAssertEqual(turns, 6, "60 readings in chunks of 10")
    }

    // MARK: The Health mirror's watermark

    /// The workout's readings are already in Apple Health inside the HKWorkout `writeWorkout`
    /// committed, so the flush must not offer them — and must not move `hk:heartRate` past them.
    func testTheFlushOffersTheBacklogButNotTheWorkoutsOwnReadings() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        try drain(store)

        let pending = try store.pendingHealthSamples(kinds: [.heartRate])
        XCTAssertEqual(pending.count, unsyncedNight.count + ringHistoryInsideTheWorkout.count)
        XCTAssertTrue(pending.allSatisfy { $0.end == $0.start }, "only history instants, never a workout reading")
        XCTAssertEqual(pending.filter { $0.start < self.at(0) }.count, unsyncedNight.count)

        try store.markHealthWritten(pending, device: .ringConn)
        XCTAssertEqual(try store.pendingHealthSamples(kinds: [.heartRate]).count, 0, "nothing offered twice")
    }

    /// The issue's comment: a flush landing BETWEEN End and the next drain used to move
    /// `hk:heartRate` to the workout's end, so the back-filled night could never reach Health even
    /// once the store side was fixed.
    func testAFlushRightAfterEndLeavesTheBackfillStillPending() async throws {
        let store = try makeStore()
        try await endWorkout(store)

        let rightAfterEnd = try store.pendingHealthSamples(kinds: [.heartRate])
        XCTAssertEqual(rightAfterEnd, [], "the workout's own readings are not offered")
        try store.markHealthWritten(rightAfterEnd, device: .ringConn)

        try drain(store)
        let pending = try store.pendingHealthSamples(kinds: [.heartRate])
        XCTAssertEqual(pending.count, unsyncedNight.count + ringHistoryInsideTheWorkout.count,
                       "the night still reaches Apple Health")
    }

    /// The ring's own history INSIDE the workout window is kept and mirrored like any other
    /// history (decision 46). Only a row that lasts a moment — a workout reading — is held back.
    func testTheRingsOwnRowsInsideTheWorkoutStillReachHealth() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        _ = try store.ingest(ringHistoryInsideTheWorkout)
        let pending = try store.pendingHealthSamples(kinds: [.heartRate])
        XCTAssertEqual(pending.map(\.start), ringHistoryInsideTheWorkout.map(\.start))
    }

    /// Does a ring workout's heart rate reach Apple Health twice today? Yes — this is build 62's
    /// behaviour, reproduced by dropping the span the fix records: the rows sit in the store above
    /// `hk:heartRate`, so the flush writes them as standalone samples beside the HKWorkout that
    /// already holds them. The exclusion is what stops it.
    func testWithoutTheExclusionTheWorkoutsReadingsWouldBeWrittenToHealthASecondTime() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        WorkoutHealthExclusions().clear(device: .ringConn)
        let pending = try store.pendingHealthSamples(kinds: [.heartRate])
        XCTAssertEqual(pending.count, workoutReadings.count)
        XCTAssertTrue(pending.allSatisfy { $0.end > $0.start })
    }

    /// A span is dropped once the Health watermark has passed its end — nothing inside it can be
    /// pending any more, so it must not accumulate in UserDefaults for the life of the install.
    func testASpanIsDroppedOnceTheHealthWatermarkPassesIt() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        XCTAssertEqual(WorkoutHealthExclusions().intervals(device: .ringConn).count, 1)
        let later = [QuantitySample(kind: .heartRate, start: at(3600), value: 70)]
        _ = try store.ingest(later)
        let pending = try store.pendingHealthSamples(kinds: [.heartRate])
        XCTAssertEqual(pending, later)
        try store.markHealthWritten(pending, device: .ringConn)
        _ = try store.pendingHealthSamples(kinds: [.heartRate])
        XCTAssertEqual(WorkoutHealthExclusions().intervals(device: .ringConn), [])
    }

    // MARK: Only a workout reading lasts a moment

    /// The discriminator the exclusion relies on. If any OTHER ring heart-rate row could land
    /// inside a workout span with `end > start`, it would be withheld from Health by mistake.
    func testEveryOtherRingHeartRateRowIsAnInstant() async throws {
        let store = try makeStore()
        try await endWorkout(store)
        // The history drain (`BulkSleep.samples` / `RingSession.persist`).
        _ = try store.ingest(ringHistoryInsideTheWorkout)
        // A live / on-demand reading settled inside the window (`RingSession.stopLiveMonitoring`).
        _ = try store.insertLiveReadings([QuantitySample(kind: .heartRate, start: at(305), value: 148)])
        // `handleEndOfHistory`'s placeholders, which carry value 0.
        _ = try store.ingest([QuantitySample(kind: .heartRate, start: at(400), value: 0)])

        let spanned = try heartRateRows(store).filter { $0.end > $0.start }
        XCTAssertEqual(spanned.count, workoutReadings.count, "only the workout's readings have a span")
        XCTAssertEqual(Set(spanned.map(\.value)), [150])
    }

    /// `handleEndOfHistory`'s 0-bpm placeholders are rejected by `isPlausible` before the cursor
    /// ever sees them, so that `ingest` caller cannot move the watermark over a backlog.
    func testEndOfHistoryPlaceholdersAreRejectedAndMoveNoWatermark() throws {
        let store = try makeStore()
        let placeholders = [QuantitySample(kind: .heartRate, start: at(0), value: 0),
                            QuantitySample(kind: .heartRate, start: at(150), value: 0)]
        XCTAssertEqual(try store.ingest(placeholders), [])
        XCTAssertNil(try store.loadCursor().last(.heartRate))
        XCTAssertEqual(try heartRateRows(store).count, 0)
    }

    // MARK: The live / on-demand reading on the same End path

    /// Ending a workout that fell back to the `0x95` live poll tears the cycle down through
    /// `RingSession.stopLiveMonitoring`, which persists the settled reading. Through `ingest` that
    /// was the same cursor jump as the workout's own rows — one reading stamped at the workout's
    /// end was enough to drop the whole night again.
    func testALiveReadingDoesNotMoveTheIngestWatermarkEither() throws {
        let store = try makeStore()
        let settled = [QuantitySample(kind: .heartRate, start: at(601), value: 128),
                       QuantitySample(kind: .spo2, start: at(601), value: 0.97)]
        XCTAssertEqual(try store.insertLiveReadings(settled).count, 2)
        XCTAssertNil(try store.loadCursor().last(.heartRate))
        XCTAssertNil(try store.loadCursor().last(.spo2))

        XCTAssertEqual(try store.ingest(unsyncedNight).count, unsyncedNight.count, "the backlog still lands")
    }

    func testRePersistingTheSameLiveReadingStoresNothing() throws {
        let store = try makeStore()
        let settled = [QuantitySample(kind: .heartRate, start: at(601), value: 128)]
        XCTAssertEqual(try store.insertLiveReadings(settled).count, 1)
        XCTAssertEqual(try store.insertLiveReadings(settled).count, 0)
        XCTAssertEqual(try heartRateRows(store).count, 1)
    }

    func testALiveReadingStillReachesAppleHealth() throws {
        let store = try makeStore()
        let settled = [QuantitySample(kind: .heartRate, start: at(601), value: 128)]
        _ = try store.insertLiveReadings(settled)
        XCTAssertEqual(try store.pendingHealthSamples(kinds: [.heartRate]), settled)
    }

    func testImplausibleLiveReadingsAreStillRejected() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.insertLiveReadings([
            QuantitySample(kind: .heartRate, start: at(0), value: 0),
            QuantitySample(kind: .heartRate, start: at(10), value: 400),
            QuantitySample(kind: .steps, start: at(20), value: 100),   // cumulative: ingest's job
        ]), [])
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSample>()).count, 0)
    }

    // MARK: The hard constraint — no double counting

    private let profile = UserProfile(age: 35, weightKg: 70, heightCm: 175, sex: .male)

    /// What `HealthKitWriter.flushActiveCalories` and `GoalsCardView` read, over the store's rows.
    private func dayEstimate(_ store: LocalStore) throws -> Calories.DailyEstimate {
        let day = Calendar(identifier: .gregorian).startOfDay(for: t0)
        let hr = try store.ownedSamples(kind: .heartRate, from: day, to: at(12 * 3600))
        return Calories.dailyEstimate(hrSamples: hr.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) },
                                      steps: 0, profile: profile, dayStart: day)
    }

    /// The constraint that matters outside the app: the active energy Apple Health ends up with is
    /// the same whether or not the ring's history for the workout window arrived. The workout's own
    /// `activeEnergyBurned` sample is netted out of the daily estimate, and `finalize` prices that
    /// sample over the workout's TRUE duration at its average bpm — exactly what the day's HR
    /// channel now holds for the same hour. So the daily delta is 0 either way, and the only active
    /// energy Health receives is the workout's own sample.
    func testActiveEnergyWrittenToHealthIsTheSameEitherWay() async throws {
        let credited = Calories.workoutActiveKcal(avgHR: 150, durationSeconds: 600, profile: profile)

        let withoutHistory = try makeStore()
        try await endWorkout(withoutHistory)
        let before = HealthKitWriter.netDailyActiveKcalEstimate(
            hrKcal: try dayEstimate(withoutHistory).activeKcal, stepKcal: 0, workoutActiveKcal: credited)

        WorkoutHealthExclusions().clear(device: .ringConn)
        let withHistory = try makeStore()
        try await endWorkout(withHistory)
        _ = try withHistory.ingest(ringHistoryInsideTheWorkout)
        let after = HealthKitWriter.netDailyActiveKcalEstimate(
            hrKcal: try dayEstimate(withHistory).activeKcal, stepKcal: 0, workoutActiveKcal: credited)

        XCTAssertEqual(before, 0, accuracy: 1e-9)
        XCTAssertEqual(after, 0, accuracy: 1e-9, "the day's HR channel is exactly the workout's own kcal")
        XCTAssertEqual(after, before, accuracy: 1e-9)
    }

    /// Activity minutes DO move, and this records by how much and why. 10 readings/minute × 2 s is
    /// all the time the workout's own stamps assert; the ring's history covers the rest of the
    /// window. It is a correction of an under-count, not a double count: the readers union
    /// overlapping elevated time, so re-delivering the same series changes nothing
    /// (`RingWorkoutOverlapTests`), and the total never exceeds the workout's real length.
    func testActivityMinutesRiseToTheWorkoutsRealLengthAndNoFurther() async throws {
        let withoutHistory = try makeStore()
        try await endWorkout(withoutHistory)
        XCTAssertEqual(try dayEstimate(withoutHistory).elevatedMinutes, 2.0, accuracy: 1e-9,
                       "60 readings × 2 s")

        WorkoutHealthExclusions().clear(device: .ringConn)
        let withHistory = try makeStore()
        try await endWorkout(withHistory)
        _ = try withHistory.ingest(ringHistoryInsideTheWorkout)
        let minutes = try dayEstimate(withHistory).elevatedMinutes
        XCTAssertEqual(minutes, 10.0, accuracy: 1e-9, "the ten-minute workout, covered once")

        // Re-delivering the same history a second time cannot add a minute.
        _ = try withHistory.ingest(ringHistoryInsideTheWorkout)
        XCTAssertEqual(try dayEstimate(withHistory).elevatedMinutes, minutes, accuracy: 1e-9)
    }
}
