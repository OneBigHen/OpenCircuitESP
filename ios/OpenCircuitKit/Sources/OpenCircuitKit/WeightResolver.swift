import Foundation

/// Which body weight the calorie / VO₂ max math uses (#284, decision 63): the manual Profile entry or
/// the latest body-mass sample the user has in Apple Health, whichever is NEWER.
///
/// Pure and clock-free so every branch is testable with synthetic dates.
public enum WeightResolver {
    public enum Source: Equatable, Sendable {
        case manual
        case appleHealth
    }

    public struct Resolved: Equatable, Sendable {
        public let kg: Double
        public let source: Source
        /// When the winning value was set or measured; nil when a manual weight was never timestamped.
        public let date: Date?
    }

    /// A latest Apple Health body-mass sample (kilograms) and when it was taken.
    public struct HealthSample: Equatable, Sendable {
        public let kg: Double
        public let date: Date
        public init(kg: Double, date: Date) {
            self.kg = kg
            self.date = date
        }
    }

    /// Smallest and largest weight accepted from Health. Anything outside is treated as no sample,
    /// so a stray zero or a unit slip can never reach the calorie math.
    public static let plausibleKg: ClosedRange<Double> = 20...500

    /// - Parameters:
    ///   - manualKg: the Profile field's value (its default when never edited).
    ///   - manualSetAt: when the user last edited the field. nil = never stamped: either never
    ///     edited (the value is just the default) or edited before this stamp existed. Both are
    ///     treated as "older than any Health sample", so a real measurement beats an unknown date.
    ///   - health: the latest Apple Health sample, or nil when there is none, access was never
    ///     granted or was denied (HealthKit does not tell those apart for reads, and does not need to).
    ///
    /// Apple Health wins only when its sample date is STRICTLY newer than `manualSetAt`. On an exact
    /// tie the manual value wins: it is the number the user can see and edit on the Profile page, and
    /// a tie is far likelier to be the same weigh-in typed in twice than a newer one.
    public static func resolve(manualKg: Double, manualSetAt: Date?,
                               health: HealthSample?) -> Resolved {
        let manual = Resolved(kg: manualKg, source: .manual, date: manualSetAt)
        guard let health, plausibleKg.contains(health.kg) else { return manual }
        guard let manualSetAt else {
            return Resolved(kg: health.kg, source: .appleHealth, date: health.date)
        }
        return health.date > manualSetAt
            ? Resolved(kg: health.kg, source: .appleHealth, date: health.date)
            : manual
    }

    /// UserDefaults keys. The manual pair lives with the Profile page's other `userProfile.*` keys;
    /// the Health pair is a cache of the reader's last result, so the cards resolve with no query.
    public enum Keys {
        public static let manualKg = "userProfile.weightKg"
        public static let manualSetAt = "userProfile.weightKg.lastSetAt"
        public static let healthKg = "userProfile.weightKg.health"
        public static let healthAt = "userProfile.weightKg.health.at"
    }

    /// Dates are stored as `timeIntervalSince1970`; 0 means "absent" (what `@AppStorage` defaults to).
    public static func resolve(manualKg: Double, manualSetAtEpoch: Double,
                               healthKg: Double, healthAtEpoch: Double) -> Resolved {
        resolve(manualKg: manualKg,
                manualSetAt: manualSetAtEpoch > 0 ? Date(timeIntervalSince1970: manualSetAtEpoch) : nil,
                health: healthAtEpoch > 0
                    ? HealthSample(kg: healthKg, date: Date(timeIntervalSince1970: healthAtEpoch)) : nil)
    }

    /// Same, reading the four keys from `defaults` (the non-view call sites).
    public static func resolve(defaults: UserDefaults) -> Resolved {
        resolve(manualKg: defaults.object(forKey: Keys.manualKg) as? Double ?? 70,
                manualSetAtEpoch: defaults.double(forKey: Keys.manualSetAt),
                healthKg: defaults.double(forKey: Keys.healthKg),
                healthAtEpoch: defaults.double(forKey: Keys.healthAt))
    }
}
