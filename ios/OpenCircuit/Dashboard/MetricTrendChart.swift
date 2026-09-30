// One Swift Charts view for a metric's daily series (#216), drawn two ways: a compact sparkline
// for the Today tile, and a full axis-labelled chart for the metric's detail screen.
//
// Both draw the SAME three things, in the metric's existing accent colour:
//   - the personal "usual range" as a shaded band (`BaselineTrend.usualRange` — the band the
//     above / within / below verdict uses, so the picture and the words can't disagree);
//   - the daily values as a line, broken at missing days (a lone day is a dot — never interpolated);
//   - the newest value as an emphasised point.
// No band is drawn while the baseline is still being learned.

import SwiftUI
import Charts
import OpenCircuitKit

struct MetricTrendChart: View {
    let tile: TodayTile
    var compact = false

    private struct DayValue: Identifiable {
        let date: Date
        let value: Double
        /// Index of the unbroken run this day belongs to (gaps start a new run).
        let run: Int
        let isSingleton: Bool
        var id: Date { date }
    }

    private var dayValues: [DayValue] {
        var out: [DayValue] = []
        var run = 0, previousWasValue = false
        var runs: [Int: Int] = [:]
        for (i, v) in tile.values.enumerated() {
            if let v {
                if !previousWasValue { run += 1 }
                out.append(DayValue(date: tile.days[i], value: v, run: run, isSingleton: false))
                runs[run, default: 0] += 1
                previousWasValue = true
            } else {
                previousWasValue = false
            }
        }
        return out.map { DayValue(date: $0.date, value: $0.value, run: $0.run, isSingleton: runs[$0.run] == 1) }
    }

    /// Y domain covering the values and the band, padded so nothing sits on the edge.
    private var yDomain: ClosedRange<Double> {
        var vals = tile.values.compactMap { $0 }
        if let r = tile.trend?.usualRange { vals += [r.lowerBound, r.upperBound] }
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.3, abs(hi) * 0.01, 0.1)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        let points = dayValues
        let newest = points.last
        let xStart = tile.days.first ?? Date()
        let xEnd = (tile.days.last ?? Date()).addingTimeInterval(86_400)
        Chart {
            if let r = tile.trend?.usualRange {
                RectangleMark(xStart: .value("Start", xStart), xEnd: .value("End", xEnd),
                              yStart: .value("Usual low", r.lowerBound), yEnd: .value("Usual high", r.upperBound))
                    .foregroundStyle(tile.tint.opacity(compact ? 0.13 : 0.12))
                if !compact, let mean = tile.trend?.baselineMean {
                    RuleMark(y: .value("Average", mean))
                        .foregroundStyle(tile.tint.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            ForEach(points) { p in
                // Centre each day's mark in its day (x is a Date at the day's start).
                let x = p.date.addingTimeInterval(43_200)
                if p.isSingleton {
                    PointMark(x: .value("Day", x), y: .value(tile.title, p.value))
                        .foregroundStyle(tile.tint.opacity(0.8))
                        .symbolSize(compact ? 14 : 30)
                } else {
                    LineMark(x: .value("Day", x), y: .value(tile.title, p.value),
                             series: .value("Run", p.run))
                        .foregroundStyle(tile.tint)
                        .lineStyle(StrokeStyle(lineWidth: compact ? 2 : 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    if !compact {
                        PointMark(x: .value("Day", x), y: .value(tile.title, p.value))
                            .foregroundStyle(tile.tint)
                            .symbolSize(18)
                    }
                }
            }
            if let newest {
                PointMark(x: .value("Day", newest.date.addingTimeInterval(43_200)),
                          y: .value(tile.title, newest.value))
                    .foregroundStyle(tile.tint)
                    .symbolSize(compact ? 40 : 90)
            }
        }
        .chartXScale(domain: xStart...xEnd)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .modifier(AxesModifier(compact: compact, days: tile.days.count, format: tile.format))
        .accessibilityHidden(compact)
    }

    private struct AxesModifier: ViewModifier {
        let compact: Bool
        let days: Int
        let format: (Double) -> String

        func body(content: Content) -> some View {
            if compact {
                content.chartXAxis(.hidden).chartYAxis(.hidden)
            } else {
                content
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: days > 16 ? 7 : 3)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                            AxisGridLine()
                            AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)) } }
                        }
                    }
            }
        }
    }
}
