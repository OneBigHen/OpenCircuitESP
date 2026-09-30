// Today metric tiles (#216) — the view: a two-column grid of glanceable tiles, each with value +
// unit, a 14-day sparkline and a neutral trend chip. Model and honesty rules live in `TodayTiles`.
//
// The trend chip is deliberately colour-neutral: "above usual" is good news for HRV and bad news
// for resting HR, and the tile has no business deciding which on the user's behalf — the synthesis
// line and Vitals Status are where judgements live.

import SwiftUI
import OpenCircuitKit

struct MetricTilesSection: View {
    let tiles: [TodayTile]
    /// The shared trends load hasn't landed yet: draw placeholders, not "No data yet".
    var isLoading = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR NUMBERS").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Text("last \(TodayTiles.windowDays) days").font(.caption).foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(tiles) { MetricTileView(tile: $0) }
            }
            .redacted(reason: isLoading ? .placeholder : [])
        }
    }
}

struct MetricTileView: View {
    let tile: TodayTile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                KeylineGlyph(tile.icon, size: 15, relativeTo: .caption)
                    .foregroundStyle(tile.tint)
                Text(tile.title.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tile.valueText ?? "—")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tile.valueText == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if tile.valueText != nil, !tile.unit.isEmpty {
                    Text(tile.unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Sparkline(values: tile.sparkline, baseline: tile.trend?.direction != nil ? tile.trend?.baselineMean : nil,
                      tint: tile.tint)
                .frame(height: 30)
            HStack(spacing: 4) {
                if let direction = tile.trend?.direction {
                    KeylineGlyph(direction.icon, size: 12, relativeTo: .caption2)
                        .foregroundStyle(tile.tint)
                }
                Text(tile.captionText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let asOf = tile.staleAsOf {
                Text("as of \(asOf.formatted(.dateTime.weekday(.abbreviated).day()))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ocCardSurface(padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
    }
}

private extension BaselineTrend.Direction {
    var icon: KeylineIcon {
        switch self {
        case .above:  return .arrowUpRight
        case .within: return .minus
        case .below:  return .arrowDownRight
        }
    }
}

/// A minimal 14-slot sparkline: consecutive days joined, gaps left as gaps (a lone day is a dot),
/// the newest point marked, and the baseline mean as a faint dashed rule when there is one.
struct Sparkline: View {
    let values: [Double?]
    var baseline: Double?
    var tint: Color

    var body: some View {
        Canvas { ctx, size in
            let present = values.compactMap { $0 } + (baseline.map { [$0] } ?? [])
            guard let lo = present.min(), let hi = present.max(), values.count > 1 else { return }
            let span = hi - lo
            let inset: CGFloat = 3
            func point(_ i: Int, _ v: Double) -> CGPoint {
                let x = inset + (size.width - 2 * inset) * CGFloat(i) / CGFloat(values.count - 1)
                let t = span > 0 ? (v - lo) / span : 0.5
                return CGPoint(x: x, y: inset + (size.height - 2 * inset) * CGFloat(1 - t))
            }
            if let baseline {
                let y = point(0, baseline).y
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y))
                rule.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(rule, with: .color(.secondary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            var run: [CGPoint] = []
            func flush() {
                if run.count == 1 {
                    ctx.fill(Path(ellipseIn: CGRect(x: run[0].x - 1.75, y: run[0].y - 1.75, width: 3.5, height: 3.5)),
                             with: .color(tint.opacity(0.8)))
                } else if run.count > 1 {
                    var p = Path()
                    p.addLines(run)
                    ctx.stroke(p, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                run = []
            }
            for (i, v) in values.enumerated() {
                if let v { run.append(point(i, v)) } else { flush() }
            }
            flush()
            if let last = values.lastIndex(where: { $0 != nil }), let v = values[last] {
                let c = point(last, v)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(tint))
            }
        }
        .accessibilityHidden(true)
    }
}
