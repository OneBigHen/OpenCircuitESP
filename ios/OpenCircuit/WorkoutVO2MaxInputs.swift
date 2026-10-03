// WorkoutVO2MaxInputs.swift — the app-side inputs of `VO2MaxEstimate` (#232), shared by the ring's
// workout (`WorkoutSessionManager.stop()`) and the strap's (`StrapWorkoutRecorder.end()`), so the two
// devices' runs are estimated from exactly the same route reduction, age and resting heart rate
// (docs/TRAINING_METRICS.md §2.2). The estimate itself is pure, in OpenCircuitKit.

import CoreLocation
import Foundation
import OpenCircuitKit

@MainActor
enum WorkoutVO2MaxInputs {

    /// The GPS fixes as cumulative distance: the same running sum as the workout's distance.
    ///
    /// `pauses` (the strap's workout, #227): a step between two fixes that straddle a pause adds no
    /// distance, as `StrapWorkoutLocation` adds none across one. No fix is stored while paused, so
    /// such a step is also longer than `VO2MaxEstimate.maxFixGap` for any real pause and never feeds
    /// a minute's speed; this keeps the sum equal to the distance the summary shows. The ring's
    /// workout has no pause, so it passes none and the sum is unchanged.
    static func routePoints(_ route: [CLLocation], pauses: [DateInterval] = []) -> [VO2MaxEstimate.RoutePoint] {
        var points: [VO2MaxEstimate.RoutePoint] = []
        var cumulative = 0.0
        var previous: CLLocation?
        for location in route {
            if let previous {
                let crossesPause = pauses.contains {
                    $0.start >= previous.timestamp && $0.start < location.timestamp
                }
                if !crossesPause { cumulative += location.distance(from: previous) }
            }
            previous = location
            let hasAltitude = location.verticalAccuracy > 0
            points.append(VO2MaxEstimate.RoutePoint(
                time: location.timestamp, distance: cumulative,
                altitude: hasAltitude ? location.altitude : nil,
                verticalAccuracy: hasAltitude ? location.verticalAccuracy : nil))
        }
        return points
    }

    /// The age only if the user set one: the profile's 35 placeholder is not an age.
    static func storedAge(_ defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: "userProfile.age") as? Int
    }

    /// The resting-HR input: daily resting HR from the stored heart-rate history (every device's
    /// rows, as the ring's workout has always read them), leaving out the workout's own window.
    static func restingHR(store: LocalStore, start: Date, end: Date) -> Double? {
        let since = start.addingTimeInterval(-9 * 86_400)
        let history = (try? store.recentSamples(kind: .heartRate, since: since)) ?? []
        return restingHR(history: history, start: start, end: end)
    }

    /// `restingHR(store:start:end:)` over rows already fetched (tested without SwiftData).
    static func restingHR(history: [QuantitySample], start: Date, end: Date) -> Double? {
        let window = start ... max(start, end)
        let hr = history
            .filter { !window.contains($0.start) }
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        return VO2MaxEstimate.restingHR(daily: RestingHR.dailyValues(hr: hr), runStart: start)
    }
}
