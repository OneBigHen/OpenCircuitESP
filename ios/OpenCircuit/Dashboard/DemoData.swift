// DEBUG-ONLY synthetic demo data for screenshots (#216). Compiled out of Release entirely.
//
// Launch a Debug build with `-OCDemoData YES` (e.g. `xcrun simctl launch booted <bundle> -OCDemoData YES`)
// and, on a store with no sleep history, this seeds two weeks of SYNTHETIC ring data — sleep
// summaries, overnight HR/HRV/SpO₂/resp. rate, daytime HR + skin temp, and steps — so the Today tab
// can be reviewed by screenshot. Every value is generated from smooth formulas below; none of it
// comes from, or resembles a copy of, any real wearer's data. It refuses to touch a store that
// already holds sleep history, so it can never mix into real data on a developer's own phone.

#if DEBUG
import Foundation
import SwiftData
import OpenCircuitKit

enum DemoData {
    static let launchArgumentKey = "OCDemoData"

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: launchArgumentKey) }

    @MainActor
    static func seedIfRequested(_ context: ModelContext, now: Date = Date()) {
        guard isRequested else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<StoredSleepSummary>())) ?? 0
        guard existing == 0 else { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let nights = 14

        // Deterministic wiggle in -1…1, so every run (and before/after) seeds identical data.
        func wiggle(_ i: Int, _ salt: Double) -> Double { sin(Double(i) * 1.7 + salt) * cos(Double(i) * 0.6 + salt * 2) }

        for n in 0..<nights {
            // n = 0 is last night (ending this morning), n = 13 the oldest.
            let i = nights - 1 - n
            guard let wakeDay = cal.date(byAdding: .day, value: -n, to: today),
                  let bedDay = cal.date(byAdding: .day, value: -1, to: wakeDay) else { continue }
            let bed = bedDay.addingTimeInterval((23 * 60 + 5 + 20 * wiggle(i, 0.3)) * 60)
            let wake = wakeDay.addingTimeInterval((6 * 60 + 50 + 15 * wiggle(i, 1.1)) * 60)
            let inBedMin = Int(wake.timeIntervalSince(bed) / 60)
            let awake = 28 + Int(8 * wiggle(i, 2.0))
            let asleep = inBedMin - awake
            let deep = Int(Double(asleep) * 0.19), rem = Int(Double(asleep) * 0.23)
            // A gentle upward recovery trend over the fortnight, so the tiles have something to say.
            let progress = Double(i) / Double(nights - 1)
            let summary = StoredSleepSummary(
                night: cal.startOfDay(for: bed),
                asleepMin: asleep, deepMin: deep, lightMin: asleep - deep - rem, remMin: rem,
                awakeMin: awake, efficiency: Double(asleep) / Double(inBedMin),
                inBedStart: bed, inBedEnd: wake,
                sleepOnset: bed.addingTimeInterval(12 * 60), sleepWake: wake.addingTimeInterval(-6 * 60),
                updatedAt: wake,
                skinTempC: 33.55 + 0.12 * wiggle(i, 0.9),
                sleepScore: Int(74 + 8 * progress + 5 * wiggle(i, 0.5)),
                stressScore: Int(44 - 10 * progress + 4 * wiggle(i, 1.7)))
            context.insert(summary)

            // Overnight series every 5 minutes (SpO₂ / RR every 10).
            let hrvBase = 44 + 12 * progress, hrBase = 56 - 3 * progress
            var t = bed, k = 0
            while t < wake {
                let w = wiggle(k + i * 97, 0.2)
                context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: t,
                                            end: t.addingTimeInterval(60), value: (hrBase + 3 * w).rounded()))
                context.insert(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: t,
                                            end: t.addingTimeInterval(60), value: (hrvBase + 7 * w).rounded()))
                if k % 2 == 0 {
                    context.insert(StoredSample(kindRaw: MetricKind.spo2.rawValue, start: t,
                                                end: t.addingTimeInterval(60), value: 0.965 + 0.012 * w))
                    context.insert(StoredSample(kindRaw: MetricKind.respiratoryRate.rawValue, start: t,
                                                end: t.addingTimeInterval(60), value: 14.6 + 0.6 * w))
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
                let delta = max(0, Int(150 + 110 * wiggle(j + i * 13, 1.9)))
                let end = min(d.addingTimeInterval(900), dayEnd)
                context.insert(StoredStepSample(start: d, end: end, delta: delta))
                daySteps += delta
                d = d.addingTimeInterval(900); j += 1
            }
            context.insert(StoredDaily(day: wakeDay, steps: daySteps, updatedAt: dayEnd))
        }
        try? context.save()
    }
}
#endif
