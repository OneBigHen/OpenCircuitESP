import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Decision 29 (#215): baselines ("your usual") are per device. A night or day is compared only with
// earlier ones from the same device, and a device new to the person starts "Learning your usual".
// Every value here is synthetic. The ring-only half pins that an empty ownership log changes nothing.

@MainActor
final class PerDeviceBaselineTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let strap = SyncDeviceID(rawValue: "zeppos:5B1E4C2A-0000-4000-8000-00000000B029")
    private let calendar = Calendar.current

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container
    }

    /// Local midnight `daysAgo` days before today (real clock, so `TrendsData`'s window holds it).
    private func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
    }

    /// A night ending at 07:00 on `day(daysAgo)` (in bed 23:00 the evening before), with `skinTempC`.
    @discardableResult
    private func saveNight(_ store: LocalStore, daysAgo: Int, skinTempC: Double, device: SyncDeviceID = .ringConn) throws -> SleepPersistOutcome {
        let start = day(daysAgo).addingTimeInterval(-3600), end = day(daysAgo).addingTimeInterval(7 * 3600)
        let segments = [SleepSegment(start: start, end: end, stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        extras.skinTempC = skinTempC
        return try store.saveSleepSummary(SleepStaging.summary(segments),
                                          night: SleepNightKey.night(inBedStart: start, inBedEnd: end),
                                          inBedStart: start, inBedEnd: end, sleepOnset: start, sleepWake: end,
                                          extras: extras, device: device)
    }

    /// Fourteen ring nights (33.0 °C), then a switch to the strap the evening before last night, and
    /// the strap's first night at 34.6 °C.
    private func ringThenStrap(_ store: LocalStore) throws -> DeviceOwnershipLog {
        for k in 1...14 { try saveNight(store, daysAgo: k, skinTempC: 33.0 + Double(k % 3) * 0.1) }
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: day(0).addingTimeInterval(-3 * 3600))])
        ownership.install(log)
        XCTAssertEqual(try saveNight(store, daysAgo: 0, skinTempC: 34.6, device: strap), .inserted)
        return log
    }

    // MARK: The new device learns its own usual

    /// Through the real trends load: the skin-temperature tile on the strap's first night reads
    /// "Learning your usual", not a +1.5 °C swing against the ring's finger temperatures.
    func testAStrapNightAfterFourteenRingNightsReadsLearningYourUsual() async throws {
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        _ = try ringThenStrap(store)
        let trends = await TrendsData.loadAsync(container: container, tempUnitRaw: TemperatureUnit.celsius.rawValue)
        XCTAssertEqual(trends.nightOwner(day(0)), .zeppOS)
        XCTAssertEqual(trends.nightOwner(day(3)), .ringConn)

        let tile = TodayTiles.build(.skinTemp, points: trends.points, restingHR: trends.restingHR,
                                    tempUnit: .celsius, scope: .from(trends))
        XCTAssertEqual(tile.valueText, "34.6")
        XCTAssertEqual(tile.rangeText, "Learning your usual · 0/4 days")
        XCTAssertNil(tile.trend?.direction, "no 'vs usual' against another device")

        let mixed = TodayTiles.build(.skinTemp, points: trends.points, restingHR: trends.restingHR, tempUnit: .celsius)
        XCTAssertTrue(mixed.rangeText.hasPrefix("Usual"), "without the scope the ring's nights would be its usual: \(mixed.rangeText)")
    }

    /// No temperature notification on the strap's first night: no same-device baseline and no
    /// same-device previous night, so neither the offset nor the night-over-night swing exists.
    func testNoTemperatureNotificationFiresOnTheFirstStrapNight() throws {
        let store = LocalStore(try makeContainer().mainContext)
        _ = try ringThenStrap(store)
        let center = HealthNotificationCenter()
        XCTAssertEqual(center.tempFeverCandidates(store: store, restingHRDaily: []).candidates, [])

        ownership.install(DeviceOwnershipLog())   // the same rows judged as one device
        XCTAssertFalse(center.tempFeverCandidates(store: store, restingHRDaily: []).candidates.isEmpty,
                       "mixed with the ring's nights, the strap's first night would have fired")
    }

    func testEachConsumerKeepsToItsOwnDevice() throws {
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        let log = try ringThenStrap(store)
        let rows = try store.recentSleepSummaries(limit: 40)
        let latest = try XCTUnwrap(store.latestSleepSummary())

        XCTAssertEqual(LocalStore.sameDevice(rows, as: latest).count, 1, "the strap's own nights only")
        let ringNight = try XCTUnwrap(rows.first { $0.skinTempC < 34 })
        XCTAssertEqual(LocalStore.sameDevice(rows, as: ringNight).count, 14, "a ring night is judged on the ring's")

        // Cycle: the strap night has no same-device baseline, so it gets no offset.
        let deviations = CycleCalendarView.skinTempDeviations(rows, log: log)
        XCTAssertFalse(deviations.contains { calendar.isDate($0.night, inSameDayAs: latest.night) })
        XCTAssertFalse(deviations.isEmpty, "the ring's nights keep theirs")

        // Vitals Status: the current device's rows only.
        let ringHR = StoredSample(QuantitySample(kind: .heartRate, start: day(2).addingTimeInterval(9 * 3600), value: 60))
        let strapHR = StoredSample(QuantitySample(kind: .heartRate, start: day(0).addingTimeInterval(9 * 3600), value: 64),
                                   device: strap)
        let own = VitalsStatusCardView.currentDeviceRows(samples: [[ringHR, strapHR]], nights: rows, log: log)
        XCTAssertEqual(own.samples[0].map(\.value), [64])
        XCTAssertEqual(own.nights.count, 1)

        // Basal energy: a strap day's resting-HR baseline never uses the ring's days.
        let daily = (0...6).map { RestingHR.DailyValue(day: day($0), bpm: 55 + Double($0)) }.sorted { $0.day < $1.day }
        XCTAssertNil(HealthKitWriter.restingEnergyInputs(forDay: day(0), from: daily, ownership: log).baseline)
        XCTAssertNotNil(HealthKitWriter.restingEnergyInputs(forDay: day(0), from: daily).baseline)

        // Headache: the strap night's day is scored against the strap's nights only.
        let snapshot = HeadacheEngine.snapshot(store: store, day: day(0), asOf: day(0).addingTimeInterval(10 * 3600),
                                               restingHR: [], calendar: calendar)
        XCTAssertEqual(snapshot.nights.count, 1)

        // Apple Health fallback: the strap takes only its own writes; the ring everything else.
        XCTAssertTrue(HealthKitVitalsBaselineReader.isFrom(.zeppOS, localIdentifier: strap.rawValue))
        XCTAssertFalse(HealthKitVitalsBaselineReader.isFrom(.zeppOS, localIdentifier: "ringconn"))
        XCTAssertFalse(HealthKitVitalsBaselineReader.isFrom(.zeppOS, localIdentifier: nil))
        XCTAssertTrue(HealthKitVitalsBaselineReader.isFrom(.ringConn, localIdentifier: "ringconn"))
        XCTAssertTrue(HealthKitVitalsBaselineReader.isFrom(.ringConn, localIdentifier: nil))
        XCTAssertFalse(HealthKitVitalsBaselineReader.isFrom(.ringConn, localIdentifier: strap.rawValue))
    }

    // MARK: Ring-only: byte-identical

    /// With an empty log every decision-29 path returns exactly what the pre-decision code computed:
    /// the same rows, the same samples, the same deviations, the same baselines, and the same alerts.
    func testARingOnlyInstallIsByteIdentical() async throws {
        ownership.install(DeviceOwnershipLog())
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        for k in 0...14 { try saveNight(store, daysAgo: k, skinTempC: k == 0 ? 34.6 : 33.0 + Double(k % 3) * 0.1) }
        for k in 0...9 {
            _ = try store.ingest([QuantitySample(kind: .heartRate, start: day(k).addingTimeInterval(3 * 3600), value: 50 + Double(k)),
                                  QuantitySample(kind: .heartRate, start: day(k).addingTimeInterval(4 * 3600), value: 52 + Double(k))])
        }
        let rows = try store.recentSleepSummaries(limit: 40)
        let latest = try XCTUnwrap(store.latestSleepSummary())

        // Store helpers.
        XCTAssertEqual(LocalStore.sameDevice(rows, as: latest).map(\.night), rows.map(\.night))
        let since = day(12)
        XCTAssertEqual(try store.recentOwnSamples(kind: .heartRate, since: since), try store.recentSamples(kind: .heartRate, since: since))
        XCTAssertEqual(try store.ownSamples(kind: .heartRate, from: since, to: Date(), of: .ringConn),
                       try store.samples(kind: .heartRate, from: since, to: Date()))

        // Tiles: no scope at all.
        let trends = await TrendsData.loadAsync(container: container, tempUnitRaw: TemperatureUnit.celsius.rawValue)
        XCTAssertNil(TodayTiles.DeviceScope.from(trends))

        // Cycle deviations: the single-baseline computation, verbatim.
        let nights = rows.filter { $0.skinTempC > 0 }.map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
        let reference: [(night: Date, offsetC: Double)] = nights.compactMap { n in
            guard let base = SkinTempBaseline.baseline(priorNights: nights.filter { $0.night < n.night }) else { return nil }
            return (n.night, SkinTempBaseline.offset(tonight: n.celsius, baseline: base))
        }
        let now = CycleCalendarView.skinTempDeviations(rows, log: DeviceOwnershipLog())
        XCTAssertEqual(now.map(\.night), reference.map(\.night))
        XCTAssertEqual(now.map(\.offsetC), reference.map(\.offsetC))

        // Vitals Status rows, basal-energy baseline.
        let sample = StoredSample(QuantitySample(kind: .heartRate, start: day(1), value: 60))
        let rowsOut = VitalsStatusCardView.currentDeviceRows(samples: [[sample]], nights: rows, log: DeviceOwnershipLog())
        XCTAssertTrue(rowsOut.samples[0].first === sample)
        XCTAssertEqual(rowsOut.nights.map(\.night), rows.map(\.night))
        let daily = (0...6).map { RestingHR.DailyValue(day: day($0), bpm: 55 + Double($0)) }.sorted { $0.day < $1.day }
        XCTAssertEqual(HealthKitWriter.restingEnergyInputs(forDay: day(0), from: daily, ownership: DeviceOwnershipLog()).baseline,
                       Calories.restingBaselineBpm(prior: daily.filter { $0.day < day(0) }.map(\.bpm)))

        // Alerts: the fever pass judges every night, as before (the jump fires).
        XCTAssertFalse(HealthNotificationCenter().tempFeverCandidates(store: store, restingHRDaily: []).candidates.isEmpty)
        // Headache: every night.
        XCTAssertEqual(HeadacheEngine.snapshot(store: store, day: day(0), asOf: day(0).addingTimeInterval(10 * 3600),
                                               restingHR: [], calendar: calendar).nights.count, rows.count)
    }
}
