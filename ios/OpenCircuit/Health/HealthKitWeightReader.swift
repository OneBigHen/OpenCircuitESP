// HealthKitWeightReader.swift — reads the latest body mass from Apple Health (#284, decision 63) so a
// weight logged on a scale app or in Health can feed the calorie / VO₂ max math when it is newer than
// the Profile entry. READ-ONLY: nothing is ever written to Health for weight.
//
// ⚠️ SAME ISOLATION AS `VO2MaxHealthWriter`, AND FOR THE SAME REASON (build 50 / #129 / #210: two
// authorization requests that disagree about one type cost testers a grant they already gave). This
// request names exactly one type, `bodyMass`, in `read`, with an EMPTY share set, and `bodyMass` is in
// NEITHER of the main request's sets, so no type ever appears in two requests. Both halves are pinned:
//   • `HealthKitAuthorizationSurfaceTests.testTheLazyBodyMassRequestNamesOnlyBodyMass` (Kit, source audit)
//     allows this file one request, requires it to read only `bodyMassType` and share nothing, and
//     forbids the bodyMass HealthKit type anywhere else in the app;
//   • `HealthKitShareTypesTests.testBodyMassStaysOutOfTheMainRequest` (app) asserts `bodyMass` is in
//     neither `allTypes` nor `authorizationReadTypes`.
// It also stays out of `allTypes` so the #129 upgrade probe never prompts an install at launch.
//
// LAZY: asked the first time the Calories card is on screen, never at launch, never before the user
// has connected Apple Health (the heart-rate share probe), so the sheet is not the first Health prompt
// they see. ASKED AT MOST ONCE per install (`askedKey`), so a decline cannot become a prompt loop.
// HealthKit hides READ status for privacy: "denied", "never asked" and "no sample" all look like an
// empty result, and all of them mean the same thing here — the manual weight keeps being used.
//
// What has NOT been observed: this request running on a device that already holds the main grant.
// The PR asks for that on-phone check (grant body mass, then confirm Workouts and Heart Rate are still
// on in Health ▸ Sharing ▸ Apps ▸ OpenCircuit).

import Foundation
import HealthKit
import OpenCircuitKit

@MainActor
struct HealthKitWeightReader {
    /// The one type this reader asks for. Named once so the source audit can pin the request to it.
    static let bodyMassType = HKQuantityType(.bodyMass)

    /// UserDefaults flag: the body-mass sheet was already requested once on this install.
    static let askedKey = "weightFromHealth.asked.v1"

    private let store = HKHealthStore()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Refresh the cached latest body mass (`WeightResolver.Keys.healthKg` / `.healthAt`). Never throws
    /// and never blocks the caller on anything but the query: every failure leaves the cache cleared or
    /// untouched and the manual weight in charge.
    func refreshCache() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        // Not connected to Health at all: no body-mass sheet out of context.
        guard HealthKitWriter().isShareAuthorized else { return }

        if !defaults.bool(forKey: Self.askedKey) {
            let status = try? await store.statusForAuthorizationRequest(toShare: [], read: [Self.bodyMassType])
            guard status == .shouldRequest || status == .unnecessary else { return }
            defaults.set(true, forKey: Self.askedKey)
            if status == .shouldRequest {
                do {
                    try await store.requestAuthorization(toShare: [], read: [Self.bodyMassType])
                } catch {
                    return
                }
            }
        }

        let sample = await latestSample()
        if let sample {
            defaults.set(sample.kg, forKey: WeightResolver.Keys.healthKg)
            defaults.set(sample.date.timeIntervalSince1970, forKey: WeightResolver.Keys.healthAt)
        } else {
            // No sample, or read access off (HealthKit returns an empty result for both): forget any
            // earlier cache so a revoked grant stops steering the math.
            defaults.removeObject(forKey: WeightResolver.Keys.healthKg)
            defaults.removeObject(forKey: WeightResolver.Keys.healthAt)
        }
    }

    private func latestSample() async -> WeightResolver.HealthSample? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: Self.bodyMassType, predicate: nil, limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                guard error == nil, let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: WeightResolver.HealthSample(
                    kg: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    date: sample.endDate))
            }
            store.execute(query)
        }
    }
}
