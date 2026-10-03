import Security
import XCTest
@testable import OpenCircuit

/// Steer 4 (review-261 F2): the Shortcuts actions refuse only before the first unlock since boot, never
/// because the phone is merely locked. The decision is pure over the sentinel's probe result.
final class FirstUnlockGateTests: XCTestCase {
    func testOnlyBeforeTheFirstUnlockRefuses() {
        XCTAssertEqual(FirstUnlockGate.verdict(for: .beforeFirstUnlock), .refuse)
        XCTAssertEqual(FirstUnlockGate.verdict(for: .readable), .proceed, "locked after the first unlock still reads")
        XCTAssertEqual(FirstUnlockGate.verdict(for: .missing), .proceed, "no sentinel yet: nothing says it's unreadable")
        XCTAssertEqual(FirstUnlockGate.verdict(for: .failed(-34018)), .proceed, "any other error: proceed (and log)")
        XCTAssertEqual(FirstUnlockGate.verdict(for: .failed(errSecNotAvailable)), .proceed)
    }

    /// The one test whose subject IS the keychain: the sentinel round-trips. It skips only on `-34018`
    /// (no keychain entitlement, the orchestrator's unsigned runs; `_shared-rules.md`).
    func testTheSentinelRoundTripsInTheKeychain() throws {
        let sentinel = FirstUnlockSentinel(service: "com.standardsoftwaresolutions.opencircuit.firstUnlockSentinel.test")
        sentinel.remove()
        defer { sentinel.remove() }
        let missing = sentinel.probe()
        if missing == .failed(-34018) { throw XCTSkip("keychain unavailable in an unsigned run (-34018)") }
        XCTAssertEqual(missing, .missing)
        let added = sentinel.ensure()
        if added == -34018 { throw XCTSkip("keychain unavailable in an unsigned run (-34018)") }
        XCTAssertEqual(added, errSecSuccess)
        XCTAssertEqual(sentinel.probe(), .readable, "after the first unlock it reads, locked or not")
        XCTAssertEqual(sentinel.ensure(), errSecSuccess, "idempotent")
    }
}
