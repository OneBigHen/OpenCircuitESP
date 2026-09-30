// DEBUG-ONLY synthetic demo data for screenshots (#216). Compiled out of Release entirely.
//
// Launch a Debug build with `-OCDemoData YES` (e.g. `xcrun simctl launch booted <bundle> -OCDemoData YES`)
// and, on a store with no sleep history, this seeds 30 days of SYNTHETIC ring data — sleep
// summaries, overnight HR/HRV/SpO₂/resp. rate, daytime HR + skin temp, and steps — so the Today tab
// can be reviewed by screenshot. Every value is generated from smooth formulas below; none of it
// comes from, or resembles a copy of, any real wearer's data. It refuses to touch a store that
// already holds sleep history, so it can never mix into real data on a developer's own phone.

#if DEBUG
import Foundation
import SwiftData
import UIKit
import OpenCircuitKit

enum DemoData {
    static let launchArgumentKey = "OCDemoData"

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: launchArgumentKey) }

    /// `-OCDemoScrollY <points>`: after launch, scroll the Today list down that far, so a
    /// screenshot run can capture below the fold without UI automation.
    static let scrollKey = "OCDemoScrollY"

    @MainActor
    static func seedIfRequested(_ context: ModelContext, now: Date = Date()) {
        guard isRequested else { return }
        scheduleScrollIfRequested()
        let existing = (try? context.fetchCount(FetchDescriptor<StoredSleepSummary>())) ?? 0
        guard existing == 0 else { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let nights = 30

        // Deterministic wiggle in -1…1, so every run (and before/after) seeds identical data.
        func wiggle(_ i: Int, _ salt: Double) -> Double { sin(Double(i) * 1.7 + salt) * cos(Double(i) * 0.6 + salt * 2) }

        for n in 0..<nights {
            // n = 0 is last night (ending this morning), n = nights - 1 the oldest.
            let i = nights - 1 - n
            guard let wakeDay = cal.date(byAdding: .day, value: -n, to: today),
                  let bedDay = cal.date(byAdding: .day, value: -1, to: wakeDay) else { continue }
            let bed = bedDay.addingTimeInterval((23 * 60 + 5 + 20 * wiggle(i, 0.3)) * 60)
            let wake = wakeDay.addingTimeInterval((6 * 60 + 50 + 15 * wiggle(i, 1.1)) * 60)
            let inBedMin = Int(wake.timeIntervalSince(bed) / 60)
            let awake = 42 + Int(8 * wiggle(i, 2.0))
            let asleep = inBedMin - awake
            let deep = Int(Double(asleep) * 0.19), rem = Int(Double(asleep) * 0.23)
            // A gentle upward recovery trend over the fortnight, so the tiles have something to say.
            let progress = Double(i) / Double(nights - 1)
            let summary = StoredSleepSummary(
                night: SleepNightKey.night(inBedStart: bed, inBedEnd: wake, calendar: cal),
                asleepMin: asleep, deepMin: deep, lightMin: asleep - deep - rem, remMin: rem,
                awakeMin: awake, efficiency: Double(asleep) / Double(inBedMin),
                inBedStart: bed, inBedEnd: wake,
                sleepOnset: bed.addingTimeInterval(12 * 60), sleepWake: wake.addingTimeInterval(-6 * 60),
                updatedAt: wake,
                skinTempC: 33.55 + 0.22 * wiggle(i, 0.9),
                sleepScore: Int(74 + 8 * progress + 5 * wiggle(i, 0.5)),
                stressScore: Int(44 - 10 * progress + 4 * wiggle(i, 1.7)))
            // A synthetic stage timeline: ~90-minute cycles, deeper early and more REM late, with a
            // couple of brief wakes. The oldest nights get none, so the "timeline isn't stored"
            // state is on screen too.
            if n < 20 { summary.hypnogramData = SleepHypnogramCodec.encode(demoHypnogram(bed: bed, wake: wake, salt: Double(i))) }
            context.insert(summary)

            // Overnight series every 5 minutes (SpO₂ / RR every 10).
            // Night-to-night variation on top of the trend, as real nights have.
            let hrvBase = 44 + 12 * progress + 5 * wiggle(i, 2.6)
            let hrBase = 56 - 3 * progress + 1.8 * wiggle(i, 3.1)
            let spo2Base = 0.962 + 0.006 * wiggle(i, 0.8)
            let rrBase = 14.6 + 0.5 * wiggle(i, 1.4)
            var t = bed, k = 0
            while t < wake {
                let w = wiggle(k + i * 97, 0.2)
                context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: t,
                                            end: t.addingTimeInterval(60), value: (hrBase + 3 * w).rounded()))
                context.insert(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: t,
                                            end: t.addingTimeInterval(60), value: (hrvBase + 7 * w).rounded()))
                if k % 2 == 0 {
                    context.insert(StoredSample(kindRaw: MetricKind.spo2.rawValue, start: t,
                                                end: t.addingTimeInterval(60), value: spo2Base + 0.012 * w))
                    context.insert(StoredSample(kindRaw: MetricKind.respiratoryRate.rawValue, start: t,
                                                end: t.addingTimeInterval(60), value: rrBase + 0.6 * w))
                }
                t = t.addingTimeInterval(300); k += 1
            }

            // Daytime (for past days: 07:30–22:30; for today: up to now) HR, skin temp and steps.
            let dayEnd = n == 0 ? now : wakeDay.addingTimeInterval(22.5 * 3600)
            var d = wakeDay.addingTimeInterval(7.5 * 3600), j = 0
            var daySteps = 0
            while d < dayEnd {
                let w = wiggle(j + i * 31, 0.7)
                context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: d,
                                            end: d.addingTimeInterval(60), value: (74 + 12 * w).rounded()))
                if j % 4 == 0 { context.insert(StoredDaytimeTemp(time: d, celsius: 32.9 + 0.3 * w)) }
                let delta = max(0, Int(150 + 40 * wiggle(i, 0.4) + 110 * wiggle(j + i * 13, 1.9)))
                let end = min(d.addingTimeInterval(900), dayEnd)
                context.insert(StoredStepSample(start: d, end: end, delta: delta))
                daySteps += delta
                d = d.addingTimeInterval(900); j += 1
            }
            context.insert(StoredDaily(day: wakeDay, steps: daySteps, updatedAt: dayEnd))
        }
        try? context.save()
    }

    private static func demoHypnogram(bed: Date, wake: Date, salt: Double) -> [SleepSegment] {
        var out: [SleepSegment] = []
        var t = bed
        func add(_ minutes: Double, _ stage: SleepStage) {
            let end = min(t.addingTimeInterval(minutes * 60), wake)
            guard end > t else { return }
            out.append(SleepSegment(start: t, end: end, stage: stage))
            t = end
        }
        add(12, .awake)
        var cycle = 0
        while t < wake {
            let late = Double(cycle) / 4
            add(22 + 6 * sin(salt + Double(cycle)), .asleepCore)
            add(max(4, 34 - 22 * late + 5 * cos(salt * 1.3 + Double(cycle))), .asleepDeep)
            add(14, .asleepCore)
            add(10 + 16 * late, .asleepREM)
            if cycle % 2 == 1 { add(4, .awake) }
            cycle += 1
        }
        return out
    }

    @MainActor
    private static func scheduleScrollIfRequested() {
        let y = UserDefaults.standard.double(forKey: scrollKey)
        guard y > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            guard let list = windows.lazy.compactMap({ firstVerticalScrollView(in: $0) }).first else { return }
            let maxY = max(list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom, 0)
            list.setContentOffset(CGPoint(x: 0, y: min(y, maxY) - list.adjustedContentInset.top), animated: false)
        }
    }

    /// The first on-screen scroll view taller in content than in frame (the Today `List`).
    @MainActor
    private static func firstVerticalScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView, s.window != nil, !s.isHidden,
           s.contentSize.height > s.bounds.height + 1, s.bounds.width > 200 { return s }
        for sub in view.subviews { if let s = firstVerticalScrollView(in: sub) { return s } }
        return nil
    }
}
#endif

#if DEBUG
import SwiftUI

/// DEBUG-only: `-OCDemoScreen metric-hrv | pastNights | liveHR` presents that screen full-screen on
/// launch, so a screenshot run can reach it without UI automation. `liveHR` renders the live-measure
/// card's composition over a SYNTHETIC buffer — a simulator has no ring to measure.
struct DemoScreenModifier: ViewModifier {
    @State private var screen: String?
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: Binding(get: { screen.map(DemoScreenID.init) },
                                           set: { screen = $0?.id })) { id in
                NavigationStack { destination(id.id) }
            }
            .task {
                guard DemoData.isRequested, let s = UserDefaults.standard.string(forKey: "OCDemoScreen") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                screen = s
            }
    }

    @ViewBuilder
    private func destination(_ id: String) -> some View {
        if id.hasPrefix("metric-"), let m = TodayTile.Metric(rawValue: String(id.dropFirst(7))) {
            MetricDetailView(metric: m, tempUnitRaw: tempUnitRaw)
        } else if id == "pastNights" {
            SleepNightsBrowserView()
        } else {
            DemoLiveCard()
        }
    }
}

private struct DemoScreenID: Identifiable { let id: String }

private struct DemoLiveCard: View {
    @State private var buffer: LiveBuffer = {
        var b = LiveBuffer()
        let now = Date().timeIntervalSince1970
        for k in 0..<45 {
            let t = Double(k) * 2
            b.append(value: (62 + 4 * sin(t / 9) + 2 * sin(t / 3.1)).rounded(), at: now - 90 + t)
        }
        return b
    }()

    var body: some View {
        ScrollView {
            OCCard {
                OCSectionHeader("Live Heart Rate", systemImage: "heart.fill", tint: Theme.hr)
                LiveVitalReadout(value: Int(buffer.latest), unit: "bpm", tint: Theme.hr,
                                 pulses: true, sessionValues: buffer.points.map(\.value))
                LiveVitalsChart(buffer: buffer, color: Theme.hr, window: 90, unit: "bpm",
                                emptyText: "Hold still — getting a reading…")
                    .frame(height: 150)
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .navigationTitle("Today")
    }
}
#endif
