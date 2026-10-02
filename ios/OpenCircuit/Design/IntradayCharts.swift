// The intraday (one-day) chart cards (#74 follow-up, reworked for #239).
//
// One look for every day chart: the card surface, an uppercase title with an avg / scrub pill, the
// night in-bed band, a 6-hour axis, and the plot clipped to the day. What #239 changed:
//   • Readable at strap density: readings are bucketed (`IntradaySeries`, a few minutes each at a
//     per-minute strap's cadence) and drawn as a min–max band with the bucket average as the line.
//     Touch-to-scrub still reads the exact reading nearest the finger, never a bucket value.
//   • Never bridge a gap: a bucket with no readings ends the line. A run of one bucket is a dot.
//   • Per device (decisions 28, 29): each device that owned part of the day is its own series, the
//     line broken at the switch; when more than one device is on the card, both are named, each with
//     its own average, and each average's reference line covers only its device's time.

import SwiftUI
import Charts
import OpenCircuitKit

/// One intraday vital over a single day, as bucketed per-device series.
struct IntradaySeriesCard: View {
    let title: String
    let unit: String
    let color: Color
    let day: IntradaySeries.Day
    let domain: ClosedRange<Date>
    let nightWindow: DateInterval?
    /// The devices that owned some of the day, in order (`DayTimeline.owners`).
    var owners: [DeviceOwnershipLog.Family] = [.ringConn]
    /// Name the device(s) on the card. Off for a ring-only install, whose card is unchanged.
    var namesDevices = false
    /// Display conversion applied to every value at render (°C → °F follows the setting live).
    var convert: (Double) -> Double = { $0 }
    /// A fixed y-scale (stress is always 0–100); nil = fitted to the data.
    var fixedYDomain: ClosedRange<Double>?
    var decimals = 1
    /// Plain words under the chart (what the number is, what it is not).
    var footnote: String?

    @State private var selected: Date?

    private func text(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }
    private func withUnit(_ v: Double) -> String { unit.isEmpty ? text(v) : "\(text(v)) \(unit)" }

    /// Devices whose line is drawn dashed: only when two devices have readings on this card, the one
    /// whose readings come second. A single device is always a solid line.
    private func isSecondary(_ family: DeviceOwnershipLog.Family) -> Bool {
        day.families.count > 1 && day.families.first != family
    }

    private var showsLegend: Bool { namesDevices }
    /// Per-device reference lines only when two devices have readings on this card. A single device
    /// keeps the card exactly as it was (its average is in the header).
    private var drawsAverageLines: Bool { day.families.count > 1 }

    // MARK: Drawables

    private struct Band: Identifiable {
        let id: String
        let start: Date, end: Date, lo: Double, hi: Double
    }
    private struct LinePoint: Identifiable {
        let id: String
        let run: String
        let family: DeviceOwnershipLog.Family
        let time: Date, value: Double
    }
    private struct Dot: Identifiable {
        let id: String
        let family: DeviceOwnershipLog.Family
        let time: Date, lo: Double, hi: Double, value: Double
    }
    private struct AverageLine: Identifiable {
        let id: String
        let family: DeviceOwnershipLog.Family
        let start: Date, end: Date, value: Double
    }

    private var bands: [Band] {
        day.series.enumerated().flatMap { si, s in
            s.buckets.enumerated().map { bi, b in
                Band(id: "\(si)-\(bi)", start: b.start, end: b.end, lo: convert(b.min), hi: convert(b.max))
            }
        }
    }

    private var lines: [LinePoint] {
        day.series.enumerated().flatMap { si, s in
            s.runs.enumerated().filter { $0.element.count > 1 }.flatMap { ri, run in
                run.enumerated().map { bi, b in
                    LinePoint(id: "\(si)-\(ri)-\(bi)", run: "\(si)-\(ri)", family: s.family,
                              time: b.mid, value: convert(b.mean))
                }
            }
        }
    }

    private var dots: [Dot] {
        day.series.enumerated().flatMap { si, s in
            s.runs.enumerated().compactMap { ri, run -> Dot? in
                guard run.count == 1, let b = run.first else { return nil }
                return Dot(id: "\(si)-\(ri)", family: s.family, time: b.mid,
                           lo: convert(b.min), hi: convert(b.max), value: convert(b.mean))
            }
        }
    }

    private var averageLines: [AverageLine] {
        guard drawsAverageLines else { return [] }
        // Drawn across the stretch's own readings only, never over hours the device has none.
        return day.series.enumerated().compactMap { si, s in
            guard let first = s.buckets.first?.start, let last = s.buckets.last?.end,
                  let avg = day.averages[s.family] else { return nil }
            return AverageLine(id: "\(si)", family: s.family, start: max(first, domain.lowerBound),
                               end: min(last, domain.upperBound), value: convert(avg))
        }
    }

    /// Fit the y-axis to the band (+15% padding) so a tight vital isn't flattened by a 0 baseline.
    private var yDomain: ClosedRange<Double> {
        if let fixedYDomain { return fixedYDomain }
        let values = day.series.flatMap(\.buckets).flatMap { [convert($0.min), convert($0.max)] }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.15
        return (lo - pad)...(hi + pad)
    }

    /// Night band, clamped to the day so a window crossing midnight can't run off the right edge.
    private var clampedNight: (start: Date, end: Date)? {
        guard let w = nightWindow else { return nil }
        let s = max(w.start, domain.lowerBound)
        let e = min(w.end, domain.upperBound)
        return e > s ? (s, e) : nil
    }

    /// The exact reading under the finger.
    private var selectedReading: (point: IntradaySeries.Point, family: DeviceOwnershipLog.Family)? {
        selected.flatMap { IntradaySeries.nearest(to: $0, in: day) }
    }

    private func stroke(_ family: DeviceOwnershipLog.Family, width: CGFloat = 2) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, dash: isSecondary(family) ? [5, 3] : [])
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let sel = selectedReading {
                    HStack(spacing: 4) {
                        Text(sel.point.time, format: .dateTime.hour().minute())
                            .font(.caption2).foregroundStyle(.tertiary)
                        if day.families.count > 1 {
                            Text(sel.family.deviceName).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(withUnit(convert(sel.point.value)))
                            .font(.caption.weight(.semibold)).foregroundStyle(color)
                    }
                } else if day.families.count == 1, let family = day.families.first, let avg = day.averages[family] {
                    Text("avg \(withUnit(convert(avg)))")
                        .font(.caption.weight(.semibold)).foregroundStyle(color)
                }
            }
            if day.isEmpty {
                Text("No readings this day")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 110, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart.frame(height: 110)
                    .accessibilityElement()
                    .accessibilityLabel(accessibilitySummary)
            }
            if showsLegend { legend }
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .ocCardSurface()
    }

    /// Each device that owned part of the day, its line style and its own day average.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(owners, id: \.self) { family in
                HStack(spacing: 6) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 16, y: 4)) }
                        .stroke(color, style: stroke(family))
                        .frame(width: 16, height: 8)
                    Text(family.deviceName).font(.caption2).foregroundStyle(.secondary)
                    Text(day.averages[family].map { "avg \(withUnit(convert($0)))" } ?? "no readings")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(day.averages[family] == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibilitySummary: String {
        let parts = day.families.compactMap { family -> String? in
            guard let avg = day.averages[family] else { return nil }
            let name = day.families.count > 1 || namesDevices ? "\(family.deviceName), " : ""
            return "\(name)average \(withUnit(convert(avg)))"
        }
        return "\(title) through the day. " + parts.joined(separator: ". ")
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            if let night = clampedNight {
                RectangleMark(xStart: .value("Sleep start", night.start),
                              xEnd: .value("Sleep end", night.end))
                    .foregroundStyle(Color.indigo.opacity(0.10))
            }
            // Min–max per bucket: one rectangle each, so an empty bucket is simply not drawn.
            ForEach(bands) { b in
                RectangleMark(xStart: .value("Start", b.start), xEnd: .value("End", b.end),
                              yStart: .value("Min", b.lo), yEnd: .value("Max", b.hi))
                    .foregroundStyle(color.opacity(0.18))
            }
            // The bucket averages: one line per unbroken run, so the line stops at every gap.
            ForEach(lines) { p in
                LineMark(x: .value("Time", p.time), y: .value(title, p.value), series: .value("Run", p.run))
                    .interpolationMethod(.monotone)
                    .lineStyle(stroke(p.family))
                    .foregroundStyle(color)
            }
            ForEach(dots) { d in
                if d.hi > d.lo {
                    RuleMark(x: .value("Time", d.time), yStart: .value("Min", d.lo), yEnd: .value("Max", d.hi))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(color.opacity(0.35))
                }
                PointMark(x: .value("Time", d.time), y: .value(title, d.value))
                    .symbolSize(18).foregroundStyle(color)
            }
            ForEach(averageLines) { a in
                RuleMark(xStart: .value("Start", a.start), xEnd: .value("End", a.end), y: .value("Average", a.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(color.opacity(0.6))
            }
            if let sel = selectedReading {
                RuleMark(x: .value("Time", sel.point.time))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color.opacity(0.35))
                PointMark(x: .value("Time", sel.point.time), y: .value(title, convert(sel.point.value)))
                    .symbolSize(90).foregroundStyle(color)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selected)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }
}

/// Hourly steps as a clipped bar chart with touch-to-read. Bars match Apple Health's Steps look; the
/// night band is clamped to the day so it can't overflow the right axis. When two devices counted
/// steps this day, each device's share of an hour is its own stacked segment, and both are named.
struct IntradayStepsCard: View {
    let buckets: [DayTimeline.StepBucket]
    let total: Int?
    let domain: ClosedRange<Date>
    let nightWindow: DateInterval?
    var owners: [DeviceOwnershipLog.Family] = [.ringConn]
    var namesDevices = false

    @State private var selected: Date?

    private var families: [DeviceOwnershipLog.Family] {
        owners.filter { family in buckets.contains { $0.family == family } }
    }
    private var splitsByDevice: Bool { families.count > 1 }

    /// One total per hour, for the scrub readout.
    private var hourly: [(hour: Date, steps: Int)] {
        var sums: [Date: Int] = [:]
        for b in buckets { sums[b.hour, default: 0] += b.steps }
        return sums.sorted { $0.key < $1.key }.map { (hour: $0.key, steps: $0.value) }
    }

    private var clampedNight: (start: Date, end: Date)? {
        guard let w = nightWindow else { return nil }
        let s = max(w.start, domain.lowerBound)
        let e = min(w.end, domain.upperBound)
        return e > s ? (s, e) : nil
    }

    private var selectedBucket: (hour: Date, steps: Int)? {
        guard let selected else { return nil }
        return hourly.min {
            abs($0.hour.timeIntervalSince(selected)) < abs($1.hour.timeIntervalSince(selected))
        }
    }

    private func steps(of family: DeviceOwnershipLog.Family) -> Int {
        buckets.filter { $0.family == family }.reduce(0) { $0 + $1.steps }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STEPS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let sel = selectedBucket {
                    HStack(spacing: 4) {
                        Text(sel.hour, format: .dateTime.hour())
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("\(sel.steps) steps").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                } else if let total {
                    Text("\(total) total").font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
            if buckets.isEmpty {
                Text("No readings this day")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 110, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart.frame(height: 110)
            }
            if namesDevices {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(owners, id: \.self) { family in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(barColor(family)).frame(width: 12, height: 8)
                            Text(family.deviceName).font(.caption2).foregroundStyle(.secondary)
                            let count = steps(of: family)
                            Text(count > 0 ? "\(count) steps" : "no readings")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(count > 0 ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .ocCardSurface()
    }

    private func barColor(_ family: DeviceOwnershipLog.Family) -> Color {
        (owners.firstIndex(of: family) ?? 0) > 0 ? Color.green.opacity(0.45) : Color.green
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            if let night = clampedNight {
                RectangleMark(xStart: .value("Sleep start", night.start),
                              xEnd: .value("Sleep end", night.end))
                    .foregroundStyle(Color.indigo.opacity(0.10))
            }
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                BarMark(x: .value("Hour", b.hour, unit: .hour), y: .value("Steps", b.steps))
                    .foregroundStyle(splitsByDevice ? barColor(b.family) : .green)
            }
            if let sel = selectedBucket {
                RuleMark(x: .value("Hour", sel.hour, unit: .hour))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.green.opacity(0.4))
            }
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $selected)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }
}
