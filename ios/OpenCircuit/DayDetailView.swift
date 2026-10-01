// Intraday (time-of-day) breakdown for one calendar day (#74 follow-up; #239 for both devices).
//
// The daily Trends bars answer "how was this day, on average" — this view answers
// "WHEN during the day was each metric at what level": a true time-series, x-axis is
// the actual sample timestamp (not bucketed to a day), so HR/SpO2/HRV/RR/steps can be
// read off at any time of day. The night's in-bed window (if any) is shaded for
// context, since a dip often lines up with sleep rather than anything daytime.
//
// Two ways in: Trends → tap a day, and Today → "Today's timeline" (#239). Every card reads only the
// device that owned each moment and draws each device as its own series (`DayTimeline`,
// `IntradaySeriesCard`); readings are bucketed so a strap's per-minute data stays readable.
//
// SCOPE — same samples already shown elsewhere; no new decode, no invented levels.
// The only "level" cue is each metric's own day average — per device, never a fabricated
// clinical threshold.

import SwiftUI
import SwiftData
import OpenCircuitKit

struct DayDetailView: View {
    let day: Date
    @Environment(\.modelContext) private var modelContext
    @State private var timeline: DayTimeline?
    // Display unit for skin temp: stored samples are °C, the chart converts (matches TrendsView #83).
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()

    /// The cards, top to bottom. Stress shows only where the strap owned some of the day.
    private static let order: [DayTimeline.Metric] = [.heartRate, .hrv, .spo2, .respiratoryRate, .skinTemp, .stress, .steps]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let timeline {
                    if timeline.isEmpty && !timeline.showsStress {
                        emptyState
                    } else {
                        ForEach(Self.order.filter { $0 != .stress || timeline.showsStress }, id: \.self) { metric in
                            DayMetricCard(timeline: timeline, metric: metric, tempUnitRaw: tempUnitRaw)
                        }
                    }
                } else {
                    ProgressView("Loading…").padding(.top, 40)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(Self.dayTitle.string(from: day))
        .navigationBarTitleDisplayMode(.inline)
        // Through the store, on appear and again after every finished sync (#239: today's chart must
        // not freeze; #222 review S1: never seeded from a parent's snapshot). Off the main actor
        // (review-242 SF-2): the read grows with history, and this one loads every card.
        .task(id: SyncRevision.shared.count) { await loadData() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No readings this day").font(.headline)
        }
        .padding(.top, 40)
    }

    @MainActor
    private func loadData() async {
        let loaded = await DayTimeline.loadAsync(container: modelContext.container, day: day)
        // `Task.isCancelled` is the whole guard here: `day` is a `let`, so every load on this view is
        // for the same day and only a sync bump can supersede one — `.task(id:)` cancels the previous
        // task before starting the new one. `MetricDayView` needs the day comparison as well, because
        // its `day` is `@State` and changes under the load (review-242b NIT 3).
        guard !Task.isCancelled else { return }
        timeline = loaded
    }
}

/// One metric's day card from a loaded `DayTimeline`: the same card on Today's timeline, Trends → a
/// day, and a Today metric's Day view.
struct DayMetricCard: View {
    let timeline: DayTimeline
    let metric: DayTimeline.Metric
    let tempUnitRaw: String

    /// The day's [start, start+1d) window — the fixed x-domain every intraday chart is scaled to.
    private var domain: ClosedRange<Date> { timeline.day.start...timeline.day.end }

    var body: some View {
        switch metric {
        case .heartRate:
            card("Heart Rate", unit: "bpm", color: .red)
        case .hrv:
            card("HRV (RMSSD est.)", unit: "ms", color: .green,
                 footnote: hasStrapReadings ? "The strap's HRV statistic is unconfirmed (RMSSD or SDNN)." : nil)
        case .spo2:
            card("SpO₂", unit: "%", color: .cyan)
        case .respiratoryRate:
            card("Respiratory Rate", unit: UnitsFormatter.respiratoryRateUnit, color: .teal)
        case .skinTemp:
            // Converted at render (not at load) so switching the unit re-renders live.
            let tempUnit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
            card("Skin Temp", unit: tempUnit.symbol, color: .orange,
                 convert: { tempUnit.convert(fromCelsius: $0) },
                 footnote: timeline.day(.skinTemp).families.count > 1
                    ? "The ring reads skin temperature on the finger and the strap on the arm, so each has its own line and average."
                    : nil)
        case .stress:
            card("Stress · Helio Strap", unit: "", color: Theme.stress, fixedYDomain: 0...100, decimals: 0,
                 footnote: Self.stressFootnote)
        case .steps:
            IntradayStepsCard(buckets: timeline.stepBuckets, total: timeline.stepsTotal, domain: domain,
                              nightWindow: timeline.nightWindow, owners: timeline.owners,
                              namesDevices: timeline.namesDevices)
        }
    }

    /// What the strap's stress is and is not. The bands are the ones ZEPP_PROTOCOL.md §6.5 (`0x13`)
    /// records for Amazfit; nothing else is labelled.
    static let stressFootnote = "The Helio Strap's all-day stress, 0 to 100, as the strap measures it. "
        + "It is not the ring's Overnight Stress score. Amazfit's bands: 0–39 relaxed, 40–59 mild, "
        + "60–79 moderate, 80–100 high. Stays in the app: Apple Health has no stress type."

    private var hasStrapReadings: Bool { timeline.day(metric).averages[.zeppOS] != nil }

    private func card(_ title: String, unit: String, color: Color, convert: @escaping (Double) -> Double = { $0 },
                      fixedYDomain: ClosedRange<Double>? = nil, decimals: Int = 1,
                      footnote: String? = nil) -> IntradaySeriesCard {
        // Stress is only ever the strap's, and its title names it: no device legend, no ring line.
        let strapOnly = metric == .stress
        return IntradaySeriesCard(title: title, unit: unit, color: color, day: timeline.day(metric), domain: domain,
                                  nightWindow: timeline.nightWindow, owners: strapOnly ? [.zeppOS] : timeline.owners,
                                  namesDevices: strapOnly ? false : timeline.namesDevices, convert: convert,
                                  fixedYDomain: fixedYDomain, decimals: decimals, footnote: footnote)
    }
}
