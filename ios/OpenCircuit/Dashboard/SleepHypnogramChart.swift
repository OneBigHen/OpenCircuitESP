// The night's stages over time — the hypnogram the Zepp app draws for the Helio Strap, and the one
// "Past nights" (#216) already drew — shared by the Sleep card and the night browser so the two can't
// drift apart.
//
// One row per stage (Awake on top, Deep at the bottom), each segment a block in its stage colour, a
// thin step line joining consecutive segments, and the night's first and last clock times under the
// axis. Touch-and-drag (or tap) reads one segment out: its stage, its clock span and its length — the
// "what was I doing at 3 am" question the stacked bar can't answer.
//
// Honesty rules, unchanged from the browser's private chart this replaces:
//   - only stored/live segments are drawn; a night without a timeline never gets one invented here
//     (callers show their totals instead);
//   - a segment the wearer entered (`provenance != .measured`) is drawn faded, and the caller says so.
// Stage colours are the Sleep card's own (Deep indigo, Light teal, REM purple, Awake orange).

import SwiftUI
import Charts
import OpenCircuitKit

struct SleepHypnogramChart: View {
    let segments: [SleepSegment]
    var height: CGFloat = 150

    @State private var selectedTime: Date?

    enum Row: String, CaseIterable {
        case awake = "Awake", rem = "REM", light = "Light", deep = "Deep"
        var color: Color {
            switch self {
            case .awake: return .orange
            case .rem:   return .purple
            case .light: return .teal
            case .deep:  return .indigo
            }
        }
    }

    static func row(_ s: SleepStage) -> Row? {
        switch s {
        case .awake:      return .awake
        case .asleepREM:  return .rem
        case .asleepCore: return .light
        case .asleepDeep: return .deep
        case .inBed:      return nil
        }
    }

    /// The drawable segments, in time order. `.inBed` has no row and is left out.
    static func plotted(_ segments: [SleepSegment]) -> [SleepSegment] {
        segments.filter { row($0.stage) != nil && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// The segment under `time`, or nil between segments / outside the night. A time exactly on a
    /// boundary belongs to the segment that STARTS there.
    static func segment(at time: Date, in plotted: [SleepSegment]) -> SleepSegment? {
        plotted.last { $0.start <= time && time < $0.end }
    }

    /// The step lines: one per change of row between two segments that touch (a gap of up to 5 min,
    /// the staging's epoch rounding). Segments further apart aren't joined — nothing was recorded
    /// between them, and a line would claim a transition nobody saw.
    static func transitions(_ plotted: [SleepSegment]) -> [(time: Date, from: Row, to: Row)] {
        zip(plotted, plotted.dropFirst()).compactMap { a, b in
            guard let from = row(a.stage), let to = row(b.stage), from != to,
                  b.start.timeIntervalSince(a.end) <= 300 else { return nil }
            return (b.start, from, to)
        }
    }

    var body: some View {
        let plotted = Self.plotted(segments)
        let steps = Self.transitions(plotted)
        let blocks = plotted.compactMap { seg in Self.row(seg.stage).map { (seg: seg, row: $0) } }
        let picked = selectedTime.flatMap { Self.segment(at: $0, in: plotted) }
        VStack(alignment: .leading, spacing: 6) {
            readout(picked, plotted: plotted)
            Chart {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    RuleMark(x: .value("Time", step.time),
                             yStart: .value("Stage", step.from.rawValue),
                             yEnd: .value("Stage", step.to.rawValue))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    RectangleMark(xStart: .value("Start", block.seg.start), xEnd: .value("End", block.seg.end),
                                  y: .value("Stage", block.row.rawValue), height: .ratio(0.8))
                        .foregroundStyle(block.row.color.opacity(opacity(block.seg, picked: picked)))
                        .cornerRadius(2)
                }
                if picked != nil, let selectedTime {
                    RuleMark(x: .value("Selected", selectedTime))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: Row.allCases.map(\.rawValue))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartXSelection(value: $selectedTime)
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(Self.summary(plotted))
            if let first = plotted.first?.start, let last = plotted.last?.end {
                HStack {
                    Text(first.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    Text(last.formatted(date: .omitted, time: .shortened))
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityHidden(true)
            }
        }
    }

    /// Faded when wearer-entered; while a segment is picked, the others dim so it stands out.
    private func opacity(_ seg: SleepSegment, picked: SleepSegment?) -> Double {
        let base = seg.provenance == .measured ? 1.0 : 0.4
        guard let picked else { return base }
        return seg == picked ? base : base * 0.35
    }

    /// One line above the chart: the picked segment, or a hint that the chart can be scrubbed.
    @ViewBuilder
    private func readout(_ picked: SleepSegment?, plotted: [SleepSegment]) -> some View {
        if let picked, let row = Self.row(picked.stage) {
            HStack(spacing: 6) {
                Circle().fill(row.color).frame(width: 8, height: 8)
                Text(row.rawValue).font(.caption.weight(.semibold))
                Text(Self.span(picked)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if picked.provenance != .measured {
                    Text("· entered by you").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else if !plotted.isEmpty {
            Text("Touch and drag to see each stage's times")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// "2:14 – 2:51 AM · 37m".
    static func span(_ seg: SleepSegment) -> String {
        let minutes = Int((seg.end.timeIntervalSince(seg.start) / 60).rounded())
        let length = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return "\(seg.start.formatted(date: .omitted, time: .shortened)) – "
            + "\(seg.end.formatted(date: .omitted, time: .shortened)) · \(length)"
    }

    static func summary(_ segs: [SleepSegment]) -> String {
        guard let first = segs.first?.start, let last = segs.last?.end else { return "No stages" }
        let awakenings = segs.filter { $0.stage == .awake }.count
        return "Sleep stages from \(first.formatted(date: .omitted, time: .shortened)) to "
            + "\(last.formatted(date: .omitted, time: .shortened)), \(awakenings) awake periods"
    }
}
