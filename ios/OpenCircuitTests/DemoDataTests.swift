#if DEBUG && targetEnvironment(simulator)
import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The screenshot seeder's refusal rule (review #220 S1). It compiles only into Debug SIMULATOR
/// builds, and it seeds only a store with no row of ANY type it writes: seeded `StoredSample`s are
/// Health-flushable, so one real row of any kind must stop it. Synthetic rows only.
@MainActor
final class DemoDataTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func emptyContainer() throws -> ModelContainer {
        try ModelContainer(for: StoredSleepSummary.self, StoredSample.self, StoredDaytimeTemp.self,
                           StoredStepSample.self, StoredDaily.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testAnEmptyStoreMayBeSeeded() throws {
        let container = try emptyContainer()
        XCTAssertTrue(DemoData.holdsNoSeedableRows(container.mainContext))
    }

    /// Before this, only a stored night stopped it: a store with real HR, steps or temperature but
    /// no night got 30 days of synthetic vitals mixed in, and the next flush sent them to Health.
    func testOneRowOfAnySeededTypeRefuses() throws {
        let rows: [(String, (ModelContext) -> Void)] = [
            ("night", { $0.insert(StoredSleepSummary(night: self.at)) }),
            ("sample", { $0.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: self.at,
                                                end: self.at, value: 61)) }),
            ("daytime temp", { $0.insert(StoredDaytimeTemp(time: self.at, celsius: 33.1)) }),
            ("step delta", { $0.insert(StoredStepSample(start: self.at, end: self.at.addingTimeInterval(900),
                                                        delta: 120)) }),
            ("daily", { $0.insert(StoredDaily(day: self.at, steps: 4_000, updatedAt: self.at)) }),
        ]
        for (name, insert) in rows {
            let container = try emptyContainer()
            insert(container.mainContext)
            try container.mainContext.save()
            XCTAssertFalse(DemoData.holdsNoSeedableRows(container.mainContext), "one \(name) row must refuse")
        }
    }

    /// Requested, on a store holding one real heart-rate sample and no night: nothing is added.
    func testARequestedSeedLeavesAStoreWithRealSamplesUntouched() throws {
        let container = try emptyContainer()
        let context = container.mainContext
        context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: at, end: at, value: 61))
        try context.save()

        UserDefaults.standard.set(true, forKey: DemoData.launchArgumentKey)
        defer { UserDefaults.standard.removeObject(forKey: DemoData.launchArgumentKey) }
        DemoData.seedIfRequested(context, now: at.addingTimeInterval(86_400))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSample>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSleepSummary>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredStepSample>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredDaily>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredDaytimeTemp>()), 0)
    }
}
#endif
