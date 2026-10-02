// Today metric tiles (#216) — the view: a dense two-column grid, each tile reading top to bottom as
// label + freshness → large value with a small unit → delta vs usual with its arrow → a 14-day
// sparkline over the shaded usual range → the labelled usual range. Tapping a tile opens its
// detail on today's day chart, with the 14/30-day trend one segment away (#239); the row under the
// grid opens today's timeline. Model and honesty rules live in `TodayTiles`.
//
// The Helio Strap's Stress tile (#239, steer 3) sits in the same grid but is NOT a `TodayTile`: it has
// no usual range and no baseline (see `StrapStressTile`), so it never enters the "vs your usual"
// machinery, the Today sentence, or the 14/30-day detail. Tapping it opens today's stress chart.
//
// The delta arrow is deliberately colour-neutral (secondary): "above usual" is good news for HRV and
// bad news for resting HR, and the tile has no business deciding which on the user's behalf — the
// synthesis line and Vitals Status are where judgements live.

import SwiftUI
import Charts
import ZeppKit
import OpenCircuitKit

struct MetricTilesSection: View {
    let tiles: [TodayTile]
    /// The shared trends load hasn't landed yet: draw placeholders, not "No data yet".
    var isLoading = false
    var onSelect: (TodayTile.Metric) -> Void = { _ in }
    /// Opens today's timeline, every metric through the day (#239). No row when nil.
    var onTimeline: (() -> Void)?
    /// The strap's stress (#239, steer 3): a tile only while a stored strap reading is under 24 h old.
    var strapStress: StrapStressTile?
    /// Opens today's stress chart.
    var onStress: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR NUMBERS").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Text("vs your usual · \(TodayTiles.windowDays) days").font(.caption).foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(tiles) { tile in
                    Button { onSelect(tile.metric) } label: { MetricTileView(tile: tile) }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                }
                // Freshness is checked at render, not only at load, so a reading that ages past 24 h
                // while the app stays open drops the tile.
                if let strapStress, strapStress.isFresh(now: Date()) {
                    Button(action: onStress) { StrapStressTileView(tile: strapStress) }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                }
            }
            .redacted(reason: isLoading ? .placeholder : [])
            if let onTimeline {
                Button(action: onTimeline) { TodayTimelineRow() }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// The one-tap way from Today to today's timeline (#239): every metric's day chart, stacked.
struct TodayTimelineRow: View {
    var body: some View {
        HStack(spacing: 10) {
            KeylineGlyph(.activity, size: 16).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Today's timeline").font(.subheadline.weight(.semibold))
                Text("Every metric through the day").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            KeylineGlyph(.chevronRight, size: 14).foregroundStyle(.tertiary)
        }
        .ocCardSurface(padding: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens every metric's chart for today")
        .accessibilityAddTraits(.isButton)
    }
}

struct MetricTileView: View {
    let tile: TodayTile

    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                KeylineGlyph(tile.icon, size: 14, relativeTo: .caption)
                    .foregroundStyle(tile.tint)
                Text(tile.title.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                if let fresh = tile.freshnessText() {
                    Text(fresh)
                        .font(.caption2)
                        .foregroundStyle(tile.isStale() ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
            // Large value, small unit.
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(tile.valueText ?? "—")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tile.valueText == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.6)
                if tile.valueText != nil, !tile.unit.isEmpty {
                    Text(tile.unit).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Delta vs usual, with direction.
            HStack(spacing: 3) {
                if let direction = tile.trend?.direction, tile.deltaText != nil {
                    KeylineGlyph(direction.icon, size: 11, relativeTo: .caption2)
                        .foregroundStyle(.secondary)
                }
                Text(tile.deltaText ?? " ")
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            MetricTrendChart(tile: tile, compact: true)
                .frame(height: 34)
            Text(tile.rangeText)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCardSurface(padding: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityHint("Opens today's \(tile.title) chart and its trend")
        .accessibilityAddTraits(.isButton)
    }
}

/// The strap's Stress tile, laid out like `MetricTileView` — label + time, large value, a line of
/// words, a sparkline, a bottom line — but with Amazfit's band word where the delta would be, today's
/// readings where the 14-day series would be, and no usual range at all.
struct StrapStressTileView: View {
    let tile: StrapStressTile

    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 30

    private var level: Int { Int(tile.latest.value.rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                KeylineGlyph(.activity, size: 14, relativeTo: .caption).foregroundStyle(Theme.stress)
                // The day chart's own label, so this is never read as the ring's Overnight Stress.
                // The full label gets the whole row (the time sits with the band word below), so it is
                // never truncated to something that could be the ring's.
                Text("STRESS · HELIO STRAP")
                    .font(.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(level)")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("/ 100").font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            // Amazfit's word for the level (ZEPP_PROTOCOL.md §6.5), the only label it gets.
            HStack(spacing: 4) {
                Text(tile.band.map { $0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst() } ?? " ")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                Text(tile.latest.at, format: .dateTime.hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            StrapStressSparkline(tile: tile).frame(height: 34)
            Text("The strap's own scale · no usual range")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCardSurface(padding: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens today's stress chart")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = ["Stress, from the Helio Strap", "\(level) out of 100"]
        if let band = tile.band { parts.append(band.rawValue) }
        parts.append("at \(tile.latest.at.formatted(date: .omitted, time: .shortened))")
        parts.append("The strap's own scale, with no usual range")
        return parts.joined(separator: ". ")
    }
}

/// Today's strap stress as a compact line: the same buckets and the same never-bridge-a-gap runs as
/// the day chart (`IntradaySeries`), over a fixed 0–100 scale and the whole day.
struct StrapStressSparkline: View {
    let tile: StrapStressTile

    private struct Point: Identifiable {
        let id: String
        let run: String
        let time: Date
        let value: Double
        /// The only bucket in its run: a line needs two points, so this one is drawn as a dot.
        let isLone: Bool
    }

    private var points: [Point] {
        tile.today.series.enumerated().flatMap { si, s in
            s.runs.enumerated().flatMap { ri, run in
                run.enumerated().map { bi, b in
                    Point(id: "\(si)-\(ri)-\(bi)", run: "\(si)-\(ri)", time: b.mid, value: b.mean,
                          isLone: run.count == 1)
                }
            }
        }
    }

    var body: some View {
        if points.isEmpty {
            Text("No readings yet today").font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Chart(points) { p in
                LineMark(x: .value("Time", p.time), y: .value("Stress", p.value), series: .value("Run", p.run))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .foregroundStyle(Theme.stress)
                if p.isLone {
                    PointMark(x: .value("Time", p.time), y: .value("Stress", p.value))
                        .symbolSize(12)
                        .foregroundStyle(Theme.stress)
                }
            }
            .chartXScale(domain: tile.day.start...tile.day.end)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { $0.clipped() }
            .accessibilityHidden(true)
        }
    }
}

extension BaselineTrend.Direction {
    var icon: KeylineIcon {
        switch self {
        case .above:  return .arrowUpRight
        case .within: return .minus
        case .below:  return .arrowDownRight
        }
    }
}
