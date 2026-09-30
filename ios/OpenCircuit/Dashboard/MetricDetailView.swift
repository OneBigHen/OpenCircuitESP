// A Today metric's trend screen (#216): the tile's metric over 14 or 30 days, with the personal
// usual range as a band, the headline value and its delta, min / average / max, and plain notes on
// what the number is and how "usual" is worked out.
//
// From the Today tab, the 14-day view is built from that tab's own trends load, handed in, so it IS
// the data the tile was built from and costs no second read; only the 30-day range then loads its own
// window. Any range not handed in loads through the same off-main `TrendsData.loadAsync(lookbackDays:)`
// the tabs use.

import SwiftUI
import SwiftData
import OpenCircuitKit

struct MetricDetailView: View {
    let metric: TodayTile.Metric
    let tempUnitRaw: String

    @Environment(\.modelContext) private var modelContext
    @State private var range = 14
    @State private var loaded: [Int: TrendsData]

    /// - Parameter todayTrends: the Today tab's shared load (`TrendsData.lookbackDays` long), reused
    ///   for that range instead of reading the same ~25 k rows again; nil to load it here.
    init(metric: TodayTile.Metric, tempUnitRaw: String, todayTrends: TrendsData? = nil) {
        self.metric = metric
        self.tempUnitRaw = tempUnitRaw
        _loaded = State(initialValue: todayTrends.map { [TrendsData.lookbackDays: $0] } ?? [:])
    }

    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 52

    private var tempUnit: TemperatureUnit { TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius }

    private var tile: TodayTile? {
        loaded[range].map {
            TodayTiles.build(metric, points: $0.points, restingHR: $0.restingHR,
                             tempUnit: tempUnit, windowDays: range)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                Picker("Range", selection: $range) {
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)

                if let tile {
                    header(tile)
                    OCCard {
                        MetricTrendChart(tile: tile)
                            .frame(height: 220)
                            .accessibilityElement()
                            .accessibilityLabel(chartSummary(tile))
                        legend(tile)
                    }
                    stats(tile)
                    notes(tile)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .navigationTitle(TodayTiles.build(metric, points: [], restingHR: [], tempUnit: tempUnit).title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: range) {
            guard loaded[range] == nil else { return }
            loaded[range] = await TrendsData.loadAsync(container: modelContext.container,
                                                       tempUnitRaw: tempUnitRaw, lookbackDays: range)
        }
    }

    // MARK: Pieces

    private func header(_ tile: TodayTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                KeylineGlyph(tile.icon, size: 16, relativeTo: .subheadline).foregroundStyle(tile.tint)
                Text("\(tile.qualifier.capitalizedFirst)\(tile.freshnessText().map { " · \($0)" } ?? "")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tile.valueText ?? "—")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tile.valueText == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                if tile.valueText != nil, !tile.unit.isEmpty {
                    Text(tile.unit).font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if let delta = tile.deltaText, let direction = tile.trend?.direction {
                HStack(spacing: 4) {
                    KeylineGlyph(direction.icon, size: 14, relativeTo: .subheadline).foregroundStyle(.secondary)
                    Text(delta).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if tile.isStale() {
                Text("No reading on the most recent day — this is the latest one there is.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ tile: TodayTile) -> some View {
        HStack(spacing: 14) {
            if tile.trend?.usualRange != nil {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(tile.tint.opacity(0.18)).frame(width: 16, height: 10)
                    Text(tile.rangeText).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(tile.rangeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(tile.values.compactMap { $0 }.count) of \(tile.values.count) days")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func stats(_ tile: TodayTile) -> some View {
        let vals = tile.values.compactMap { $0 }
        return HStack(spacing: 0) {
            stat("MIN", vals.min().map(tile.format))
            stat("AVG", vals.isEmpty ? nil : tile.format(vals.reduce(0, +) / Double(vals.count)))
            stat("MAX", vals.max().map(tile.format))
        }
        .ocCardSurface()
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func notes(_ tile: TodayTile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(what(tile.metric)).font(.footnote).foregroundStyle(.secondary)
            Text("Your usual range is the average of the earlier days in this window, widened by half their day-to-day spread (and never narrower than a small fixed margin). A value inside it counts as usual. It needs \(BaselineTrend.defaultMinBaselineDays) earlier days before it's shown. On-device estimate — not a medical device.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func what(_ m: TodayTile.Metric) -> String {
        switch m {
        case .hrv:             return "The average of the ring's heart-rate-variability readings while you slept, one value per night."
        case .restingHR:       return "A daily resting heart rate: the day's lowest 5-minute average heart rate — the same estimate Vitals Status uses."
        case .spo2:            return "The average of the ring's blood-oxygen readings while you slept, one value per night."
        case .respiratoryRate: return "The average of the ring's breathing-rate readings while you slept, one value per night."
        case .skinTemp:        return "The ring's skin temperature for each night. Skin temperature runs below core body temperature; what matters is the change from your usual."
        case .steps:           return "Steps counted by the ring each day. Today's total is still growing, so the comparison uses yesterday, the last complete day."
        }
    }

    private func chartSummary(_ tile: TodayTile) -> String {
        let vals = tile.values.compactMap { $0 }
        guard let lo = vals.min(), let hi = vals.max() else { return "\(tile.title) chart, no data in the last \(range) days" }
        var s = "\(tile.title) over the last \(range) days, \(vals.count) days with data, ranging from \(tile.format(lo)) to \(tile.format(hi)) \(tile.spokenUnit)"
        if let r = tile.trend?.usualRange {
            s += ". Usual range \(tile.format(r.lowerBound)) to \(tile.format(r.upperBound))"
        }
        return s
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
