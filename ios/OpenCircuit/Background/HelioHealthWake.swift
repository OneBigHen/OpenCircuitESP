import Foundation
import HealthKit

// Decision 33 (#233): HealthKit background delivery of the iPhone's own step count is a second wake
// for strap users, and after decision 35 the only one that doesn't depend on the strap. When the
// iPhone counts new steps (someone walks around with it), HealthKit launches or wakes the app at most
// hourly and calls the observer query's handler; that handler runs one bounded strap sync (wake reason
// `healthDelivery`) through `HelioWakeCoordinator`, and calls HealthKit's completion handler on every
// path (HealthKit backs off, then stops delivering, to an app that doesn't).
//
// An entitlement (`com.apple.developer.healthkit.background-delivery`), not a background mode, so
// decision 26 holds. Strap only: ring-only users never construct this or touch HealthKit for it. The
// read permission is asked for only from an explicit action on the strap's device screen.

/// What the Health delivery wake needs from HealthKit; `HealthKitStepDelivery` in the app, a fake in
/// the tests.
@MainActor
protocol StepDeliveryControlling: AnyObject {
    /// Ask to read the iPhone's step count (the system sheet). true when the request completed;
    /// HealthKit never says whether read access was granted.
    func requestStepReadAccess() async -> Bool
    /// Start the observer query. `onUpdate` gets HealthKit's completion handler, which must be called.
    func startObserving(_ onUpdate: @escaping @MainActor (_ completion: @escaping @Sendable () -> Void) -> Void)
    func stopObserving()
    func enableBackgroundDelivery() async -> Bool
    func disableBackgroundDelivery() async
}

@MainActor
final class HelioHealthWake {
    /// The person turned "Sync in the background more reliably" on.
    nonisolated static let enabledKey = "helio.healthDeliveryWake.enabled.v1"
    /// Background delivery is enabled in HealthKit (so a switch to the ring knows to turn it off).
    nonisolated static let deliveryOnKey = "helio.healthDeliveryWake.deliveryOn.v1"

    static let shared = HelioHealthWake(
        control: HealthKitStepDelivery(), defaults: .standard,
        strapChosen: { ActiveDeviceChoiceStore.persisted() == .helioStrap },
        wake: { done in HelioWakeCoordinator.shared.wake(.healthDelivery, done: done) })

    private let control: any StepDeliveryControlling
    private let defaults: UserDefaults
    private let strapChosen: @MainActor () -> Bool
    private let wake: @MainActor (_ done: @escaping @MainActor () -> Void) -> Void
    private(set) var isObserving = false

    init(control: any StepDeliveryControlling, defaults: UserDefaults, strapChosen: @escaping @MainActor () -> Bool,
         wake: @escaping @MainActor (_ done: @escaping @MainActor () -> Void) -> Void) {
        self.control = control
        self.defaults = defaults
        self.strapChosen = strapChosen
        self.wake = wake
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The decision: observe the iPhone's steps only with the strap chosen and the person's opt-in.
    nonisolated static func shouldObserve(strapChosen: Bool, enabled: Bool) -> Bool { strapChosen && enabled }

    /// At launch (HealthKit relaunches the app for a delivery, so the query must be set up during
    /// launch every time, synchronously): observe with the strap chosen and the opt-in on; with the ring
    /// chosen, turn off a delivery left on. Never asks for permission. Returns the HealthKit
    /// bookkeeping that follows (enabling or disabling delivery), for tests to await.
    @discardableResult
    func configureAtLaunch() -> Task<Void, Never> {
        if Self.shouldObserve(strapChosen: strapChosen(), enabled: isEnabled) {
            startQuery()
            return Task { await self.enableDelivery() }
        }
        return Task { await self.stop() }
    }

    /// The explicit action: ask to read steps, then observe. The answer isn't knowable (HealthKit hides
    /// read access); without it the query simply never fires.
    func enable() async {
        defaults.set(true, forKey: Self.enabledKey)
        _ = await control.requestStepReadAccess()
        guard Self.shouldObserve(strapChosen: strapChosen(), enabled: isEnabled) else { return }
        startQuery()
        await enableDelivery()
    }

    func disable() async {
        defaults.set(false, forKey: Self.enabledKey)
        await stop()
    }

    /// `DeviceSwitcher`: on to the strap, observe again if the opt-in is on; off to the ring, turn
    /// delivery off (the opt-in is kept for the next switch back).
    func deviceChanged() async {
        await configureAtLaunch().value
    }

    /// Whether anything about this wake was ever set up: a ring-only install has neither key, so its
    /// launch and device switches never construct `shared`.
    nonisolated static func wasEverUsed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey) || defaults.bool(forKey: deliveryOnKey)
    }

    /// HealthKit's update: one bounded strap sync. `completion` is called exactly once, on every path.
    func handleUpdate(_ completion: @escaping @Sendable () -> Void) {
        var called = false
        let finish: @MainActor () -> Void = {
            guard !called else { return }
            called = true
            completion()
        }
        guard Self.shouldObserve(strapChosen: strapChosen(), enabled: isEnabled) else { return finish() }
        wake(finish)
    }

    private func startQuery() {
        guard !isObserving else { return }
        isObserving = true
        control.startObserving { [weak self] completion in
            guard let self else { return completion() }
            self.handleUpdate(completion)
        }
    }

    private func enableDelivery() async {
        if await control.enableBackgroundDelivery() { defaults.set(true, forKey: Self.deliveryOnKey) }
    }

    private func stop() async {
        if isObserving {
            isObserving = false
            control.stopObserving()
        }
        if defaults.bool(forKey: Self.deliveryOnKey) {
            await control.disableBackgroundDelivery()
            defaults.set(false, forKey: Self.deliveryOnKey)
        }
    }
}

/// The app's HealthKit side: an observer query on the iPhone's step count and hourly background
/// delivery for it.
@MainActor
final class HealthKitStepDelivery: StepDeliveryControlling {
    private let store = HKHealthStore()
    private let steps = HKQuantityType(.stepCount)
    private var query: HKObserverQuery?

    func requestStepReadAccess() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [steps])
            return true
        } catch {
            return false
        }
    }

    func startObserving(_ onUpdate: @escaping @MainActor (_ completion: @escaping @Sendable () -> Void) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(), query == nil else { return }
        let query = HKObserverQuery(sampleType: steps, predicate: nil) { _, completion, error in
            // HealthKit's queue. An error still gets its completion call, and nothing runs.
            guard error == nil else { return completion() }
            // HealthKit's completion handler may be called from any thread.
            let done = HealthKitCompletion(call: completion)
            Task { @MainActor in onUpdate { done.call() } }
        }
        store.execute(query)
        self.query = query
    }

    func stopObserving() {
        if let query { store.stop(query) }
        query = nil
    }

    func enableBackgroundDelivery() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.enableBackgroundDelivery(for: steps, frequency: .hourly)
            return true
        } catch {
            return false
        }
    }

    func disableBackgroundDelivery() async {
        try? await store.disableBackgroundDelivery(for: steps)
    }
}

/// HealthKit's observer-query completion handler, which HealthKit lets any thread call.
private struct HealthKitCompletion: @unchecked Sendable {
    let call: () -> Void
}
