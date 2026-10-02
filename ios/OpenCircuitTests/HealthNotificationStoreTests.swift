import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The persisted once-only ledger for the instant alerts (decision 32, #234): per kind, the end of
/// the latest reading that notified. SYNTHETIC values only.
final class HealthNotificationStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HealthNotificationStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheWatermarkRoundTripsPerKind() {
        let store = HealthNotificationStore(defaults)
        XCTAssertEqual(store.liveWatermark(), [:])
        let a = Date(timeIntervalSince1970: 1_780_000_000)
        let b = a.addingTimeInterval(600)
        store.markLiveWatermark([.highHR: a, .lowSpO2: b])
        XCTAssertEqual(HealthNotificationStore(defaults).liveWatermark(), [.highHR: a, .lowSpO2: b])
    }

    /// A watermark only moves forward, so a pass that read an older ledger can never re-open a
    /// reading a newer pass already claimed.
    func testTheWatermarkNeverMovesBackward() {
        let store = HealthNotificationStore(defaults)
        let later = Date(timeIntervalSince1970: 1_780_000_600)
        store.markLiveWatermark([.highHR: later])
        store.markLiveWatermark([.highHR: later.addingTimeInterval(-300),
                                 .elevatedHRInactive: later])
        XCTAssertEqual(store.liveWatermark(), [.highHR: later, .elevatedHRInactive: later])
    }

    /// The watermark is its own key: it does not disturb the backoff ledger or the night ledger.
    func testTheWatermarkIsSeparateFromTheOtherLedgers() {
        let store = HealthNotificationStore(defaults)
        let t = Date(timeIntervalSince1970: 1_780_000_000)
        store.markFired([.highHR], at: t.addingTimeInterval(60))
        store.markNight([.fever], night: 20_260_617)
        store.markLiveWatermark([.highHR: t])
        XCTAssertEqual(store.lastFired(), [.highHR: t.addingTimeInterval(60)])
        XCTAssertEqual(store.lastNotifiedNight(), [.fever: 20_260_617])
        XCTAssertEqual(store.liveWatermark(), [.highHR: t])
    }
}
