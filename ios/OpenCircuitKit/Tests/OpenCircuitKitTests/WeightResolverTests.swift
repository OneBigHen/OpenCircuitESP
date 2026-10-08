import XCTest
@testable import OpenCircuitKit

final class WeightResolverTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testHealthNewerThanManualWins() {
        let r = WeightResolver.resolve(manualKg: 70, manualSetAt: t0,
                                       health: .init(kg: 72.5, date: t0.addingTimeInterval(60)))
        XCTAssertEqual(r.source, .appleHealth)
        XCTAssertEqual(r.kg, 72.5)
        XCTAssertEqual(r.date, t0.addingTimeInterval(60))
    }

    func testManualNewerThanHealthWins() {
        let r = WeightResolver.resolve(manualKg: 70, manualSetAt: t0,
                                       health: .init(kg: 72.5, date: t0.addingTimeInterval(-60)))
        XCTAssertEqual(r.source, .manual)
        XCTAssertEqual(r.kg, 70)
    }

    func testEqualDatesManualWins() {
        let r = WeightResolver.resolve(manualKg: 70, manualSetAt: t0, health: .init(kg: 72.5, date: t0))
        XCTAssertEqual(r.source, .manual)
        XCTAssertEqual(r.kg, 70)
    }

    func testNoHealthSampleFallsBackToManual() {
        let r = WeightResolver.resolve(manualKg: 70, manualSetAt: t0, health: nil)
        XCTAssertEqual(r, .init(kg: 70, source: .manual, date: t0))
    }

    func testNeverStampedManualLosesToAnyHealthSample() {
        let r = WeightResolver.resolve(manualKg: 70, manualSetAt: nil, health: .init(kg: 65, date: t0))
        XCTAssertEqual(r.source, .appleHealth)
        XCTAssertEqual(r.kg, 65)
    }

    func testImplausibleHealthValueIsIgnored() {
        for kg in [0.0, -3, 19.9, 500.1, .nan] {
            let r = WeightResolver.resolve(manualKg: 70, manualSetAt: nil, health: .init(kg: kg, date: t0))
            XCTAssertEqual(r.source, .manual, "\(kg)")
        }
    }

    func testEpochOverloadTreatsZeroAsAbsent() {
        // What @AppStorage holds before the reader has ever stored anything (denied / never granted).
        let r = WeightResolver.resolve(manualKg: 70, manualSetAtEpoch: 0, healthKg: 0, healthAtEpoch: 0)
        XCTAssertEqual(r, .init(kg: 70, source: .manual, date: nil))
    }

    func testDefaultsOverload() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WeightResolverTests"))
        defaults.removePersistentDomain(forName: "WeightResolverTests")
        defer { defaults.removePersistentDomain(forName: "WeightResolverTests") }
        XCTAssertEqual(WeightResolver.resolve(defaults: defaults).kg, 70, "default when nothing is stored")

        defaults.set(80.0, forKey: WeightResolver.Keys.manualKg)
        defaults.set(t0.timeIntervalSince1970, forKey: WeightResolver.Keys.manualSetAt)
        defaults.set(78.0, forKey: WeightResolver.Keys.healthKg)
        defaults.set(t0.timeIntervalSince1970 + 1, forKey: WeightResolver.Keys.healthAt)
        XCTAssertEqual(WeightResolver.resolve(defaults: defaults).kg, 78)

        defaults.set(t0.timeIntervalSince1970 + 2, forKey: WeightResolver.Keys.manualSetAt)
        XCTAssertEqual(WeightResolver.resolve(defaults: defaults).kg, 80)
    }
}
