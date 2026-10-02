import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Decision 49: the strap's PAI is its own tile in Today's Your Numbers grid (it left the strap card),
// and tapping it explains PAI. These pin the grid's rule — the same `StrapPAIReading` load
// `ContentView.loadTrends` runs, then `MetricTilesSection.paiTile`, which the view's body calls — and
// above all that a ring-only install never gets the tile. The store-level read is pinned by
// `StrapPAICardTests` (decision 45); this is the grid on top of it.
//
// Every reading and time here is synthetic.

/// 2026-09-20T12:00:00Z. In the past, so nothing here is future-dated against the real clock.
private let tNow = Date(timeIntervalSince1970: 1_789_862_400 + 12 * 3600)
private let tStoreTypes: [any PersistentModel.Type] = [
    StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
    StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
]

@MainActor
final class StrapPAITileTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let strap = SyncDeviceID(rawValue: "zeppos:AAAAAAAA-0000-4000-8000-000000000049")
    private let now = tNow

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(for: Schema(tStoreTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private func put(_ store: LocalStore, _ kind: MetricKind, _ value: Double, at time: Date,
                     device: SyncDeviceID) throws {
        store.context.insert(StoredSample(QuantitySample(kind: kind, start: time, value: value), device: device))
        try store.context.save()
    }

    /// What the grid shows a tile for at `render`, after the load `ContentView.loadTrends` runs at `now`.
    private func gridTile(_ store: LocalStore, render: Date? = nil) -> StrapPAIReading? {
        let loaded = StrapPAIReading.load(container: store.context.container, now: now)
        return MetricTilesSection.paiTile(loaded, now: render ?? now)
    }

    /// The RingConn guarantee: a ring-only install's grid never renders a PAI tile. The ring writes no
    /// `.pai` rows, and even one on the ring's timeline (nothing writes it) is never read as the strap's.
    /// PAI is not a `TodayTile.Metric` either, so the ring's six tiles are exactly what they were.
    func testARingOnlyInstallsGridNeverGetsAPAITile() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        for minute in stride(from: 0.0, to: 600, by: 5) {
            try put(store, .heartRate, 60, at: now.addingTimeInterval(-minute * 60), device: .ringConn)
        }
        XCTAssertNil(gridTile(store), "a ring day has no PAI tile")
        try put(store, .pai, 70, at: now.addingTimeInterval(-600), device: .ringConn)
        XCTAssertNil(gridTile(store), "the ring's timeline is never read as the strap's")
        XCTAssertNil(MetricTilesSection.paiTile(nil, now: now), "no reading, no tile")
        XCTAssertEqual(TodayTile.Metric.allCases,
                       [.hrv, .restingHR, .spo2, .respiratoryRate, .skinTemp, .steps],
                       "PAI is not a TodayTile: no usual range, no baseline, not in the Today sentence")
    }

    /// A strap reading gets a tile — including a missed sync day's (36 h) — and loses it at RENDER time
    /// once it ages past 48 h while the app stays open.
    func testAStrapReadingGetsATileUntilItAgesPastTwoDays() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try put(store, .pai, 101, at: now.addingTimeInterval(-36 * 3600), device: strap)
        let shown = try XCTUnwrap(gridTile(store))
        XCTAssertEqual(shown.latest.value, 101)
        XCTAssertNotNil(gridTile(store, render: now.addingTimeInterval(12 * 3600)), "exactly 48 h: still shown")
        XCTAssertNil(gridTile(store, render: now.addingTimeInterval(12 * 3600 + 1)), "past 48 h: dropped")
    }

    /// A total of 0 is a real reading (a week with no qualifying activity), so it gets a tile.
    func testAZeroGetsATile() throws {
        let store = try makeStore()
        try put(store, .pai, 0, at: now.addingTimeInterval(-3600), device: strap)
        XCTAssertEqual(gridTile(store)?.latest.value, 0)
    }

    /// A reading dated after `now` (a strap clock running fast) never gets a tile.
    func testAFutureDatedReadingGetsNoTile() {
        let ahead = StrapPAIReading(latest: HelioReading(value: 90, at: now.addingTimeInterval(60)))
        XCTAssertNil(MetricTilesSection.paiTile(ahead, now: now))
    }

    /// The explanation says what decision 49 asks for: Amazfit's score from heart-rate zones, worked out
    /// by the strap and not by OpenCircuit; no usual range because the formula isn't ours to check
    /// (decision 25); and not in Apple Health because it has no PAI type (decision 15).
    func testTheExplanationCoversWhatItIsTheMissingRangeAndAppleHealth() {
        let copy = StrapPAIInfoSheet.bullets.joined(separator: " ")
        XCTAssertTrue(copy.contains("Amazfit"))
        XCTAssertTrue(copy.contains("heart rate"))
        XCTAssertTrue(copy.contains("OpenCircuit doesn't calculate it"))
        XCTAssertTrue(copy.contains("no usual range"))
        XCTAssertTrue(copy.contains("Apple Health has no type for it"))
        XCTAssertLessThanOrEqual(StrapPAIInfoSheet.bullets.count, 4, "a few short lines, like the setup screen's")
    }
}
