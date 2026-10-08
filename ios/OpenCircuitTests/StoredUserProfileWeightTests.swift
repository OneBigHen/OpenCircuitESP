import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// #284: `HealthKitWriter.storedUserProfile` (the Health write path's profile) uses the resolved weight.
@MainActor
final class StoredUserProfileWeightTests: XCTestCase {
    private let suite = "StoredUserProfileWeightTests"
    private let t0 = 1_700_000_000.0

    private func defaults() throws -> UserDefaults {
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        return d
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testNewerHealthWeightFeedsTheProfile() throws {
        let d = try defaults()
        d.set(70.0, forKey: WeightResolver.Keys.manualKg)
        d.set(t0, forKey: WeightResolver.Keys.manualSetAt)
        d.set(75.0, forKey: WeightResolver.Keys.healthKg)
        d.set(t0 + 10, forKey: WeightResolver.Keys.healthAt)
        XCTAssertEqual(HealthKitWriter.storedUserProfile(d).weightKg, 75)
    }

    func testNoHealthCacheKeepsTheManualWeight() throws {
        let d = try defaults()
        d.set(70.0, forKey: WeightResolver.Keys.manualKg)
        d.set(t0, forKey: WeightResolver.Keys.manualSetAt)
        XCTAssertEqual(HealthKitWriter.storedUserProfile(d).weightKg, 70)
    }

    func testOlderHealthWeightLosesToTheManualEntry() throws {
        let d = try defaults()
        d.set(70.0, forKey: WeightResolver.Keys.manualKg)
        d.set(t0, forKey: WeightResolver.Keys.manualSetAt)
        d.set(75.0, forKey: WeightResolver.Keys.healthKg)
        d.set(t0 - 10, forKey: WeightResolver.Keys.healthAt)
        XCTAssertEqual(HealthKitWriter.storedUserProfile(d).weightKg, 70)
    }
}
