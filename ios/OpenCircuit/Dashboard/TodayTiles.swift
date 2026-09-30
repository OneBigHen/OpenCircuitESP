// Today metric tiles (#216) — the model: turns the shared two-week trends load into six tiles
// (HRV, resting HR, SpO₂, respiratory rate, skin temp, steps), each with its current value, a
// 14-day series for the sparkline, and where the value sits against the user's own baseline.
//
// Reads ONLY what `TrendsData` already loaded from `LocalStore` (the same per-day rollups the
// Trends tab charts), plus the resting-HR series `TrendsData` derives with `RestingHR.dailyValues`
// — so a tile can never disagree with the Trends tab about the same day. Nothing is interpolated:
// a day without data is a gap in the sparkline, a metric without data says so.
//
// Which daily value each tile uses, and why:
//   HRV / SpO₂ / resp. rate — the OVERNIGHT average (`sleep*Avg`): the night is the one window the
//     ring samples consistently, so nights compare like-for-like; daytime values depend on activity.
//   Skin temp — the nightly value stored on the sleep summary (the Vitals Status source).
//   Resting HR — `RestingHR.dailyValues` over the window's HR (the Vitals Status derivation).
//   Steps — today's running total as the headline; the TREND compares the last COMPLETE day, since
//     a partial day would always read "below usual" before evening.

import SwiftUI
import OpenCircuitKit

struct TodayTile: Identifiable {
    enum Metric: String, CaseIterable {
        case hrv, restingHR, spo2, respiratoryRate, skinTemp, steps
    }

    let metric: Metric
    let title: String
    /// What the value is, in a few words ("overnight avg").
    let qualifier: String
    let icon: KeylineIcon
    let tint: Color
    /// Formatted current value, or nil when there's no data at all.
    let valueText: String?
    let unit: String
    /// One slot per day of the window, oldest first; nil = no data that day.
    let sparkline: [Double?]
    /// The baseline comparison behind the trend chip; nil when there's no data.
    let trend: BaselineTrend.Result?
    /// For steps, the trend is about yesterday, not today's partial total.
    let trendIsYesterday: Bool
    /// The newest value's day is older than yesterday — shown as "as of …".
    let staleAsOf: Date?
    /// Spoken form of the unit, for VoiceOver.
    let spokenUnit: String
    /// Formats a baseline mean (in display units) for the caption / VoiceOver.
    let format: (Double) -> String

    var id: Metric { metric }

    // MARK: Caption

    var captionText: String {
        guard valueText != nil else { return "No data yet" }
        let need = BaselineTrend.defaultMinBaselineDays
        guard let trend, let direction = trend.direction else {
            return "Learning your usual · \(min(trend?.baselineDays ?? 0, need))/\(need) days"
        }
        let prefix = trendIsYesterday ? "Yesterday " : ""
        switch direction {
        case .above:  return prefix + (trendIsYesterday ? "above usual" : "Above usual")
        case .within: return prefix + (trendIsYesterday ? "near usual" : "Near usual")
        case .below:  return prefix + (trendIsYesterday ? "below usual" : "Below usual")
        }
    }

    var accessibilityLabel: String {
        var parts = [title]
        if let valueText { parts.append("\(valueText) \(spokenUnit), \(qualifier)") } else { parts.append("no data yet") }
        if let staleAsOf {
            parts.append("as of \(staleAsOf.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
        }
        if let trend, let direction = trend.direction, let mean = trend.baselineMean {
            let who = trendIsYesterday ? "Yesterday was" : "That's"
            let where_: String
            switch direction {
            case .above:  where_ = "above"
            case .within: where_ = "near"
            case .below:  where_ = "below"
            }
            parts.append("\(who) \(where_) your usual of \(format(mean)) \(spokenUnit)")
        } else if valueText != nil {
            parts.append("still learning your usual range")
        }
        let days = sparkline.compactMap { $0 }.count
        parts.append("\(days) of the last \(sparkline.count) days have data")
        return parts.joined(separator: ". ")
    }
}

enum TodayTiles {

    static let windowDays = TrendsData.lookbackDays

    /// Build the six tiles. `now`/`calendar` are injectable for tests and fixtures.
    static func build(points: [TrendsEngine.DailyPoint],
                      restingHR: [RestingHR.DailyValue],
                      tempUnit: TemperatureUnit,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [TodayTile] {
        let today = calendar.startOfDay(for: now)
        let days: [Date] = (0..<windowDays).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        func series(_ pick: (TrendsEngine.DailyPoint) -> Double?) -> [BaselineTrend.Point] {
            points.compactMap { p in
                guard let v = pick(p), v > 0, v.isFinite else { return nil }
                return BaselineTrend.Point(date: calendar.startOfDay(for: p.date), value: v)
            }
            .filter { $0.date >= (days.first ?? today) && $0.date <= today }
        }

        func slots(_ pts: [BaselineTrend.Point]) -> [Double?] {
            var byDay: [Date: Double] = [:]
            for p in pts { byDay[p.date] = p.value }
            return days.map { byDay[$0] }
        }

        func stale(_ pts: [BaselineTrend.Point]) -> Date? {
            guard let last = pts.max(by: { $0.date < $1.date }) else { return nil }
            return last.date < yesterday ? last.date : nil
        }

        func tile(_ metric: TodayTile.Metric, _ title: String, _ qualifier: String, _ icon: KeylineIcon,
                  _ tint: Color, _ unit: String, spokenUnit: String, pts: [BaselineTrend.Point],
                  floor: Double, format: @escaping (Double) -> String) -> TodayTile {
            let trend = BaselineTrend.evaluate(pts, minAbsoluteDelta: floor)
            return TodayTile(metric: metric, title: title, qualifier: qualifier, icon: icon, tint: tint,
                             valueText: trend.map { format($0.latest.value) }, unit: unit,
                             sparkline: slots(pts), trend: trend, trendIsYesterday: false,
                             staleAsOf: stale(pts), spokenUnit: spokenUnit, format: format)
        }

        let whole: (Double) -> String = { String(Int($0.rounded())) }
        let oneDecimal: (Double) -> String = { String(format: "%.1f", $0) }

        let hrv = tile(.hrv, "HRV", "overnight avg", .activity, Theme.hrv, "ms",
                       spokenUnit: "milliseconds", pts: series(\.sleepHRVAvg), floor: 3, format: whole)

        let rhrPts = restingHR
            .map { BaselineTrend.Point(date: calendar.startOfDay(for: $0.day), value: $0.bpm) }
            .filter { $0.value > 0 && $0.date >= (days.first ?? today) }
        let rhr = tile(.restingHR, "Resting HR", "daily estimate", .heart, Theme.hr, "bpm",
                       spokenUnit: "beats per minute", pts: rhrPts, floor: 2, format: whole)

        let spo2 = tile(.spo2, "SpO₂", "overnight avg", .droplet, Theme.spo2, "%",
                        spokenUnit: "percent", pts: series { $0.sleepSpO2Avg.map { $0 * 100 } },
                        floor: 1, format: whole)

        let rr = tile(.respiratoryRate, "Resp. rate", "overnight avg", .wind, Theme.rr,
                      UnitsFormatter.respiratoryRateUnit, spokenUnit: "breaths per minute",
                      pts: series(\.sleepRRAvg), floor: 0.5, format: oneDecimal)

        // Converted to the user's unit BEFORE comparing, so the floor is expressed in that unit too.
        let tempFloorC = 0.3
        let tempPts = series(\.skinTempC).map {
            BaselineTrend.Point(date: $0.date, value: tempUnit.convert(fromCelsius: $0.value))
        }
        let tempFloor = tempUnit.convertDelta(fromCelsius: tempFloorC)
        let temp = tile(.skinTemp, "Skin temp", "overnight", .thermometer, Theme.temp, tempUnit.symbol,
                        spokenUnit: tempUnit == .fahrenheit ? "degrees Fahrenheit" : "degrees Celsius",
                        pts: tempPts, floor: tempFloor, format: oneDecimal)

        // Steps: headline = today's total; trend = the last complete day vs the days before it.
        let stepPts = series { $0.steps.map(Double.init) }
        let completeDays = stepPts.filter { $0.date < today }
        let stepsTrend = BaselineTrend.evaluate(completeDays, minAbsoluteDelta: 1_000)
        let todaySteps = stepPts.first { $0.date == today }?.value
        let stepsFormat: (Double) -> String = { Int($0.rounded()).formatted(.number) }
        let steps = TodayTile(
            metric: .steps, title: "Steps", qualifier: todaySteps != nil ? "so far today" : "latest day",
            icon: .route, tint: Theme.steps,
            valueText: (todaySteps ?? stepPts.last?.value).map(stepsFormat),
            unit: "", sparkline: slots(stepPts), trend: stepsTrend,
            trendIsYesterday: stepsTrend?.latest.date == yesterday,
            staleAsOf: todaySteps == nil ? stepPts.last.map(\.date) : nil,
            spokenUnit: "steps", format: stepsFormat)

        return [hrv, rhr, spo2, rr, temp, steps]
    }
}
