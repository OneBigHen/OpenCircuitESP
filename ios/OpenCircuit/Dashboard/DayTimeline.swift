// One day of every intraday metric, loaded from the store and shaped for the day charts (#239).
//
// The rules live in `IntradaySeries` (OpenCircuitKit); this only reads the rows:
//   • Only the device that owned each moment (decision 28): `LocalStore.ownedSamples`, and for the
//     rows that carry no device (the ring's daytime skin temperature, step rows) the owner at the
//     row's time. A catch-up one device recorded for the other's time is never drawn.
//   • Each device is its own series with its own day average (decision 29). Ring-finger and
//     strap-arm skin temperatures never share a line or an average.
//   • Ring-only installs (empty ownership log) read exactly the rows they read before #239.
//
// Loaded on demand by the view that shows it, through the store, every time it appears and every time
// a sync finishes (`SyncRevision`). Never seeded from a parent's snapshot: that froze a detail view in
// #222 (review S1).
//
// The load runs OFF the main actor (`loadAsync`), the way `TrendsData.loadAsync` does: a fresh
// `ModelContext` over the same container inside a detached task, handing this value type back. It is
// a day-bounded read (~2 900 rows), but its SQLite cost grows with the history behind it, and it
// re-runs after every finished sync while a day chart is open, so it must never be a main-thread
// hitch. Measured on disk against the full 30-day retention window (86 k rows), iPhone 17 simulator,
// three loads per run: WARM 74–177 ms for every card and 36–47 ms for a single metric (review-242b
// measured 105–150 ms and ~38 ms on its own fixture; these runs share the machine, so the spread is
// contention). A COLD first load is several times that — 284/538/732 ms here, up to ~1 s in
// review-242b. Like the trends load, the second context sees only SAVED rows, which is what every caller
// here wants: ingest and the sync hooks commit before the `.syncFinished` bump that triggers the reload.

import Foundation
import OpenCircuitKit
import SwiftData

struct DayTimeline {

    /// The metrics a day chart can show.
    enum Metric: String, CaseIterable, Hashable {
        case heartRate, hrv, spo2, respiratoryRate, skinTemp, steps, stress
    }

    /// One hour's steps from one device.
    struct StepBucket: Equatable {
        let hour: Date
        let family: DeviceOwnershipLog.Family
        let steps: Int
    }

    /// The local day `[start, start + 1 day)`.
    let day: DateInterval
    let log: DeviceOwnershipLog
    /// Display-ready values: SpO₂ in %, skin temperature in °C (the view converts the unit live).
    var series: [Metric: IntradaySeries.Day] = [:]
    var stepBuckets: [StepBucket] = []
    var stepsTotal: Int?
    var nightWindow: DateInterval?

    /// The stretches of the day each device owned (decision 28).
    var spans: [IntradaySeries.Span] { IntradaySeries.spans(of: day, log: log) }

    /// The devices that owned some of this day, in order. One ring for a ring-only install.
    var owners: [DeviceOwnershipLog.Family] {
        var out: [DeviceOwnershipLog.Family] = []
        for span in spans where !out.contains(span.family) { out.append(span.family) }
        return out
    }

    /// Stress is the strap's (#239): its card shows when the strap owned some of the day, or (after a
    /// switch back) when it still has readings. Never for a ring-only install.
    var showsStress: Bool {
        owners.contains(.zeppOS) || !(series[.stress]?.isEmpty ?? true)
    }

    /// Name the device on each card: whenever more than one device has ever been chosen. A ring-only
    /// install's cards are unchanged.
    var namesDevices: Bool { !log.isEmpty }

    func day(_ metric: Metric) -> IntradaySeries.Day {
        series[metric] ?? .empty
    }

    var isEmpty: Bool {
        series.values.allSatisfy(\.isEmpty) && stepBuckets.isEmpty && stepsTotal == nil
    }

    static func dayInterval(_ day: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// The metrics a screen showing every card needs to load, given the ownership log.
    ///
    /// Stress is the strap's, and `showsStress` can only be true when the log holds a strap entry: a
    /// day's owners come from the same log, and stress rows only ever exist for time the strap owned
    /// (they are ingested through the ownership filter). So a ring-only install skips that fetch
    /// entirely and still renders exactly the cards it rendered before (review-242 SF-2).
    static func metricsToLoad(log: DeviceOwnershipLog) -> Set<Metric> {
        var out: Set<Metric> = [.heartRate, .hrv, .spo2, .respiratoryRate, .skinTemp, .steps]
        if log.entries.contains(where: { $0.family == .zeppOS }) { out.insert(.stress) }
        return out
    }

    /// Read `metrics` for the local day containing `day`, off the main actor.
    ///
    /// The ownership log is snapshotted on the main actor (it is `@MainActor`-isolated state) and
    /// passed in, so the detached work touches nothing main-isolated — the `TrendsData.loadAsync`
    /// rule. Cancellation is cooperative: the caller checks `Task.isCancelled` before publishing, so
    /// a superseded day's result is dropped rather than drawn over a newer one.
    static func loadAsync(container: ModelContainer, day: Date,
                          metrics: Set<Metric> = Set(Metric.allCases),
                          calendar: Calendar = .current) async -> DayTimeline {
        let log = await MainActor.run { LocalStore.ownershipLog() }
        return await Task.detached {
            fetch(container: container, day: day, metrics: metrics, calendar: calendar, log: log)
        }.value
    }

    /// Every card a full day screen shows, off the main actor: `metricsToLoad(log:)` for this install.
    static func loadAsync(container: ModelContainer, day: Date,
                          calendar: Calendar = .current) async -> DayTimeline {
        let log = await MainActor.run { LocalStore.ownershipLog() }
        let metrics = metricsToLoad(log: log)
        return await Task.detached {
            fetch(container: container, day: day, metrics: metrics, calendar: calendar, log: log)
        }.value
    }

    /// The off-main read itself: a fresh `ModelContext` over `container`, the rows for one day, and the
    /// pure shaping in `IntradaySeries`. Every fetch goes through `LocalStore`'s own `nonisolated`
    /// descriptors and ownership filters, never a hand-copied predicate, so this can't diverge from
    /// what the main-actor store would return.
    nonisolated static func fetch(container: ModelContainer, day: Date, metrics: Set<Metric>,
                                  calendar: Calendar, log: DeviceOwnershipLog) -> DayTimeline {
        let context = ModelContext(container)
        let interval = dayInterval(day, calendar: calendar)
        var out = DayTimeline(day: interval, log: log)
        let from = interval.start, to = interval.end

        func owned(_ kind: MetricKind, minValue: Double = 0, scale: Double = 1) -> IntradaySeries.Day {
            let samples = (try? LocalStore.ownedSamples(in: context, kind: kind, from: from, to: to, log: log)) ?? []
            let points = samples.filter { $0.value > minValue }
                .map { IntradaySeries.Point(time: $0.start, value: $0.value * scale) }
            return IntradaySeries.day(points, day: interval, log: log)
        }

        for metric in metrics {
            switch metric {
            case .heartRate: out.series[.heartRate] = owned(.heartRate, minValue: TrendsEngine.minValidHR)
            case .hrv: out.series[.hrv] = owned(.hrvSDNN)
            case .spo2: out.series[.spo2] = owned(.spo2, scale: 100)
            case .respiratoryRate: out.series[.respiratoryRate] = owned(.respiratoryRate)
            case .stress:
                // 0 is a real stress level (fully relaxed), not "no reading": keep it.
                out.series[.stress] = owned(.stress, minValue: -1)
            case .skinTemp:
                out.series[.skinTemp] = IntradaySeries.day(
                    skinTemperatures(context: context, interval: interval, log: log), day: interval, log: log)
            case .steps:
                let rows = (try? context.fetch(LocalStore.stepSamplesDescriptor(from: from, to: to))) ?? []
                out.stepBuckets = hourlySteps(rows.map { (start: $0.start, end: $0.end, delta: $0.delta) },
                                              log: log, calendar: calendar)
                let dailies = (try? context.fetch(LocalStore.recentDailiesDescriptor(limit: 60))) ?? []
                out.stepsTotal = dailies.first { calendar.isDate($0.day, inSameDayAs: from) }?.steps
            }
        }

        // Shade the night's in-bed window if this day is (or starts) a stored sleep night.
        let summaries = (try? context.fetch(LocalStore.recentSleepSummariesDescriptor(limit: 60))) ?? []
        if let s = summaries.first(where: { calendar.isDate($0.night, inSameDayAs: from) }), s.inBedEnd > s.inBedStart {
            out.nightWindow = DateInterval(start: s.inBedStart, end: s.inBedEnd)
        }
        return out
    }

    /// The day's skin temperatures, each device's own:
    ///   • the ring's daytime readings (`StoredDaytimeTemp`, ring-only rows with no device column), for
    ///     the time the ring owned. With an empty log that is every row, exactly as before #239;
    ///   • the strap's stored (sleep-window, worn) readings for the time it owned. A ring-only install
    ///     never reads these: its nightly `.temperature` rows were never on this chart.
    nonisolated private static func skinTemperatures(context: ModelContext, interval: DateInterval,
                                                     log: DeviceOwnershipLog) -> [IntradaySeries.Point] {
        let descriptor = LocalStore.daytimeTemperaturesDescriptor(from: interval.start, to: interval.end)
        let ring = ((try? context.fetch(descriptor)) ?? [])
            .filter { log.owner(at: $0.time) == .ringConn && $0.celsius > 0 }
            .map { IntradaySeries.Point(time: $0.time, value: $0.celsius) }
        guard log.entries.contains(where: { $0.family == .zeppOS }) else { return ring }
        let strap = ((try? LocalStore.ownSamples(in: context, kind: .temperature, from: interval.start,
                                                 to: interval.end, of: .zeppOS, log: log)) ?? [])
            .filter { $0.value > 0 }
            .map { IntradaySeries.Point(time: $0.start, value: $0.value) }
        return ring + strap
    }

    /// Step rows summed per hour they LANDED in (`end`) and per device. A row lies wholly in its
    /// device's time (decision 28b), so its device is the owner at its start. With an empty log every
    /// row is the ring's and this is the pre-#239 hourly sum.
    static func hourlySteps(_ rows: [(start: Date, end: Date, delta: Int)], log: DeviceOwnershipLog,
                            calendar: Calendar = .current) -> [StepBucket] {
        struct Key: Hashable { let hour: Date; let family: DeviceOwnershipLog.Family }
        var sums: [Key: Int] = [:]
        for row in rows where row.delta > 0 {
            let hour = calendar.dateInterval(of: .hour, for: row.end)?.start ?? row.end
            sums[Key(hour: hour, family: log.owner(at: row.start)), default: 0] += row.delta
        }
        return sums.map { StepBucket(hour: $0.key.hour, family: $0.key.family, steps: $0.value) }
            .sorted { ($0.hour, $0.family.rawValue) < ($1.hour, $1.family.rawValue) }
    }
}

extension DeviceOwnershipLog.Family {
    /// The device's name on a chart: the same words as the device picker.
    var deviceName: String {
        switch self {
        case .ringConn: return ActiveDeviceChoice.ringConn.displayName
        case .zeppOS: return ActiveDeviceChoice.helioStrap.displayName
        }
    }
}
