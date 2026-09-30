// The Helio Strap's app-side rules (HelioSyncPolicy.swift, #215 phase 3). Every fixture is synthetic:
// made-up keys, made-up readings, times chosen by hand.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

// MARK: - Fixture builders

/// 2026-09-30T00:00:00Z.
private let midnight: TimeInterval = 1_790_726_400

/// One 8-byte activity minute (§6.5): kind, intensity, steps, HR, unknown, sleep, deep, REM.
private func activityRecord(kind: UInt8 = 0x01, steps: UInt8 = 0, hr: UInt8 = 60) -> [UInt8] {
    [kind, 0x10, steps, hr, 0x00, 0x00, 0x00, 0x00]
}

/// One 8-byte temperature minute (§6.5): i16 unknown, i16 centi-°C, i16, i16.
private func temperatureRecord(centi: Int16) -> [UInt8] {
    let raw = UInt16(bitPattern: centi)
    return [0xff, 0x7f, UInt8(raw & 0xff), UInt8(raw >> 8), 0x5a, 0x5a, 0x5a, 0x5a]
}

/// A 594-byte sleep-session record (§6.6). Minutes count from `midnightRef` − 24 h.
private func sessionRecord(midnightRef: TimeInterval = midnight, stages: [(start: UInt16, end: UInt16, type: UInt8)],
                           score: UInt8 = 80) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(midnightRef)), at: 0x000)
    put(le32(UInt32(midnightRef)), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(stages.first?.start ?? 0), at: 0x00A)
    put(le16(stages.last?.end ?? 0), at: 0x00C)
    r[0x015] = 55
    r[0x016] = score
    r[0x054] = UInt8(stages.count)
    for (i, s) in stages.enumerated() {
        put(le16(s.start) + le16(s.end) + [s.type], at: 0x056 + 5 * i)
    }
    return r
}

private func parseSessions(_ records: [[UInt8]]) throws -> [ZeppSleepSession] {
    let parsed = try ZeppRecordParser.parse(.sleepSession, data: records.flatMap { $0 }, start: date(0))
    guard case .sleepSession(let sessions) = parsed.records else { XCTFail("not a session batch"); return [] }
    return sessions
}

/// Absolute time of a session minute: previous midnight + minutes.
private func sessionTime(_ minutes: Int, midnightRef: TimeInterval = midnight) -> Date {
    date(midnightRef - 86_400 + TimeInterval(minutes) * 60)
}

// MARK: - Key text (decision 4)

final class HelioKeyTextTests: XCTestCase {
    private let digits = "00112233445566778899aabbccddeeff"

    func testAcceptsTheFormsPeoplePaste() {
        let forms = [
            digits,
            digits.uppercased(),
            "0x" + digits,
            "0X" + digits.uppercased(),
            "  \(digits)\n",
            "00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff",
            "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF",
            "0x 0011 2233\t4455:6677 8899 aabb ccdd eeff",
        ]
        for form in forms {
            XCTAssertEqual(HelioKeyText.normalized(form), digits, form)
            XCTAssertEqual(HelioKeyText.parse(form), ZeppAuthKey(hex: digits), form)
        }
    }

    func testRejectsEverythingElse() {
        let rejects = [
            "",
            "0x",
            String(digits.dropLast()),                        // 31 digits
            digits + "0",                                     // 33 digits
            "00112233-44556677-8899aabb-ccddeeff",            // hyphens are not accepted
            "g0112233445566778899aabbccddeeff",               // not hex
            "00 0x112233445566778899aabbccddeeff",            // 0x only as a leading prefix
            "０0112233445566778899aabbccddeeff",               // full-width zero
            "0x0x" + digits,                                  // one prefix only
        ]
        for text in rejects {
            XCTAssertNil(HelioKeyText.normalized(text), text)
            XCTAssertNil(HelioKeyText.parse(text), text)
        }
    }
}

// MARK: - Health policy and store mapping (decisions 10, 14, 16)

final class HelioHealthPolicyTests: XCTestCase {

    func testHRVIsNeverAHealthKindInV1() {
        XCTAssertFalse(HelioHealthPolicy.writesHRV)
        XCTAssertEqual(HelioHealthPolicy.healthMirroredKinds(), [.heartRate, .spo2, .respiratoryRate, .temperature])
        XCTAssertFalse(HelioHealthPolicy.healthMirroredKinds().contains(.hrvSDNN))
        // The one switch, flipped, is the only way HRV joins.
        XCTAssertTrue(HelioHealthPolicy.healthMirroredKinds(writesHRV: true).contains(.hrvSDNN))
    }

    func testHRVIsStoredLocallyButStaysOutOfTheHealthMapping() throws {
        // Two made-up records (worked example D's shape) plus a 0 ms "no reading".
        let hrv = try ZeppRecordParser.parse(.hrv, data: hex("8c e4 ba 6a 08 2a b8 e5 ba 6a 08 39 e4 e6 ba 6a 08 00"),
                                             start: date(0))
        XCTAssertEqual(ZeppMetricMapping.samples(from: hrv), [], "the Health-clean mapping keeps HRV out")
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: hrv), [
            QuantitySample(kind: .hrvSDNN, start: date(1_790_633_100), value: 42),
            QuantitySample(kind: .hrvSDNN, start: date(1_790_633_400), value: 57),
        ])
    }

    func testActivitySplitsIntoHeartRateAndStepMinutes() throws {
        let data = activityRecord(steps: 12, hr: 70) + activityRecord(steps: 0, hr: 0xff) + activityRecord(steps: 3, hr: 0)
        let parsed = try ZeppRecordParser.parse(.activity, data: data, start: date(midnight))
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed), [
            QuantitySample(kind: .heartRate, start: date(midnight), value: 70),
        ], "HR only; no-reading bytes dropped, steps go to the step ledger")
        XCTAssertEqual(ZeppMetricMapping.stepMinutes(from: parsed), [
            QuantitySample(kind: .steps, start: date(midnight), end: date(midnight + 60), value: 12),
            QuantitySample(kind: .steps, start: date(midnight + 120), end: date(midnight + 180), value: 3),
        ], "each minute's own count over its own minute, zero minutes omitted")
    }

    func testTemperatureNeverEntersTheStoreUngated() throws {
        let parsed = try ZeppRecordParser.parse(.temperature, data: temperatureRecord(centi: 3350), start: date(midnight))
        XCTAssertEqual(ZeppMetricMapping.storedSamples(from: parsed), [])
    }
}

// MARK: - Skin temperature gate (decision 12)

final class HelioSkinTemperatureGateTests: XCTestCase {
    /// 23:00 → 07:00.
    private let night = DateInterval(start: date(midnight - 3600), end: date(midnight + 7 * 3600))

    private func temperatures(_ centis: [Int16], from start: TimeInterval) throws -> [ZeppTemperatureMinute] {
        let parsed = try ZeppRecordParser.parse(.temperature, data: centis.flatMap(temperatureRecord), start: date(start))
        guard case .temperature(let minutes) = parsed.records else { throw XCTSkip("not temperature") }
        return minutes
    }

    private func activity(_ kinds: [UInt8], from start: TimeInterval) throws -> [ZeppActivityMinute] {
        let parsed = try ZeppRecordParser.parse(.activity, data: kinds.flatMap { activityRecord(kind: $0) }, start: date(start))
        guard case .activity(let minutes) = parsed.records else { throw XCTSkip("not activity") }
        return minutes
    }

    func testKeepsOnlyWornInWindowReadingsInRange() throws {
        let start = midnight   // inside the night
        let temps = try temperatures([3350, 3360, 3370, 3380, 2999, 4201, 3000, 4200, Int16.max], from: start)
        let kinds: [UInt8] = [0x01, 0x73, 0x76, 0x78, 0x01, 0x01, 0x01, 0x78, 0x01]
        let kept = HelioSkinTemperatureGate.samples(temperatures: temps, activity: try activity(kinds, from: start),
                                                    sleepWindows: [night])
        XCTAssertEqual(kept, [
            QuantitySample(kind: .temperature, start: date(start), value: 33.5),
            QuantitySample(kind: .temperature, start: date(start + 180), value: 33.8),   // sleep kind 0x78 is worn
            QuantitySample(kind: .temperature, start: date(start + 360), value: 30.0),   // both band edges kept
            QuantitySample(kind: .temperature, start: date(start + 420), value: 42.0),
        ])
    }

    func testEachExclusionIsNamed() throws {
        let temps = try temperatures([3350, 3350, 3350, 3350, 2999, 4201], from: midnight)
        let window = [night]
        XCTAssertEqual(HelioSkinTemperatureGate.exclusion(for: temps[0], activityKind: 0x73, sleepWindows: window), .notWorn)
        XCTAssertEqual(HelioSkinTemperatureGate.exclusion(for: temps[1], activityKind: 0x76, sleepWindows: window), .charging)
        XCTAssertEqual(HelioSkinTemperatureGate.exclusion(for: temps[2], activityKind: nil, sleepWindows: window), .wearUnknown)
        XCTAssertEqual(HelioSkinTemperatureGate.exclusion(for: temps[3], activityKind: 0x01, sleepWindows: []), .outsideSleepWindow)
        XCTAssertEqual(HelioSkinTemperatureGate.exclusion(for: temps[4], activityKind: 0x01, sleepWindows: window), .noReadingInRange)
        XCTAssertEqual(HelioSkinTemperatureGate.exclusion(for: temps[5], activityKind: 0x01, sleepWindows: window), .noReadingInRange)
        XCTAssertNil(HelioSkinTemperatureGate.exclusion(for: temps[0], activityKind: 0x01, sleepWindows: window))
    }

    func testDaytimeAndWindowEdgeMinutesAreOutside() throws {
        // 22:58, 22:59 before the window; 07:00 is the window's end, so outside (half-open).
        let before = try temperatures([3350, 3350, 3350], from: midnight - 3600 - 120)
        let atEnd = try temperatures([3350], from: midnight + 7 * 3600)
        let temps = before + atEnd
        let acts = try activity([0x01, 0x01, 0x01], from: midnight - 3600 - 120) + (try activity([0x01], from: midnight + 7 * 3600))
        let kept = HelioSkinTemperatureGate.samples(temperatures: temps, activity: acts, sleepWindows: [night])
        XCTAssertEqual(kept.map(\.start), [date(midnight - 3600)], "only 23:00, the window's first minute")
    }

    func testWithoutASleepWindowNothingIsKept() throws {
        let temps = try temperatures(Array(repeating: 3350, count: 10), from: midnight)
        let acts = try activity(Array(repeating: 0x01, count: 10), from: midnight)
        XCTAssertEqual(HelioSkinTemperatureGate.samples(temperatures: temps, activity: acts, sleepWindows: []), [])
    }
}

// MARK: - Sleep-stage selection (decision 13)

final class HelioSleepSelectionTests: XCTestCase {
    private let now = date(midnight + 10 * 3600)   // 10:00 the morning after

    func testTheStrapsStagesMapOntoSleepStages() throws {
        // 23:00 light, 23:30 deep, 00:30 REM, 01:00 awake, 01:05 unknown 0x09, ends 01:30.
        let sessions = try parseSessions([sessionRecord(stages: [
            (1380, 1410, 0x04), (1410, 1470, 0x05), (1470, 1500, 0x08), (1500, 1505, 0x07), (1505, 1530, 0x09),
        ])])
        let night = try XCTUnwrap(HelioSleepSelection.night(from: sessions[0], now: now))
        XCTAssertEqual(night.segments, [
            SleepSegment(start: sessionTime(1380), end: sessionTime(1410), stage: .asleepCore),
            SleepSegment(start: sessionTime(1410), end: sessionTime(1470), stage: .asleepDeep),
            SleepSegment(start: sessionTime(1470), end: sessionTime(1500), stage: .asleepREM),
            SleepSegment(start: sessionTime(1500), end: sessionTime(1505), stage: .awake),
            SleepSegment(start: sessionTime(1505), end: sessionTime(1530), stage: .asleepCore),
        ])
        XCTAssertEqual(night.window, DateInterval(start: sessionTime(1380), end: sessionTime(1530)))
        XCTAssertEqual(night.strapScore, 80)
        XCTAssertFalse(night.segments.contains { $0.stage == .inBed }, "no in-bed span is invented")
        XCTAssertTrue(night.segments.allSatisfy { $0.provenance == .measured })
    }

    func testGapsStayGapsAndOverlapsAreTrimmed() throws {
        let sessions = try parseSessions([sessionRecord(stages: [
            (1380, 1420, 0x04), (1410, 1440, 0x05),   // overlaps the previous by 10 min
            (1450, 1500, 0x04),                        // 10-minute gap before it
            (1490, 1495, 0x08),                        // entirely inside the previous: dropped
        ])])
        let night = try XCTUnwrap(HelioSleepSelection.night(from: sessions[0], now: now))
        XCTAssertEqual(night.segments, [
            SleepSegment(start: sessionTime(1380), end: sessionTime(1420), stage: .asleepCore),
            SleepSegment(start: sessionTime(1420), end: sessionTime(1440), stage: .asleepDeep),
            SleepSegment(start: sessionTime(1450), end: sessionTime(1500), stage: .asleepCore),
        ])
    }

    func testImplausibleNightsAreDropped() throws {
        let awakeOnly = try parseSessions([sessionRecord(stages: [(1380, 1440, 0x07)])])
        XCTAssertNil(HelioSleepSelection.night(from: awakeOnly[0], now: now), "no sleep in it")
        let tooLong = try parseSessions([sessionRecord(stages: [(600, 1900, 0x04)])])   // 21 h 40 min
        XCTAssertNil(HelioSleepSelection.night(from: tooLong[0], now: now))
        let future = try parseSessions([sessionRecord(stages: [(1380, 1440, 0x04)])])
        XCTAssertNil(HelioSleepSelection.night(from: future[0], now: date(midnight - 3 * 3600)), "ends after now")
        let empty = try parseSessions([sessionRecord(stages: [(1380, 1380, 0x04)])])
        XCTAssertNil(HelioSleepSelection.night(from: empty[0], now: now))
    }

    func testRedeliveredSessionsCollapseToOneNight() throws {
        let one = sessionRecord(stages: [(1380, 1440, 0x04), (1440, 1800, 0x05)])
        let sessions = try parseSessions([one, one])
        XCTAssertEqual(HelioSleepSelection.nights(from: sessions, now: now).count, 1)
    }

    func testAManuallyEditedNightIsNeverOverwritten() throws {
        let lastNight = try parseSessions([sessionRecord(stages: [(1380, 1860, 0x04)])])
        let nightBefore = try parseSessions([sessionRecord(midnightRef: midnight - 86_400, stages: [(1380, 1860, 0x04)])])
        let nights = HelioSleepSelection.nights(from: nightBefore + lastNight, now: now)
        XCTAssertEqual(nights.count, 2)
        // The person edited last night to 23:30 → 06:00.
        let edited = DateInterval(start: date(midnight - 1800), end: date(midnight + 6 * 3600))
        let kept = HelioSleepSelection.nightsToWrite(nights, manuallyEdited: [edited])
        XCTAssertEqual(kept, [nights[0]], "only the unedited night before is written")
        // A window that only touches the night's edge is not an overlap.
        let touching = DateInterval(start: nights[1].window.end, end: nights[1].window.end.addingTimeInterval(600))
        XCTAssertEqual(HelioSleepSelection.nightsToWrite(nights, manuallyEdited: [touching]), nights)
    }
}

// MARK: - Fetch plan and watermarks

final class HelioFetchPlanTests: XCTestCase {
    /// 2026-09-30T12:34:56Z.
    private let now = date(midnight + 12 * 3600 + 34 * 60 + 56)
    private var nowMinute: Date { date(midnight + 12 * 3600 + 34 * 60) }

    private func since(_ plan: [(type: ZeppFetchType, since: Date)], _ type: ZeppFetchType) -> Date? {
        plan.first { $0.type == type }?.since
    }

    func testFirstSyncReachesAWeekBackForEveryType() {
        let plan = HelioFetchPlan.plan(cursors: [:], now: now)
        XCTAssertEqual(plan.map(\.type), HelioFetchPlan.types)
        let weekBack = nowMinute.addingTimeInterval(-7 * 86_400)
        for (type, start) in plan where type != .sleepSession {
            XCTAssertEqual(start, weekBack, "\(type)")
        }
        // Sessions reach a day further so the oldest temperature minutes have their night.
        XCTAssertEqual(since(plan, .sleepSession), weekBack.addingTimeInterval(-86_400))
    }

    func testActivityAndSleepAreFetchedBeforeTemperature() {
        let order = HelioFetchPlan.types
        let temperature = order.firstIndex(of: .temperature)!
        XCTAssertLessThan(order.firstIndex(of: .activity)!, temperature)
        XCTAssertLessThan(order.firstIndex(of: .sleepSession)!, temperature)
        XCTAssertFalse(order.contains(.sleepSpO2), "0x26's layout is 🔴")
        XCTAssertFalse(order.contains(.maxHeartRate))
    }

    func testWatermarksAreHonouredAndClamped() {
        let hourAgo = now.addingTimeInterval(-3600)
        let plan = HelioFetchPlan.plan(cursors: [
            .spo2: hourAgo,
            .hrv: now.addingTimeInterval(-60 * 86_400),              // older than the retention: clamped
            .pai: now.addingTimeInterval(3 * 60),                    // a strap clock slightly ahead: clamped to now
            .restingHeartRate: now.addingTimeInterval(3600),         // far ahead: unknown, first-sync window
        ], now: now)
        XCTAssertEqual(since(plan, .spo2), HelioFetchPlan.floorToMinute(hourAgo))
        XCTAssertEqual(since(plan, .hrv), HelioFetchPlan.floorToMinute(now.addingTimeInterval(-30 * 86_400)))
        XCTAssertEqual(since(plan, .pai), nowMinute)
        XCTAssertEqual(since(plan, .restingHeartRate), nowMinute.addingTimeInterval(-7 * 86_400))
        for (_, start) in plan { XCTAssertEqual(start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0) }
    }

    func testActivityAndSessionsRewindToTheTemperatureWatermark() {
        let temperature = now.addingTimeInterval(-6 * 3600)
        let plan = HelioFetchPlan.plan(cursors: [
            .activity: now.addingTimeInterval(-600),
            .sleepSession: now.addingTimeInterval(-3600),
            .temperature: temperature,
        ], now: now)
        XCTAssertEqual(since(plan, .activity), HelioFetchPlan.floorToMinute(temperature))
        XCTAssertEqual(since(plan, .sleepSession), HelioFetchPlan.floorToMinute(temperature).addingTimeInterval(-86_400))
        XCTAssertEqual(since(plan, .temperature), HelioFetchPlan.floorToMinute(temperature))

        // An activity watermark already behind temperature's stays where it is.
        let behind = HelioFetchPlan.plan(cursors: [.activity: now.addingTimeInterval(-9 * 3600), .temperature: temperature],
                                         now: now)
        XCTAssertEqual(since(behind, .activity), HelioFetchPlan.floorToMinute(now.addingTimeInterval(-9 * 3600)))
    }

    func testCursorNamesRoundTripAndAreNotMetricKinds() {
        for type in ZeppFetchType.allCases {
            let name = HelioFetchPlan.cursorName(for: type)
            XCTAssertEqual(HelioFetchPlan.type(forCursorName: name), type)
            XCTAssertNil(MetricKind(rawValue: name))
        }
        XCTAssertEqual(HelioFetchPlan.cursorName(for: .temperature), "zepp.fetch.2e")
        XCTAssertNil(HelioFetchPlan.type(forCursorName: "heartRate"))
        XCTAssertNil(HelioFetchPlan.type(forCursorName: "zepp.fetch.zz"))
        XCTAssertNil(HelioFetchPlan.type(forCursorName: "zepp.fetch.ff"))
    }

    func testTheWatermarkOnlyMovesForwardAndNeverPastNow() throws {
        func round(nextSince: Date?) -> ZeppFetchRound {
            let parsed = ZeppParsedRecords(type: .spo2, records: .spo2([]), skippedRecords: 0, lastRecordTime: nil)
            return ZeppFetchRound(id: 1, type: .spo2, since: date(0), start: date(0), rawData: [], crcVerified: true,
                                  parsed: parsed, nextSince: nextSince)
        }
        let previous = now.addingTimeInterval(-3600)
        XCTAssertEqual(HelioFetchPlan.advancedCursor(previous: previous, round: round(nextSince: nil), now: now), previous)
        XCTAssertNil(HelioFetchPlan.advancedCursor(previous: nil, round: round(nextSince: nil), now: now))
        let later = now.addingTimeInterval(-60)
        XCTAssertEqual(HelioFetchPlan.advancedCursor(previous: previous, round: round(nextSince: later), now: now), later)
        XCTAssertEqual(HelioFetchPlan.advancedCursor(previous: previous, round: round(nextSince: now.addingTimeInterval(600)), now: now),
                       nowMinute, "never past now")
        XCTAssertEqual(HelioFetchPlan.advancedCursor(previous: previous, round: round(nextSince: previous.addingTimeInterval(-7200)), now: now),
                       previous, "a re-delivered older round never moves it back")
    }
}
