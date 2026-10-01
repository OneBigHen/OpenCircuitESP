// One metric through one day, with previous / next day (#239). The Day view of a Today metric's
// detail (`MetricDetailView`), and on its own for the strap's stress, which has no Today tile.
//
// Opens on today. Loads through the store when it appears, when the day changes and after every
// finished sync (`SyncRevision`), never from a parent's snapshot (#222 review S1).

import SwiftUI
import SwiftData
import OpenCircuitKit

struct MetricDayView: View {
    let metric: DayTimeline.Metric
    let tempUnitRaw: String
    /// Inside `MetricDetailView` (which owns the scroll view, background and title) or a screen of its own.
    var embedded = false

    @Environment(\.modelContext) private var modelContext
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var timeline: DayTimeline?

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        if embedded {
            content
        } else {
            ScrollView { content.padding(16) }
                .background(Theme.pageBackground)
                .navigationTitle(metric == .stress ? "Stress" : "Day")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            dayPicker
            if let timeline, timeline.day.start == day {
                DayMetricCard(timeline: timeline, metric: metric, tempUnitRaw: tempUnitRaw)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: LoadKey(day: day, revision: SyncRevision.shared.count)) { await load() }
    }

    private struct LoadKey: Equatable {
        let day: Date
        let revision: Int
    }

    private var dayPicker: some View {
        HStack {
            Button { step(-1) } label: {
                KeylineGlyph(.chevronLeft, size: 18).padding(8).contentShape(Rectangle())
            }
            .accessibilityLabel("Previous day")
            Spacer()
            Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { step(1) } label: {
                KeylineGlyph(.chevronRight, size: 18).padding(8).contentShape(Rectangle())
            }
            .disabled(isToday)
            .accessibilityLabel("Next day")
        }
        .foregroundStyle(Theme.accent)
        .buttonStyle(.plain)
    }

    private func step(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day) else { return }
        // Never past today: there is nothing to chart in the future.
        day = min(Calendar.current.startOfDay(for: next), Calendar.current.startOfDay(for: Date()))
    }

    @MainActor
    private func load() async {
        let requested = day
        let loaded = await DayTimeline.loadAsync(container: modelContext.container, day: requested,
                                                 metrics: [metric])
        // Tapping through days fast starts a load per day. `.task(id:)` cancels the superseded one,
        // and the day is compared as well, so an older day's result can never land on a newer one
        // (review-242 SF-2).
        guard !Task.isCancelled, requested == day, loaded.day == DayTimeline.dayInterval(requested) else { return }
        timeline = loaded
    }
}

extension TodayTile.Metric {
    /// The day chart a Today tile's Day view shows. Resting heart rate is one value per day, so its
    /// Day view is the day's heart rate it is derived from.
    var dayMetric: DayTimeline.Metric {
        switch self {
        case .hrv: return .hrv
        case .restingHR: return .heartRate
        case .spo2: return .spo2
        case .respiratoryRate: return .respiratoryRate
        case .skinTemp: return .skinTemp
        case .steps: return .steps
        }
    }
}
