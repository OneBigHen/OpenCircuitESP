import XCTest
@testable import OpenCircuit

// Decision 33 (#233): HealthKit background delivery of the iPhone's step count as the strap's second
// wake. HealthKit itself is faked: what is asked of it, when, and that its completion handler is
// called exactly once on every path.

@MainActor
private final class FakeStepDelivery: StepDeliveryControlling {
    var requests = 0
    var starts = 0
    var stops = 0
    var enables = 0
    var disables = 0
    var enableSucceeds = true
    var onUpdate: (@MainActor (_ completion: @escaping @Sendable () -> Void) -> Void)?

    func requestStepReadAccess() async -> Bool { requests += 1; return true }
    func startObserving(_ onUpdate: @escaping @MainActor (_ completion: @escaping @Sendable () -> Void) -> Void) {
        starts += 1
        self.onUpdate = onUpdate
    }
    func stopObserving() { stops += 1; onUpdate = nil }
    func enableBackgroundDelivery() async -> Bool { enables += 1; return enableSucceeds }
    func disableBackgroundDelivery() async { disables += 1 }
}

/// Counts HealthKit completion calls from any context.
private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func call() { lock.lock(); value += 1; lock.unlock() }
}

@MainActor
final class HelioHealthWakeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var strapChosen = true

    override func setUp() {
        super.setUp()
        suiteName = "HelioHealthWakeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        strapChosen = true
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func make(_ fake: FakeStepDelivery,
                      wake: @escaping @MainActor (_ done: @escaping @MainActor () -> Void) -> Void = { $0() }) -> HelioHealthWake {
        HelioHealthWake(control: fake, defaults: defaults, strapChosen: { [unowned self] in self.strapChosen }, wake: wake)
    }

    // MARK: Decision

    func testOnlyAStrapUserWhoTurnedItOnIsObserved() {
        XCTAssertTrue(HelioHealthWake.shouldObserve(strapChosen: true, enabled: true))
        XCTAssertFalse(HelioHealthWake.shouldObserve(strapChosen: true, enabled: false))
        XCTAssertFalse(HelioHealthWake.shouldObserve(strapChosen: false, enabled: true), "ring chosen")
        XCTAssertFalse(HelioHealthWake.shouldObserve(strapChosen: false, enabled: false))
        XCTAssertFalse(HelioHealthWake.wasEverUsed(defaults), "a ring-only install never constructs it")
    }

    /// Launch never asks for permission. Strap + opt-in: the query and hourly delivery. Not opted in:
    /// nothing.
    func testLaunchObservesOnlyWithTheOptInAndNeverAsks() async {
        let fake = FakeStepDelivery()
        await make(fake).configureAtLaunch().value
        XCTAssertEqual([fake.requests, fake.starts, fake.enables, fake.disables], [0, 0, 0, 0], "not opted in")

        defaults.set(true, forKey: HelioHealthWake.enabledKey)
        let wake = make(fake)
        await wake.configureAtLaunch().value
        XCTAssertEqual(fake.requests, 0, "permission only from the explicit action")
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.enables, 1)
        XCTAssertTrue(wake.isObserving)
        XCTAssertTrue(defaults.bool(forKey: HelioHealthWake.deliveryOnKey))
    }

    /// The explicit action asks once, then observes; turning it off stops the query and the delivery.
    func testTheToggleAsksOnceThenObservesAndTurningItOffStopsEverything() async {
        let fake = FakeStepDelivery()
        let wake = make(fake)
        await wake.enable()
        XCTAssertEqual(fake.requests, 1)
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.enables, 1)
        XCTAssertTrue(wake.isEnabled)
        XCTAssertTrue(HelioHealthWake.wasEverUsed(defaults))
        await wake.disable()
        XCTAssertEqual(fake.stops, 1)
        XCTAssertEqual(fake.disables, 1)
        XCTAssertFalse(wake.isEnabled)
        XCTAssertFalse(wake.isObserving)
    }

    /// A switch to the ring turns HealthKit delivery off and keeps the opt-in; a switch back observes
    /// again. A ring-chosen launch turns off a delivery left on.
    func testSwitchingToTheRingTurnsDeliveryOff() async {
        let fake = FakeStepDelivery()
        let wake = make(fake)
        await wake.enable()
        strapChosen = false
        await wake.deviceChanged()
        XCTAssertEqual(fake.stops, 1)
        XCTAssertEqual(fake.disables, 1)
        XCTAssertTrue(wake.isEnabled, "the opt-in is kept for the switch back")
        XCTAssertFalse(defaults.bool(forKey: HelioHealthWake.deliveryOnKey))
        strapChosen = true
        await wake.deviceChanged()
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.enables, 2)

        // A launch with the ring chosen and delivery left on (the app ended before the switch's turn-off).
        let other = FakeStepDelivery()
        defaults.set(true, forKey: HelioHealthWake.deliveryOnKey)
        strapChosen = false
        await make(other).configureAtLaunch().value
        XCTAssertEqual(other.disables, 1)
        XCTAssertEqual(other.starts, 0)
    }

    // MARK: The completion handler, on every path

    func testTheCompletionHandlerIsCalledOnceOnEveryPath() async {
        let fake = FakeStepDelivery()
        var wakes = 0
        // The wake calls `done` twice, as a defensive check that HealthKit still hears once.
        let wake = make(fake, wake: { done in wakes += 1; done(); done() })
        await wake.enable()
        let counter = CompletionCounter()
        fake.onUpdate? { counter.call() }
        XCTAssertEqual(counter.count, 1, "a sync ran")
        XCTAssertEqual(wakes, 1)

        strapChosen = false
        let ring = CompletionCounter()
        wake.handleUpdate { ring.call() }
        XCTAssertEqual(ring.count, 1, "ring chosen: at once, no sync")
        XCTAssertEqual(wakes, 1)

        strapChosen = true
        await wake.disable()
        let off = CompletionCounter()
        wake.handleUpdate { off.call() }
        XCTAssertEqual(off.count, 1, "turned off: at once, no sync")
        XCTAssertEqual(wakes, 1)
    }

    /// Through the real coordinator: a skip (synced minutes ago), a catch-up that finishes, and a
    /// catch-up that iOS expires all call HealthKit's completion exactly once.
    func testThroughTheCoordinatorEveryPathCompletesOnce() async {
        let state = HelioWakeState(defaults)
        var expiry: (@MainActor () -> Void)?
        var release = false
        let coordinator = HelioWakeCoordinator(.init(
            strapChosen: { true }, appIsActive: { false }, runActive: { false }, state: state,
            now: { Date(timeIntervalSince1970: 1_789_900_000) }, syncInForeground: {},
            beginAssertion: { expired in expiry = expired; return 1 }, endAssertion: { _ in },
            run: { _ in
                for _ in 0..<10_000 where !release && !Task.isCancelled { await Task.yield() }
                return HelioBackgroundRun(ending: .synced)
            },
            expire: {}, afterRun: { _ in }, note: { _, _ in }))
        let fake = FakeStepDelivery()
        let wake = make(fake, wake: { done in coordinator.wake(.healthDelivery, done: done) })
        await wake.enable()

        state.lastCompletedSync = Date(timeIntervalSince1970: 1_789_900_000 - 60)
        let skipped = CompletionCounter()
        fake.onUpdate? { skipped.call() }
        XCTAssertEqual(skipped.count, 1, "synced a minute ago: completed at once")

        state.lastCompletedSync = nil
        release = true
        let ran = CompletionCounter()
        fake.onUpdate? { ran.call() }
        for _ in 0..<5000 where ran.count == 0 { await Task.yield() }
        XCTAssertEqual(ran.count, 1, "after the catch-up")

        release = false
        let expired = CompletionCounter()
        fake.onUpdate? { expired.call() }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(expired.count, 0, "still running")
        expiry?()
        XCTAssertEqual(expired.count, 1, "iOS ended the background time: completed before suspension")
        for _ in 0..<500 { await Task.yield() }
        XCTAssertEqual(expired.count, 1, "and only once")
    }
}
