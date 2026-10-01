import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Drives the app's REAL instant-alert wiring, `HealthNotificationCenter.decideAndClaim` — the
/// synchronous stretch `evaluate` runs before its first `await` — rather than a test-side copy of it.
/// Each test names the mis-wiring it exists to catch. SYNTHETIC readings only.
@MainActor
final class HealthNotificationWiringTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: HealthNotificationStore!
    private let cal = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        suiteName = "HealthNotificationWiringTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = HealthNotificationStore(defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: h, minute: m))!
    }
    private var highHROnly: HealthAlertThresholds {
        HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
    }
    private let noQuiet = QuietHours(enabled: false)
    private let nightQuiet = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)

    private func pass(hr: [HRSample], nightLevel: [HealthNotification] = [],
                      quiet: QuietHours, gate: NotificationGate = NotificationGate(), now: Date)
        -> (fire: [HealthNotification], hits: [HealthNotification: HealthAlertHit]) {
        HealthNotificationCenter.decideAndClaim(hr: hr, spo2: [], inactiveHR: hr,
                                                nightLevel: nightLevel, thresholds: highHROnly,
                                                quiet: quiet, store: store, gate: gate,
                                                now: now, calendar: cal)
    }

    /// A fresh crossing fires, and BOTH ledgers are claimed. Catches a dropped `markLiveWatermark`
    /// or `markFired`.
    func testAFreshCrossingFiresAndClaimsBothLedgers() {
        let reading = HRSample(bpm: 146, start: at(10, 55), end: at(10, 56))
        let out = pass(hr: [reading], quiet: noQuiet, now: at(12, 0))
        XCTAssertEqual(out.fire, [.highHR])
        XCTAssertEqual(out.hits[.highHR]?.value, 146)
        XCTAssertEqual(store.lastFired()[.highHR], at(12, 0))
        XCTAssertEqual(store.liveWatermark()[.highHR], at(10, 56))
    }

    /// The watermark is claimed for what the gate let THROUGH, never for a candidate it held. Here
    /// fever fires while high HR is held by the backoff. Catches `candidates` passed where `fire`
    /// belongs.
    func testACandidateTheGateHeldClaimsNoWatermark() {
        store.markFired([.highHR], at: at(11, 30))
        let out = pass(hr: [HRSample(bpm: 146, start: at(11, 55))], nightLevel: [.fever],
                       quiet: noQuiet, now: at(12, 0))
        XCTAssertEqual(out.fire, [.fever])
        XCTAssertNil(store.liveWatermark()[.highHR])
        XCTAssertNil(out.hits[.highHR])
    }

    /// With a backoff SHORTER than the freshness limit, only the watermark stops the same crossing
    /// firing twice. Catches a dropped `markLiveWatermark`.
    func testTheSameCrossingFiresOnceEvenWithAShortBackoff() {
        let gate = NotificationGate(renotifyInterval: 10 * 60)
        let reading = [HRSample(bpm: 146, start: at(11, 55))]
        XCTAssertEqual(pass(hr: reading, quiet: noQuiet, gate: gate, now: at(12, 0)).fire, [.highHR])
        XCTAssertEqual(pass(hr: reading, quiet: noQuiet, gate: gate, now: at(12, 20)).fire, [],
                       "backoff expired, reading still fresh: the watermark must hold it")
    }

    /// Two racing passes (sync-complete and foreground) on the same ledgers: one fires.
    func testTwoRacingPassesFireOnce() {
        let reading = [HRSample(bpm: 146, start: at(11, 55))]
        XCTAssertEqual(pass(hr: reading, quiet: noQuiet, now: at(12, 0)).fire, [.highHR])
        XCTAssertEqual(pass(hr: reading, quiet: noQuiet, now: at(12, 0)).fire, [])
    }

    /// The gate uses the quiet hours it was GIVEN, never a fresh read of the setting. The stored
    /// setting is made to disagree with the argument both ways. Catches `quiet` re-read at the gate.
    func testTheGateUsesTheQuietHoursItWasGiven() {
        let d = UserDefaults.standard
        let keys = [HealthAlertDefaults.quietEnabled, HealthAlertDefaults.quietStartMinutes,
                    HealthAlertDefaults.quietEndMinutes]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        d.set(22 * 60, forKey: HealthAlertDefaults.quietStartMinutes)
        d.set(7 * 60, forKey: HealthAlertDefaults.quietEndMinutes)

        // Stored: quiet ON. Argument: OFF. A 02:50 crossing at 03:00 must fire.
        d.set(true, forKey: HealthAlertDefaults.quietEnabled)
        XCTAssertEqual(pass(hr: [HRSample(bpm: 146, start: at(2, 50))], quiet: noQuiet,
                            now: at(3, 0)).fire, [.highHR])

        // Stored: quiet OFF. Argument: ON. A night-level candidate at 03:00 must be held.
        d.set(false, forKey: HealthAlertDefaults.quietEnabled)
        XCTAssertEqual(pass(hr: [], nightLevel: [.fever], quiet: nightQuiet, now: at(3, 0)).fire, [])
    }

    /// Night-level candidates route through the same gate and claim no watermark: on the morning
    /// pass after quiet hours they fire, hours after the night they describe.
    func testNightLevelCandidatesFireAfterQuietHoursAndClaimNoWatermark() {
        XCTAssertEqual(pass(hr: [], nightLevel: [.fever, .skinTempRise], quiet: nightQuiet,
                            now: at(6, 30)).fire, [])
        XCTAssertEqual(pass(hr: [], nightLevel: [.fever, .skinTempRise], quiet: nightQuiet,
                            now: at(7, 30)).fire, [.skinTempRise, .fever])
        XCTAssertEqual(store.liveWatermark(), [:])
    }
}
