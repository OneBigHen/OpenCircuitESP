// The Today synthesis line (#216): today's date and one plain-language sentence at the top of the
// Today tab. The sentence is `TodaySynthesis.sentence` (OpenCircuitKit, unit-tested); this file
// only gathers its inputs from what the tab already holds and draws it.

import SwiftUI
import OpenCircuitKit

/// What the readiness card is showing, handed up so the synthesis line agrees with it.
struct ReadinessReport: Equatable {
    var readiness: TodaySynthesis.Readiness
    /// Last night's asleep minutes, when a night that ended today is stored.
    var lastNightAsleepMin: Int?
}

extension TodaySynthesis {
    /// Assemble the synthesis input from the Today tab's state.
    ///
    /// - `trends`: the shared two-week load (tiles are built from the same data).
    /// - `readiness`: what the readiness card reported; nil until it has.
    /// - `lastSyncAt`: only used to tell "never had data" from "nothing in the last two weeks".
    static func input(trends: TrendsData, tiles: [TodayTile], readiness: ReadinessReport?,
                      lastSyncAt: Date?, now: Date = Date()) -> Input {
        func direction(_ m: TodayTile.Metric) -> BaselineTrend.Direction? {
            guard let t = tiles.first(where: { $0.metric == m }), t.staleAsOf == nil else { return nil }
            return t.trend?.direction
        }
        // Usual sleep = the nights BEFORE the newest one, so last night isn't compared with itself.
        let nights = trends.points.compactMap(\.sleepMinutes).filter { $0 > 0 }
        let prior = nights.dropLast()
        let usualSleep = prior.isEmpty ? nil : Double(prior.reduce(0, +)) / Double(prior.count)
        // Nothing in the window but the app HAS synced before: the data is at least as old as the
        // window, which is exactly what the "more than two weeks old" wording says.
        let newest = trends.newestSampleAt
            ?? lastSyncAt.flatMap { _ in Calendar.current.date(byAdding: .day, value: -TrendsData.lookbackDays, to: now) }
        return Input(readiness: readiness?.readiness ?? .pending,
                     hrv: direction(.hrv), restingHR: direction(.restingHR), skinTemp: direction(.skinTemp),
                     lastNightSleepMinutes: readiness?.lastNightAsleepMin, usualSleepMinutes: usualSleep,
                     newestDataAt: newest, now: now)
    }
}

struct TodaySynthesisHeader: View {
    let sentence: String
    var date: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                KeylineGlyph(.sparkles, size: 18, relativeTo: .title3)
                    .foregroundStyle(Theme.gold)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(sentence)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.default, value: sentence)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today, \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))). \(sentence)")
    }
}
