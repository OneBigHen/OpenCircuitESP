import XCTest
@testable import OpenCircuitKit

/// #239: one metric through one day. Synthetic data only.
final class IntradaySeriesTests: XCTestCase {

    /// A fixed UTC "day" so the grid is independent of the machine's zone.
    private let dayStart = Date(timeIntervalSince1970: 1_790_553_600)   // 2026-09-28 00:00 UTC
    private var day: DateInterval { DateInterval(start: dayStart, duration: 86_400) }
    private func at(_ minutes: Double) -> Date { dayStart.addingTimeInterval(minutes * 60) }
    private func p(_ minutes: Double, _ value: Double) -> IntradaySeries.Point {
        IntradaySeries.Point(time: at(minutes), value: value)
    }

    // MARK: Bucketing

    func testABucketHoldsItsMinMaxAndAverage() {
        let span = IntradaySeries.Span(family: .zeppOS, start: day.start, end: day.end)
        let points = [p(0, 60), p(1, 70), p(2, 65), p(3, 61), p(4, 64),   // 00:00–00:05
                      p(5, 80), p(9, 90)]                                 // 00:05–00:10
        let b = IntradaySeries.buckets(points, in: span, width: 300, origin: dayStart)
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[0].start, at(0)); XCTAssertEqual(b[0].end, at(5))
        XCTAssertEqual(b[0].min, 60); XCTAssertEqual(b[0].max, 70)
        XCTAssertEqual(b[0].mean, 64, accuracy: 1e-9); XCTAssertEqual(b[0].count, 5)
        XCTAssertEqual(b[1].min, 80); XCTAssertEqual(b[1].max, 90); XCTAssertEqual(b[1].mean, 85)
        XCTAssertEqual(b[1].mid, at(7.5))
    }

    func testTheLineBreaksAtAnEmptyBucketAndNeverBridgesIt() {
        // Per-minute readings 00:00–01:00, the strap off charging 01:00–02:00, back 02:00–03:00.
        var points: [IntradaySeries.Point] = []
        for m in 0..<60 { points.append(p(Double(m), 60)) }
        for m in 120..<180 { points.append(p(Double(m), 70)) }
        let d = IntradaySeries.day(points, day: day, log: DeviceOwnershipLog())
        XCTAssertEqual(d.series.count, 1)
        let series = d.series[0]
        XCTAssertEqual(series.bucketWidth, 300, "per-minute data gets 5-minute buckets")
        XCTAssertEqual(series.runs.count, 2, "the charging hour is a hole, not a straight line")
        XCTAssertEqual(series.runs[0].last?.end, at(60))
        XCTAssertEqual(series.runs[1].first?.start, at(120))
        XCTAssertEqual(series.runs.map(\.count), [12, 12])
        // Nothing is drawn inside the gap.
        XCTAssertFalse(series.buckets.contains { $0.end > at(60) && $0.start < at(120) })
    }

    func testOneMissingBucketIsAlreadyAGap() {
        let points = (0..<30).filter { !(10..<15).contains($0) }.map { p(Double($0), 50) }
        let runs = IntradaySeries.day(points, day: day, log: DeviceOwnershipLog()).series[0].runs
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].last?.end, at(10))
        XCTAssertEqual(runs[1].first?.start, at(15))
    }

    func testAnUnbrokenSeriesIsOneRun() {
        let points = (0..<1440).map { p(Double($0), 60) }
        let runs = IntradaySeries.day(points, day: day, log: DeviceOwnershipLog()).series[0].runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].count, 288)
    }

    func testTheBucketWidthFollowsTheDevicesOwnCadence() {
        XCTAssertEqual(IntradaySeries.bucketWidth(for: (0..<60).map { at(Double($0)) }), 300)
        XCTAssertEqual(IntradaySeries.bucketWidth(for: (0..<60).map { at(Double($0) * 5) }), 600)
        XCTAssertEqual(IntradaySeries.bucketWidth(for: (0..<20).map { at(Double($0) * 15) }), 1800)
        XCTAssertEqual(IntradaySeries.bucketWidth(for: (0..<10).map { at(Double($0) * 120) }), 3600)
        XCTAssertEqual(IntradaySeries.bucketWidth(for: [at(0)]), 300)
        XCTAssertEqual(IntradaySeries.bucketWidth(for: []), 300)
    }

    func testAFiveMinuteCadenceWithJitterLeavesNoFalseGap() {
        // Every 5 minutes ± up to 2 minutes: buckets wide enough that none is ever empty.
        let jitter: [Double] = [0, 2, -2, 1, -1, 2, 0, -2]
        let points = (0..<96).map { i in p(Double(i) * 5 + 2 + jitter[i % jitter.count], 60) }
        let series = IntradaySeries.day(points, day: day, log: DeviceOwnershipLog()).series[0]
        XCTAssertGreaterThanOrEqual(series.bucketWidth, 600)
        XCTAssertLessThanOrEqual(series.bucketWidth, 900)
        XCTAssertEqual(series.runs.count, 1, "jitter alone never breaks the line")
    }

    // MARK: Ownership (decision 28)

    func testASwitchGivesTwoSeriesThatMeetAtTheSwitchAndNeverOverlap() {
        let switchAt = at(14 * 60 + 2)   // 14:02, inside a 5-minute bucket
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)])
        let points = (0..<1440).map { p(Double($0), $0 < 14 * 60 + 2 ? 60 : 70) }
        let d = IntradaySeries.day(points, day: day, log: log)

        XCTAssertEqual(d.series.map(\.family), [.ringConn, .zeppOS])
        let ring = d.series[0], strap = d.series[1]
        XCTAssertEqual(ring.span.start, day.start)
        XCTAssertEqual(ring.span.end, switchAt)
        XCTAssertEqual(strap.span.start, switchAt, "the two stretches meet at the switch")
        XCTAssertEqual(strap.span.end, day.end)
        // Never overlap: every ring bucket ends by the switch, every strap bucket starts at or after it.
        XCTAssertTrue(ring.buckets.allSatisfy { $0.end <= switchAt })
        XCTAssertTrue(strap.buckets.allSatisfy { $0.start >= switchAt })
        XCTAssertEqual(ring.buckets.last?.end, switchAt, "the bucket the switch lands in is split at it")
        XCTAssertEqual(strap.buckets.first?.start, switchAt)
        XCTAssertTrue(ring.points.allSatisfy { $0.time < switchAt })
        XCTAssertTrue(strap.points.allSatisfy { $0.time >= switchAt })
        XCTAssertEqual(ring.points.count + strap.points.count, 1440, "every reading in exactly one series")
        XCTAssertEqual(d.families, [.ringConn, .zeppOS])
    }

    func testSpansTileTheDayAndFollowEveryEntry() {
        let a = at(8 * 60), b = at(20 * 60)
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: a), .init(family: .ringConn, since: b)])
        let spans = IntradaySeries.spans(of: day, log: log)
        XCTAssertEqual(spans, [
            .init(family: .ringConn, start: day.start, end: a),
            .init(family: .zeppOS, start: a, end: b),
            .init(family: .ringConn, start: b, end: day.end),
        ])
        // A switch before the day: one stretch, the device chosen then.
        let earlier = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: dayStart.addingTimeInterval(-3600))])
        XCTAssertEqual(IntradaySeries.spans(of: day, log: earlier), [.init(family: .zeppOS, start: day.start, end: day.end)])
        // A strap-only install (`.distantPast`): the strap's all day.
        let strapOnly = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast)])
        XCTAssertEqual(IntradaySeries.spans(of: day, log: strapOnly).map(\.family), [.zeppOS])
        // A switch exactly at midnight belongs to the new device for the whole day.
        let atMidnight = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: day.start)])
        XCTAssertEqual(IntradaySeries.spans(of: day, log: atMidnight), [.init(family: .zeppOS, start: day.start, end: day.end)])
    }

    func testRingOnlyIsOneRingSeriesOverTheWholeDay() {
        let points = (0..<100).map { p(Double($0) * 10, 55) }
        let d = IntradaySeries.day(points, day: day, log: DeviceOwnershipLog())
        XCTAssertEqual(d.series.count, 1)
        XCTAssertEqual(d.series[0].span, .init(family: .ringConn, start: day.start, end: day.end))
        XCTAssertEqual(d.series[0].points, points)
        XCTAssertEqual(d.averages, [.ringConn: 55])
    }

    // MARK: Per-device averages (decision 29)

    func testEachDeviceHasItsOwnAverageAndNeverAMixedOne() {
        // Ring-finger skin temperature 35–36 °C until 12:00, strap-arm 32–33 °C after.
        let switchAt = at(12 * 60)
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)])
        let points = [p(60, 35), p(120, 36), p(13 * 60, 32), p(14 * 60, 33), p(15 * 60, 32.5)]
        let d = IntradaySeries.day(points, day: day, log: log)
        XCTAssertEqual(d.averages[.ringConn]!, 35.5, accuracy: 1e-9)
        XCTAssertEqual(d.averages[.zeppOS]!, 32.5, accuracy: 1e-9)
        XCTAssertEqual(d.averages.count, 2, "no averaged-together value exists")
    }

    func testADevicesAverageSpansAllItsStretchesOfTheDay() {
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(600)), .init(family: .ringConn, since: at(900))])
        let points = [p(100, 50), p(700, 80), p(1000, 70)]
        let d = IntradaySeries.day(points, day: day, log: log)
        XCTAssertEqual(d.series.map(\.family), [.ringConn, .zeppOS, .ringConn])
        XCTAssertEqual(d.averages[.ringConn]!, 60, accuracy: 1e-9)
        XCTAssertEqual(d.averages[.zeppOS]!, 80, accuracy: 1e-9)
        XCTAssertEqual(d.families, [.ringConn, .zeppOS])
    }

    func testADeviceWithNoReadingsHasNoAverage() {
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(600))])
        let d = IntradaySeries.day([p(100, 50)], day: day, log: log)
        XCTAssertEqual(d.averages, [.ringConn: 50])
        XCTAssertEqual(d.families, [.ringConn])
    }

    // MARK: Scrub

    func testScrubReadsTheExactNearestReadingAndItsDevice() {
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(600))])
        let d = IntradaySeries.day([p(590, 61), p(601, 73), p(700, 64)], day: day, log: log)
        let hit = IntradaySeries.nearest(to: at(603), in: d)
        XCTAssertEqual(hit?.point, p(601, 73))
        XCTAssertEqual(hit?.family, .zeppOS)
        XCTAssertEqual(IntradaySeries.nearest(to: at(589), in: d)?.family, .ringConn)
        XCTAssertNil(IntradaySeries.nearest(to: at(0), in: IntradaySeries.day([], day: day, log: log)))
    }

    func testPointsOutsideTheDayAreIgnored() {
        let d = IntradaySeries.day([p(-1, 99), p(10, 60), p(1440, 99)], day: day, log: DeviceOwnershipLog())
        XCTAssertEqual(d.points, [p(10, 60)])
    }

    // MARK: Load check (#239)

    /// A synthetic full strap day: 1440 per-minute heart rates and 288 stress values. Builds both
    /// days and reports the time, so the report can quote it.
    func testAFullStrapDayBucketsQuickly() {
        let log = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast)])
        let hr = (0..<1440).map { p(Double($0), 60 + Double($0 % 37)) }
        let stress = (0..<288).map { p(Double($0) * 5, Double($0 % 100)) }
        let clock = ContinuousClock()
        var hrDay: IntradaySeries.Day?
        var stressDay: IntradaySeries.Day?
        let elapsed = clock.measure {
            hrDay = IntradaySeries.day(hr, day: day, log: log)
            stressDay = IntradaySeries.day(stress, day: day, log: log)
        }
        XCTAssertEqual(hrDay?.series.first?.buckets.count, 288)
        XCTAssertEqual(stressDay?.series.first?.buckets.count, 144, "5-minute stress gets 10-minute buckets")
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("IntradaySeries load check: 1440 HR + 288 stress bucketed in \(String(format: "%.2f", ms)) ms")
        XCTAssertLessThan(ms, 250)
    }
}
