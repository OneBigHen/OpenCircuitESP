// Today metric tiles (#216) — the view: a dense two-column grid, each tile reading top to bottom as
// label + freshness → large value with a small unit → delta vs usual with its arrow → a 14-day
// sparkline over the shaded usual range → the labelled usual range. Tapping a tile opens its
// detail on today's day chart, with the 14/30-day trend one segment away (#239); the row under the
// grid opens today's timeline. Model and honesty rules live in `TodayTiles`.
//
// The delta arrow is deliberately colour-neutral (secondary): "above usual" is good news for HRV and
// bad news for resting HR, and the tile has no business deciding which on the user's behalf — the
// synthesis line and Vitals Status are where judgements live.

import SwiftUI
import OpenCircuitKit

struct MetricTilesSection: View {
    let tiles: [TodayTile]
    /// The shared trends load hasn't landed yet: draw placeholders, not "No data yet".
    var isLoading = false
    var onSelect: (TodayTile.Metric) -> Void = { _ in }
    /// Opens today's timeline, every metric through the day (#239). No row when nil.
    var onTimeline: (() -> Void)?

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

extension BaselineTrend.Direction {
    var icon: KeylineIcon {
        switch self {
        case .above:  return .arrowUpRight
        case .within: return .minus
        case .below:  return .arrowDownRight
        }
    }
}
