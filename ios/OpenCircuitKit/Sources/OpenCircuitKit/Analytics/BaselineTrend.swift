// Baseline trend (#216) — where the latest daily value of a metric sits against the user's OWN
// recent history, for the Today tab's metric tiles.
//
// Deliberately simple and honest: the baseline is the mean of the prior days in the series (the
// tiles pass the trailing 14 days), the latest value is compared to it with a deadband, and the
// answer is `nil` — "still building a baseline" — until enough prior days exist. It never fills
// gaps, never extrapolates, and never scores anything: it only says above / within / below.
//
// The deadband is the LARGER of a per-metric absolute floor (so a tiny spread can't make ordinary
// noise read as a change) and half the baseline's standard deviation (so a naturally noisy metric
// needs a proportionally bigger move). This is a display heuristic, not the Vitals Status
// classifier (`VitalsBaseline`), which stays the one place that flags anomalies.

import Foundation

public enum BaselineTrend {

    public enum Direction: String, Equatable, Sendable { case above, within, below }

    /// One dated daily value. Callers pass one point per day, oldest first or in any order.
    public struct Point: Equatable, Sendable {
        public let date: Date
        public let value: Double
        public init(date: Date, value: Double) { self.date = date; self.value = value }
    }

    public struct Result: Equatable, Sendable {
        /// The newest value in the series and its day.
        public let latest: Point
        /// Mean of the prior days; nil when there are none.
        public let baselineMean: Double?
        /// How many prior days the baseline was built from.
        public let baselineDays: Int
        /// nil while the baseline is still too thin to judge (fewer than `minBaselineDays`).
        public let direction: Direction?
        /// `latest.value - baselineMean`, or nil without a baseline.
        public var delta: Double? { baselineMean.map { latest.value - $0 } }
    }

    /// Default number of prior days required before a direction is reported.
    public static let defaultMinBaselineDays = 4

    /// Compare the newest point against the mean of the others. Returns nil for an empty series.
    /// Non-finite values are dropped rather than trusted.
    public static func evaluate(_ series: [Point],
                                minAbsoluteDelta: Double,
                                minBaselineDays: Int = defaultMinBaselineDays,
                                sdFraction: Double = 0.5) -> Result? {
        let clean = series.filter { $0.value.isFinite }.sorted { $0.date < $1.date }
        guard let latest = clean.last else { return nil }
        let prior = clean.dropLast().map(\.value)
        guard !prior.isEmpty else {
            return Result(latest: latest, baselineMean: nil, baselineDays: 0, direction: nil)
        }
        let mean = prior.reduce(0, +) / Double(prior.count)
        guard prior.count >= max(minBaselineDays, 1) else {
            return Result(latest: latest, baselineMean: mean, baselineDays: prior.count, direction: nil)
        }
        let variance = prior.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(prior.count)
        let band = max(abs(minAbsoluteDelta), sdFraction * variance.squareRoot())
        let delta = latest.value - mean
        let direction: Direction = delta > band ? .above : (delta < -band ? .below : .within)
        return Result(latest: latest, baselineMean: mean, baselineDays: prior.count, direction: direction)
    }
}
