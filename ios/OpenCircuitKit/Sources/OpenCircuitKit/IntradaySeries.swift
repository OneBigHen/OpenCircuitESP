// One metric through one day, ready to chart (#239): which device owned each stretch of the day,
// the readings bucketed so a strap's per-minute data stays readable, the line broken wherever a
// bucket is empty, and one day average per device.
//
// The rules it carries:
//   • Decision 28 (device ownership of time): the day is cut into the stretches each device owned
//     (`spans`). A reading belongs to the stretch its time falls in, so two devices' lines meet at a
//     switch and never overlap. The caller passes OWNED readings (`LocalStore.ownedSamples`); a
//     reading is never moved to the other device's stretch.
//   • Decision 29 (baselines are per device): the day average is per device (`Day.averages`), and a
//     ring-finger and a strap-arm reading never share one.
//   • Never bridge a gap: a bucket with no readings ends the line (`runs`). A strap off charging for
//     an hour is a hole in the chart, not a straight line across it.
//
// Pure value types over `Date`/`Double`, so every rule is covered by `swift test` without a store.

import Foundation

public enum IntradaySeries {

    /// One reading at its own time, in display units.
    public struct Point: Equatable, Sendable {
        public let time: Date
        public let value: Double

        public init(time: Date, value: Double) {
            self.time = time
            self.value = value
        }
    }

    /// A stretch of the day one device family owned, half-open `[start, end)`.
    public struct Span: Equatable, Sendable {
        public let family: DeviceOwnershipLog.Family
        public let start: Date
        public let end: Date

        public init(family: DeviceOwnershipLog.Family, start: Date, end: Date) {
            self.family = family
            self.start = start
            self.end = end
        }

        public func contains(_ t: Date) -> Bool { start <= t && t < end }
    }

    /// The readings of one bucket, half-open `[start, end)`. Never empty: a bucket with no reading
    /// is not a bucket, it is a gap.
    public struct Bucket: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let min: Double
        public let max: Double
        public let mean: Double
        public let count: Int

        /// Where the bucket is drawn on the time axis.
        public var mid: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    }

    /// One device's line over one stretch of the day.
    public struct Series: Equatable, Sendable {
        public let span: Span
        /// The stretch's readings, oldest first: what touch-to-scrub reads exact values from.
        public let points: [Point]
        public let bucketWidth: TimeInterval
        public let buckets: [Bucket]
        /// `buckets` cut at every empty bucket: each run is one unbroken line (a single-bucket run is
        /// a dot).
        public let runs: [[Bucket]]

        public var family: DeviceOwnershipLog.Family { span.family }
    }

    /// A metric's day: one series per owned stretch (oldest first), and each device's average.
    public struct Day: Equatable, Sendable {
        public let series: [Series]
        /// Mean of the device's readings over all its stretches of the day (decision 29). A device
        /// with no readings has no entry.
        public let averages: [DeviceOwnershipLog.Family: Double]

        public var points: [Point] { series.flatMap(\.points) }
        public var isEmpty: Bool { series.allSatisfy { $0.points.isEmpty } }
        /// The devices with readings this day, in the order they first appear.
        public var families: [DeviceOwnershipLog.Family] {
            var out: [DeviceOwnershipLog.Family] = []
            for s in series where !s.points.isEmpty && !out.contains(s.family) { out.append(s.family) }
            return out
        }
    }

    // MARK: Ownership (decision 28)

    /// `day` cut into the stretches each device owned, oldest first. They tile `day` exactly: each
    /// starts where the previous ends. A switch at `t` ends one stretch and starts the next at `t`.
    /// With an empty log, one ring stretch.
    public static func spans(of day: DateInterval, log: DeviceOwnershipLog) -> [Span] {
        var cuts = [day.start]
        for entry in log.entries where entry.since > day.start && entry.since < day.end { cuts.append(entry.since) }
        cuts.append(day.end)
        var out: [Span] = []
        for i in 0..<(cuts.count - 1) where cuts[i + 1] > cuts[i] {
            let family = log.owner(at: cuts[i])
            // Two entries can name the same family back to back only if one is a no-op; merge them.
            if let last = out.last, last.family == family {
                out[out.count - 1] = Span(family: family, start: last.start, end: cuts[i + 1])
            } else {
                out.append(Span(family: family, start: cuts[i], end: cuts[i + 1]))
            }
        }
        return out
    }

    // MARK: Buckets

    /// The bucket widths a series may use, narrowest first.
    public static let widths: [TimeInterval] = [5, 10, 15, 20, 30, 60].map { $0 * 60 }

    /// The narrowest of `widths` at least twice the series' own median spacing, so a device reading
    /// at its usual cadence (with jitter under half a step) leaves no bucket empty, and an empty
    /// bucket really is a gap. A per-minute strap gets 5 minutes; a 5-minute cadence gets 10.
    /// Sparser than every 30 minutes: an hour. Fewer than two readings: the narrowest.
    public static func bucketWidth(for times: [Date]) -> TimeInterval {
        let sorted = times.sorted()
        var gaps: [TimeInterval] = []
        for i in sorted.indices.dropFirst() {
            let gap = sorted[i].timeIntervalSince(sorted[i - 1])
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return widths[0] }
        gaps.sort()
        let median = gaps[gaps.count / 2]
        return widths.first { $0 >= 2 * median } ?? widths[widths.count - 1]
    }

    /// `points` in buckets of `width` on a grid aligned to `origin` (the day's start), each bucket
    /// clipped to `span` (so the bucket a switch lands in is split at the switch). Points outside
    /// `span` are ignored. Only buckets with readings are returned, oldest first.
    public static func buckets(_ points: [Point], in span: Span, width: TimeInterval, origin: Date) -> [Bucket] {
        guard width > 0 else { return [] }
        var groups: [Int: [Double]] = [:]
        for p in points where span.contains(p.time) {
            let index = Int((p.time.timeIntervalSince(origin) / width).rounded(.down))
            groups[index, default: []].append(p.value)
        }
        return groups.keys.sorted().compactMap { index in
            guard let values = groups[index], let lo = values.min(), let hi = values.max() else { return nil }
            let start = max(origin.addingTimeInterval(Double(index) * width), span.start)
            let end = min(origin.addingTimeInterval(Double(index + 1) * width), span.end)
            return Bucket(start: start, end: end, min: lo, max: hi,
                          mean: values.reduce(0, +) / Double(values.count), count: values.count)
        }
    }

    /// `buckets` (oldest first) cut wherever one bucket doesn't end where the next starts: an empty
    /// bucket between them is a gap, and the line never bridges it.
    public static func runs(_ buckets: [Bucket]) -> [[Bucket]] {
        var out: [[Bucket]] = []
        for bucket in buckets {
            if let last = out.last?.last, last.end == bucket.start {
                out[out.count - 1].append(bucket)
            } else {
                out.append([bucket])
            }
        }
        return out
    }

    // MARK: The day

    /// `points` over `day`: one series per owned stretch, each bucketed at its own device's cadence
    /// (`bucketWidth`, unless `width` is given), plus each device's day average over its readings.
    /// Points outside `day` are ignored.
    public static func day(_ points: [Point], day: DateInterval, log: DeviceOwnershipLog,
                           width: TimeInterval? = nil) -> Day {
        let sorted = points.filter { day.start <= $0.time && $0.time < day.end }.sorted { $0.time < $1.time }
        var series: [Series] = []
        var sums: [DeviceOwnershipLog.Family: (total: Double, count: Int)] = [:]
        for span in spans(of: day, log: log) {
            let own = sorted.filter { span.contains($0.time) }
            let w = width ?? bucketWidth(for: own.map(\.time))
            let b = buckets(own, in: span, width: w, origin: day.start)
            series.append(Series(span: span, points: own, bucketWidth: w, buckets: b, runs: runs(b)))
            for p in own {
                let sum = sums[span.family] ?? (0, 0)
                sums[span.family] = (sum.total + p.value, sum.count + 1)
            }
        }
        var averages: [DeviceOwnershipLog.Family: Double] = [:]
        for (family, sum) in sums where sum.count > 0 { averages[family] = sum.total / Double(sum.count) }
        return Day(series: series, averages: averages)
    }

    /// The reading nearest `time`, across every series of `day`: touch-to-scrub's exact value.
    public static func nearest(to time: Date, in day: Day) -> (point: Point, family: DeviceOwnershipLog.Family)? {
        var best: (point: Point, family: DeviceOwnershipLog.Family)?
        for s in day.series {
            for p in s.points {
                if let b = best, abs(b.point.time.timeIntervalSince(time)) <= abs(p.time.timeIntervalSince(time)) { continue }
                best = (p, s.family)
            }
        }
        return best
    }
}
