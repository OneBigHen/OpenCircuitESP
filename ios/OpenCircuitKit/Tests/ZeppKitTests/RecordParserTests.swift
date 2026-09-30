// Record parsers (§6.5–§6.6) on synthetic records built from the spec's layouts, plus truncated,
// oversized and random input: parsers must never trap and never read past the data.

import XCTest
@testable import ZeppKit

final class RecordParserTests: XCTestCase {

    private let start = date(1_790_632_800)

    private func parse(_ type: ZeppFetchType, _ data: [UInt8]) throws -> ZeppParsedRecords {
        try ZeppRecordParser.parse(type, data: data, start: start)
    }

    // MARK: Per-minute types

    func testActivityMinutes() throws {
        let data = hex("01 20 0c 48 00 81 82 83") + hex("73 00 00 ff 00 00 00 00") + hex("78 05 00 00 11 7f ff 00")
        let parsed = try parse(.activity, data)
        guard case .activity(let m) = parsed.records else { return XCTFail() }
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m.map(\.time), [start, start + 60, start + 120])
        XCTAssertEqual(m[0].kind, 0x01)
        XCTAssertEqual(m[0].intensity, 0x20)
        XCTAssertEqual(m[0].steps, 12)
        XCTAssertEqual(m[0].heartRate, 72)
        XCTAssertEqual([m[0].sleep, m[0].deepSleep, m[0].rem], [0x01, 0x02, 0x03])   // low 7 bits
        XCTAssertNil(m[1].heartRate)                                                     // ff
        XCTAssertEqual(m[1].kind, ZeppActivityMinute.kindNotWorn)
        XCTAssertNil(m[2].heartRate)                                                     // 00
        XCTAssertEqual([m[2].sleep, m[2].deepSleep, m[2].rem], [0x7f, 0x7f, 0x00])
        XCTAssertEqual(parsed.lastRecordTime, start + 120)
    }

    func testAutoStressMinutes() throws {
        let parsed = try parse(.autoStress, [0x00, 0x27, 0xff, 0x64, 0x65])
        guard case .autoStress(let m) = parsed.records else { return XCTFail() }
        XCTAssertEqual(m.map(\.level), [0, 39, nil, 100, nil])
        XCTAssertEqual(m.last?.time, start + 240)                // `ff` still advances the minute
        XCTAssertEqual(try parse(.autoStress, []).lastRecordTime, nil)
    }

    func testTemperatureMinutes() throws {
        func minute(_ centi: Int16) -> [UInt8] { le16(0x7fff) + le16(UInt16(bitPattern: centi)) + le16(0x5a5a) + le16(0x5a5a) }
        let parsed = try parse(.temperature, minute(3456) + minute(0x7fff) + minute(-32768) + minute(1999) + minute(4501) + minute(2000))
        guard case .temperature(let m) = parsed.records else { return XCTFail() }
        XCTAssertEqual(m.map(\.celsius), [34.56, nil, nil, nil, nil, 20.0])
        XCTAssertEqual(m[0].unknown0, 0x7fff)
        XCTAssertEqual(m[0].unknown2, 0x5a5a)
    }

    // MARK: Timestamped types

    func testSixByteHeartRateTypes() throws {
        let data = le32(1_790_600_000) + [0x08, 58] + le32(1_790_686_400) + [0xEC, 0xFF]
        for type in [ZeppFetchType.manualHeartRate, .restingHeartRate, .maxHeartRate] {
            let parsed = try parse(type, data)
            let readings: [ZeppHeartRateReading]
            switch parsed.records {
            case .manualHeartRate(let r), .restingHeartRate(let r), .maxHeartRate(let r): readings = r
            default: return XCTFail()
            }
            XCTAssertEqual(readings.map(\.beatsPerMinute), [58, nil])
            XCTAssertEqual(readings.map(\.utcOffsetQuarterHours), [8, -20])
            XCTAssertEqual(parsed.lastRecordTime, date(1_790_686_400))
        }
    }

    func testHRV() throws {
        let parsed = try parse(.hrv, hex("8c e4 ba 6a 08 2a b8 e5 ba 6a 08 39"))
        XCTAssertEqual(parsed.records, .hrv([ZeppHRVReading(time: date(1_790_633_100), unknown: 8, milliseconds: 42),
                                             ZeppHRVReading(time: date(1_790_633_400), unknown: 8, milliseconds: 57)]))
    }

    func testManualStress() throws {
        let parsed = try parse(.manualStress, le32(1_790_600_000) + [45] + le32(1_790_600_060) + [0xff])
        guard case .manualStress(let r) = parsed.records else { return XCTFail() }
        XCTAssertEqual(r.map(\.level), [45, nil])
    }

    func testSpO2() throws {
        func record(_ ts: UInt32, _ value: UInt8) -> [UInt8] { le32(ts) + [value] + [UInt8](repeating: 0xEE, count: 60) }
        let parsed = try parse(.spo2, [0x02] + record(1_790_600_000, 0x80 | 97) + record(1_790_600_600, 95) + record(1_790_601_200, 0x80))
        guard case .spo2(let r) = parsed.records else { return XCTFail() }
        XCTAssertEqual(r.map(\.percent), [97, 95, nil])
        XCTAssertEqual(r.map(\.isAutomatic), [true, false, true])
        XCTAssertEqual(parsed.lastRecordTime, date(1_790_601_200))
        XCTAssertThrowsError(try parse(.spo2, [0x03] + record(1, 90))) {
            XCTAssertEqual($0 as? ZeppRecordParser.Error, .unsupportedVersion(type: .spo2, version: 3))
        }
        XCTAssertEqual(try parse(.spo2, [0x02]).records.count, 0)
    }

    func testSleepSpO2() throws {
        let record = le32(1_790_600_000) + [96, 30] + [UInt8](1...6) + [UInt8](7...12) + [UInt8](13...20) + [UInt8](21...24)
        let parsed = try parse(.sleepSpO2, [0x02] + record)
        guard case .sleepSpO2(let r) = parsed.records else { return XCTFail() }
        XCTAssertEqual(r.first?.percent, 96)
        XCTAssertEqual(r.first?.duration, 30)
        XCTAssertEqual(r.first?.high, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(r.first?.low, [7, 8, 9, 10, 11, 12])
        XCTAssertEqual(r.first?.signalQuality, [UInt8](13...20))
        XCTAssertEqual(r.first?.extended, [21, 22, 23, 24])
    }

    func testRespiratoryRate() throws {
        let parsed = try parse(.sleepRespiratoryRate, le32(1_790_600_000) + [0x08, 14, 0x00, 0x01])
        XCTAssertEqual(parsed.records, .sleepRespiratoryRate([
            ZeppRespiratoryRateReading(time: date(1_790_600_000), utcOffsetQuarterHours: 8, breathsPerMinute: 14,
                                       unknown6: 0, unknown7: 1),
        ]))
    }

    private func paiRecord(type: UInt8, ts: UInt32) -> [UInt8] {
        var r: [UInt8] = [type] + le32(ts) + [0x08] + [UInt8](repeating: 0xAA, count: 31)
        for f in [Float(1.5), 2.5, 3.5] { r += le32(f.bitPattern) }
        r += le16(10) + le16(20) + le16(30)
        for f in [Float(12.25), 87.5] { r += le32(f.bitPattern) }
        r += [UInt8](repeating: 0xBB, count: 39)
        return r
    }

    func testPAI() throws {
        XCTAssertEqual(paiRecord(type: 5, ts: 0).count, 102)
        let parsed = try parse(.pai, paiRecord(type: 0x05, ts: 1_790_600_000) + paiRecord(type: 0x00, ts: 1_790_686_400)
                               + paiRecord(type: 0x07, ts: 1_790_700_000))
        guard case .pai(let r) = parsed.records else { return XCTFail() }
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(parsed.skippedRecords, 2)
        XCTAssertEqual(parsed.lastRecordTime, date(1_790_700_000))
        XCTAssertEqual(r[0].lowZonePAI, 1.5)
        XCTAssertEqual(r[0].highZonePAI, 3.5)
        XCTAssertEqual([r[0].lowZoneMinutes, r[0].moderateZoneMinutes, r[0].highZoneMinutes], [10, 20, 30])
        XCTAssertEqual(r[0].todayPAI, 12.25)
        XCTAssertEqual(r[0].totalPAI, 87.5)
        XCTAssertEqual(r[0].utcOffsetQuarterHours, 8)
    }

    // MARK: Sleep session (§6.6)

    /// A 594-byte session: midnight 2026-09-29 00:00 +02:00 (22:00Z on the 28th), sleep from minute
    /// 1380 (23:00 local on the 28th) to 1860 (07:00 local on the 29th).
    private func sessionRecord(stages: [(UInt16, UInt16, UInt8)], count: UInt8? = nil) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 594)
        func put16(_ v: UInt16, _ at: Int) { r[at] = UInt8(v & 0xFF); r[at + 1] = UInt8(v >> 8) }
        func put32(_ v: UInt32, _ at: Int) { for i in 0..<4 { r[at + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        put32(1_790_650_000, 0x000)
        put32(1_790_632_800, 0x004)
        r[0x008] = 1; r[0x009] = 1
        put16(1380, 0x00A)
        put16(1860, 0x00C)
        r[0x015] = 54
        r[0x016] = 81
        r[0x054] = count ?? UInt8(stages.count)
        for (i, s) in stages.enumerated() where i < 100 {
            put16(s.0, 0x056 + 5 * i); put16(s.1, 0x056 + 5 * i + 2); r[0x056 + 5 * i + 4] = s.2
        }
        put16(95, 0x24A); put16(250, 0x24C); put16(110, 0x24E); put16(25, 0x250)
        return r
    }

    func testSleepSession() throws {
        let parsed = try parse(.sleepSession, sessionRecord(stages: [(1380, 1400, 0x07), (1400, 1500, 0x04),
                                                                     (1510, 1600, 0x05), (1600, 1700, 0x08),
                                                                     (1700, 1860, 0x02)]))
        guard case .sleepSession(let sessions) = parsed.records, let s = sessions.first else { return XCTFail() }
        let base = 1_790_632_800.0 - 86_400
        XCTAssertEqual(s.time, date(1_790_650_000))
        XCTAssertEqual(s.midnightReference, date(1_790_632_800))
        XCTAssertEqual(s.sleepStart, date(base + 1380 * 60))       // 23:00 local on the 28th
        XCTAssertEqual(s.sleepEnd, date(base + 1860 * 60))         // 07:00 local on the 29th
        XCTAssertEqual(s.averageHeartRate, 54)
        XCTAssertEqual(s.score, 81)
        XCTAssertEqual(s.stages.map(\.kind), [.awake, .light, .deep, .rem, .other(0x02)])
        XCTAssertEqual(s.stages[1].start, date(base + 1400 * 60))
        XCTAssertEqual(s.stages[1].end, date(base + 1500 * 60))
        XCTAssertEqual(s.stageGaps, [date(base + 1500 * 60)...date(base + 1510 * 60)])
        XCTAssertEqual([s.totalREMMinutes, s.totalLightMinutes, s.totalDeepMinutes, s.totalAwakeMinutes], [95, 250, 110, 25])
        XCTAssertEqual(parsed.lastRecordTime, date(1_790_650_000))
    }

    func testSleepSessionWithoutStagesOrWithTooManyIsSkipped() throws {
        let hundred = (0..<100).map { i in (UInt16(1380 + i), UInt16(1381 + i), UInt8(0x04)) }
        let parsed = try parse(.sleepSession, sessionRecord(stages: []) + sessionRecord(stages: [], count: 101)
                               + sessionRecord(stages: hundred))
        guard case .sleepSession(let sessions) = parsed.records else { return XCTFail() }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.stages.count, 100)
        XCTAssertEqual(parsed.skippedRecords, 2)
        XCTAssertEqual(parsed.lastRecordTime, date(1_790_650_000))
    }

    // MARK: Length rules and hostile input

    func testLengthRules() {
        let violations: [(ZeppFetchType, Int)] = [
            (.activity, 7), (.activity, 9), (.temperature, 12), (.sleepRespiratoryRate, 4),
            (.manualHeartRate, 5), (.restingHeartRate, 7), (.maxHeartRate, 13), (.hrv, 11),
            (.spo2, 0), (.spo2, 65), (.spo2, 67), (.sleepSpO2, 0), (.sleepSpO2, 30), (.sleepSpO2, 32),
            (.sleepSession, 593), (.sleepSession, 595), (.pai, 101), (.pai, 103), (.manualStress, 4), (.manualStress, 6),
        ]
        for (type, length) in violations {
            XCTAssertThrowsError(try parse(type, [UInt8](repeating: 2, count: length)), "\(type) \(length)") {
                XCTAssertEqual($0 as? ZeppRecordParser.Error, .lengthViolation(type: type, length: length))
            }
        }
        for type in ZeppFetchType.allCases where type != .spo2 && type != .sleepSpO2 {
            XCTAssertNoThrow(try parse(type, []), "\(type) empty")
        }
    }

    func testTruncationsOfValidDataNeverTrap() throws {
        var gen = TestBytes(seed: 5)
        let samples: [(ZeppFetchType, [UInt8])] = [
            (.activity, gen.bytes(80)), (.autoStress, gen.bytes(30)), (.temperature, gen.bytes(64)),
            (.hrv, gen.bytes(60)), (.restingHeartRate, gen.bytes(12)), (.manualStress, gen.bytes(25)),
            (.sleepRespiratoryRate, gen.bytes(40)), (.spo2, [0x02] + gen.bytes(130)),
            (.sleepSpO2, [0x02] + gen.bytes(60)), (.pai, paiRecord(type: 5, ts: 1) + paiRecord(type: 5, ts: 2)),
            (.sleepSession, sessionRecord(stages: [(1, 2, 4)]) + sessionRecord(stages: [(3, 4, 5)])),
        ]
        for (type, data) in samples {
            for length in 0...data.count {
                _ = try? parse(type, Array(data.prefix(length)))
            }
        }
    }

    func testRandomGarbageNeverTraps() {
        var gen = TestBytes(seed: 31337)
        for _ in 0..<400 {
            for type in ZeppFetchType.allCases {
                let length = gen.int(0...700)
                var data = gen.bytes(length)
                if gen.int(0...1) == 0 {
                    // Nudge towards a valid length so the record decoders actually run.
                    switch type {
                    case .spo2: data = [0x02] + gen.bytes(65 * gen.int(0...3))
                    case .sleepSpO2: data = [0x02] + gen.bytes(30 * gen.int(0...3))
                    case .sleepSession: data = gen.bytes(594 * gen.int(0...2))
                    case .pai: data = gen.bytes(102 * gen.int(0...3))
                    default: data = gen.bytes(40 * gen.int(0...5))
                    }
                }
                if let parsed = try? parse(type, data) {
                    XCTAssertEqual(parsed.type, type)
                }
            }
        }
    }
}
