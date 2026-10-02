// Session commands (§5), live-data parsers (§7), device identification (§1–§2), time encodings,
// the MetricKind mapping and the round summary.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

final class SessionCommandTests: XCTestCase {

    func testServicesList() {
        let list = ZeppServicesList.parse(hex("04 03 00 29 00 01 47 00 00 4b 00 05"))
        XCTAssertEqual(list?.entries, [.init(endpoint: 0x0029, encrypted: true),
                                       .init(endpoint: 0x0047, encrypted: false),
                                       .init(endpoint: 0x004B, encrypted: nil)])
        XCTAssertEqual(list?.contains(0x0047), true)
        XCTAssertNil(ZeppServicesList.parse(hex("04 03 00 29 00 01")))      // truncated
        XCTAssertNil(ZeppServicesList.parse(hex("05 00 00")))
        XCTAssertNil(ZeppServicesList.parse([]))
        XCTAssertEqual(ZeppServicesList.parse(hex("04 00 00"))?.entries, [])

        var encryption = ZeppEndpointEncryption()
        XCTAssertTrue(encryption.isEncrypted(0x0029))
        XCTAssertFalse(encryption.isEncrypted(0x0047))
        XCTAssertFalse(encryption.isEncrypted(0x1234))                      // SPEC-GAP default
        encryption.apply(ZeppServicesList(entries: [.init(endpoint: 0x0029, encrypted: false),
                                                    .init(endpoint: 0x0047, encrypted: true),
                                                    .init(endpoint: 0x000A, encrypted: nil)]))
        XCTAssertFalse(encryption.isEncrypted(0x0029))
        XCTAssertTrue(encryption.isEncrypted(0x0047))
        XCTAssertTrue(encryption.isEncrypted(0x000A))                       // other flag: keep default
    }

    func testBatteryReply() {
        let reply = hex("04 00 57 01 00 00 00 00 00 00 00 ea 07 09 1d 08 00 00 08 00 64")
        let status = ZeppBatteryStatus.parse(reply)
        XCTAssertEqual(status?.level, 87)
        XCTAssertEqual(status?.isCharging, true)
        XCTAssertEqual(status?.lastCharge, date(1_790_661_600))          // 2026-09-29 08:00 at +02:00
        XCTAssertEqual(status?.lastChargeLevel, 100)
        XCTAssertEqual(ZeppBatteryStatus.parse(hex("04 00 32 00"))?.isCharging, false)
        XCTAssertNil(ZeppBatteryStatus.parse(hex("04 00 32 07"))?.isCharging)
        XCTAssertNil(ZeppBatteryStatus.parse(hex("04 00 32 07"))?.lastCharge)
        XCTAssertNil(ZeppBatteryStatus.parse(hex("04 00 65 00")))          // 101 %
        XCTAssertNil(ZeppBatteryStatus.parse(hex("05 00 32 00")))
        XCTAssertNil(ZeppBatteryStatus.parse(hex("04 00 32")))
        XCTAssertEqual(ZeppBatteryStatus.request, [0x03])
    }

    func testHeartRateControl() {
        XCTAssertEqual(ZeppHeartRateControl.start, [0x04, 0x01])
        XCTAssertEqual(ZeppHeartRateControl.keepRunning, [0x04, 0x02])
        XCTAssertEqual(ZeppHeartRateControl.stop, [0x04, 0x00])
        XCTAssertEqual(ZeppHeartRateControl.parse([0x05, 0x00]), .controlReply(status: 0))
        XCTAssertEqual(ZeppHeartRateControl.parse([0x06, 0x01]), .fellAsleep)
        XCTAssertEqual(ZeppHeartRateControl.parse([0x06, 0x00]), .wokeUp)
        XCTAssertNil(ZeppHeartRateControl.parse([0x06, 0x02]))
        XCTAssertNil(ZeppHeartRateControl.parse([0x05]))
    }

    /// Bluetooth Heart Rate Service measurement encodings.
    func testHeartRateMeasurement() {
        XCTAssertEqual(ZeppHeartRateMeasurement.parse([0x00, 72])?.beatsPerMinute, 72)
        XCTAssertEqual(ZeppHeartRateMeasurement.parse([0x01, 0x2c, 0x01])?.beatsPerMinute, 300)
        let full = ZeppHeartRateMeasurement.parse([0x1E, 60, 0x10, 0x00, 0x00, 0x04, 0x00, 0x02])
        XCTAssertEqual(full?.beatsPerMinute, 60)
        XCTAssertEqual(full?.sensorContact, true)
        XCTAssertEqual(full?.energyExpendedKilojoules, 16)
        XCTAssertEqual(full?.rrIntervals, [1.0, 0.5])
        XCTAssertEqual(ZeppHeartRateMeasurement.parse([0x04, 60])?.sensorContact, false)
        XCTAssertNil(ZeppHeartRateMeasurement.parse([0x00, 60])?.sensorContact)
        XCTAssertEqual(ZeppHeartRateMeasurement.parse([0x10, 60, 0x00])?.rrIntervals, [])   // dangling byte
        XCTAssertNil(ZeppHeartRateMeasurement.parse([]))
        XCTAssertNil(ZeppHeartRateMeasurement.parse([0x01, 60]))
        XCTAssertNil(ZeppHeartRateMeasurement.parse([0x08, 60, 1]))
        XCTAssertEqual(ZeppBatteryLevelCharacteristic.parse([55]), 55)
        XCTAssertNil(ZeppBatteryLevelCharacteristic.parse([101]))
        XCTAssertNil(ZeppBatteryLevelCharacteristic.parse([]))
    }

    func testConfigRead() {
        XCTAssertEqual(ZeppConfig.readRequest(group: 0x08, arguments: [0x13, 0x31]), hex("03 00 08 02 13 31"))
        XCTAssertEqual(ZeppConfig.recordingArguments, [0x01, 0x05, 0x11, 0x12, 0x13, 0x31])
        XCTAssertEqual(ZeppConfig.informationalArguments, [0x04])
        // The read HelioVerify sends is unchanged: the recording switches plus 0x04, in this order.
        XCTAssertEqual(ZeppConfig.readRequest(group: ZeppConfig.healthGroup, arguments: ZeppConfig.healthReadArguments),
                       hex("03 00 08 07 01 04 05 11 12 13 31"))

        let reply = ZeppConfig.parseReadReply(hex("04 01 08 03 00 04 01 10 00 05 0b 01 13 0b 00 31 0b 01"))
        XCTAssertEqual(reply?.group, 0x08)
        XCTAssertEqual(reply?.groupVersion, 3)
        XCTAssertEqual(reply?.isPartial, false)
        XCTAssertEqual(reply?.entries, [.init(argument: 0x01, value: .byte(0)), .init(argument: 0x05, value: .bool(true)),
                                        .init(argument: 0x13, value: .bool(false)), .init(argument: 0x31, value: .bool(true))])
        let settings = ZeppHealthSettings(reply!)
        XCTAssertEqual(settings.heartRateMonitoring, 0)
        XCTAssertEqual(settings.stressMonitoring, false)
        XCTAssertNil(settings.highAccuracySleep)
        XCTAssertEqual(settings.warnings.count, 2)                      // HR monitoring off, stress off
        XCTAssertTrue(settings.warnings[0].contains("heart-rate monitoring is off"))
    }

    /// Arg 0x04 read off on the Helio while every minute of a 12 h activity fetch carried a heart
    /// rate (§5.5): it is the "Active HR monitoring" sampling boost, not a recording switch.
    func testActiveHRMonitoringIsInformationalNotAWarning() throws {
        // HR monitoring automatic, 0x04 off, every other switch on (made-up values).
        let off = try XCTUnwrap(ZeppConfig.parseReadReply(
            hex("04 01 08 03 00 07 01 10 ff 04 0b 00 05 0b 01 11 0b 01 12 0b 01 13 0b 01 31 0b 01")))
        XCTAssertEqual(off.isPartial, false)
        let settings = ZeppHealthSettings(off)
        XCTAssertEqual(settings.heartRateDuringActivity, false)
        XCTAssertEqual(settings.warnings, [])
        XCTAssertEqual(settings.informational, ["Active HR monitoring (sampling boost during activity): off"])

        let on = try XCTUnwrap(ZeppConfig.parseReadReply(hex("04 01 08 03 00 01 04 0b 01")))
        XCTAssertEqual(ZeppHealthSettings(on).informational, ["Active HR monitoring (sampling boost during activity): on"])
        XCTAssertEqual(ZeppHealthSettings(on).warnings, [])

        let absent = try XCTUnwrap(ZeppConfig.parseReadReply(hex("04 01 08 03 00 01 13 0b 01")))
        XCTAssertEqual(ZeppHealthSettings(absent).informational, [])
    }

    func testConfigValueTypesWithConstraintsAndUnknownTypeStops() {
        var payload = hex("04 01 08 03 01 09")
        payload += hex("01 10 05 02 05 0a")                  // byte 5, allowed {5, 10}
        payload += hex("02 11 02 aa bb 01 cc")               // byte list [aa bb], allowed {cc}
        payload += hex("03 01 f6 ff 00 00 10 00")            // short -10, min 0, max 16
        payload += hex("04 02 02 01 00 02 00 00 05 00 00 10 00")   // short list [1, 2]
        payload += hex("05 03 78 56 34 12 00 00 00 00 ff 00 00 00") // int 0x12345678
        payload += hex("06 20 61 62 00 10")                  // string "ab", max 16
        payload += hex("07 30 17 1e")                        // 23:30
        payload += hex("08 40 00 00 00 00 00 00 00 00")      // timestamp 0
        payload += hex("09 99 01")                           // unknown type: stop
        let reply = ZeppConfig.parseReadReply(payload)
        XCTAssertEqual(reply?.isPartial, true)
        XCTAssertEqual(reply?.entries.map(\.value), [.byte(5), .byteList([0xaa, 0xbb]), .short(-10), .shortList([1, 2]),
                                                     .int(0x1234_5678), .string("ab"), .hourMinute(hour: 23, minute: 30),
                                                     .timestamp(0)])
        XCTAssertNil(ZeppConfig.parseReadReply(hex("04 02 08 03 00 00")))       // status ≠ 01
        XCTAssertNil(ZeppConfig.parseReadReply(hex("04 01 08")))
        XCTAssertEqual(ZeppConfig.parseReadReply(hex("04 01 08 03 00 02 13 0b 02"))?.isPartial, true)   // bool 02
        XCTAssertEqual(ZeppConfig.parseReadReply(hex("04 01 08 03 00 01 11 0b"))?.isPartial, true)      // truncated
        var gen = TestBytes(seed: 8)
        for _ in 0..<2000 { _ = ZeppConfig.parseReadReply(hex("04 01 08 03") + gen.bytes(gen.int(0...40))) }
    }

    // MARK: Time (§5.1, §6.2)

    func testSetTimeWorkedExample() {
        // 2026-09-30 12:34:56.000 Europe/Madrid (UTC+2, DST on), a Wednesday.
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let when = date(1_790_764_496)
        XCTAssertEqual(ZeppTimeCommand.setTime(when, timeZone: madrid), hex("05 ea 07 09 1e 0c 22 38 03 00 08 08"))
        XCTAssertEqual(ZeppTimeCommand.currentTimeBytes(when.addingTimeInterval(0.5), timeZone: madrid)[8], 0x80)
        // UTC−5 without DST → offset ec, DST flag 00.
        let bogota = TimeZone(identifier: "America/Bogota")!
        let bytes = ZeppTimeCommand.setTime(when, timeZone: bogota)
        XCTAssertEqual(bytes[10], 0x00)
        XCTAssertEqual(bytes[11], 0xec)
        XCTAssertTrue(ZeppTimeCommand.isSuccessReply([0x06, 0x01]))
        XCTAssertFalse(ZeppTimeCommand.isSuccessReply([0x06, 0x02]))
    }

    func testNextDSTTransition() {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        // Next transition after 2026-09-30: 2026-10-25 01:00Z, fall back one hour.
        let bytes = ZeppTimeCommand.nextDSTTransition(after: date(1_790_764_496), timeZone: madrid)
        XCTAssertEqual(bytes, [0x07] + le32(1_792_890_000) + [0xf0, 0xf1])        // −3600 as i16 LE
        XCTAssertNil(ZeppTimeCommand.nextDSTTransition(after: date(1_790_764_496), timeZone: utc))
    }

    func testFetchTimestampRoundTrip() {
        let plusTwo = TimeZone(secondsFromGMT: 7200)!
        XCTAssertEqual(ZeppFetchTimestamp.encode(date(1_790_632_800), timeZone: plusTwo), hex("ea 07 09 1d 00 00 00 08"))
        XCTAssertEqual(ZeppFetchTimestamp.encode(date(1_790_632_845), timeZone: plusTwo), hex("ea 07 09 1d 00 00 00 08"))
        XCTAssertEqual(ZeppFetchTimestamp.encode(date(1_790_632_845), timeZone: plusTwo, includeSeconds: true),
                       hex("ea 07 09 1d 00 00 2d 08"))
        XCTAssertEqual(ZeppFetchTimestamp.decode(hex("ea 07 09 1d 00 00 00 08")[...]), date(1_790_632_800))
        XCTAssertEqual(ZeppFetchTimestamp.decode(hex("ea 07 09 1c 16 00 00 00")[...]), date(1_790_632_800))
        XCTAssertEqual(ZeppFetchTimestamp.decode(hex("ea 07 09 1c 11 00 00 ec")[...]), date(1_790_632_800))   // −05:00
        for bad in ["ea 07 00 1d 00 00 00 08", "ea 07 09 00 00 00 00 08", "ea 07 09 1f 00 00 00 08",   // Sept 31
                    "ea 07 09 1d 18 00 00 08", "ea 07 09 1d 00 3c 00 08", "ea 07 09 1d 00 00 3c 08", "ea 07 09"] {
            XCTAssertNil(ZeppFetchTimestamp.decode(hex(bad)[...]), bad)
        }
    }

    // MARK: Identification (§1–§2)

    func testDeviceNameMatching() {
        XCTAssertEqual(ZeppDeviceModel.match(advertisedName: "Amazfit Helio Strap"), .helioStrap)
        XCTAssertEqual(ZeppDeviceModel.match(advertisedName: "Amazfit Helio Strap 1A2B"), .helioStrap)
        XCTAssertEqual(ZeppDeviceModel.match(advertisedName: "Amazfit Helio Strap-1A2B"), .helioStrap)
        XCTAssertEqual(ZeppDeviceModel.match(advertisedName: "Amazfit Helio Strap - 1A2B"), .helioStrap)
        XCTAssertEqual(ZeppDeviceModel.match(advertisedName: "Amazfit Helio Ring 00Z9"), .helioRing)
        for name in ["Amazfit Helio Strap 1a2b", "Amazfit Helio Strap 1A2", "Amazfit Helio Strap 1A2B3",
                     "Amazfit Helio StrapX", "Amazfit Helio Strap1A2B", "Amazfit Balance", "Amazfit Helio",
                     "helio strap", "Zepp", ""] {
            XCTAssertNil(ZeppDeviceModel.match(advertisedName: name), name)
        }
    }

    func testCharacteristicUUIDs() {
        XCTAssertEqual(ZeppCharacteristic.chunkedWrite.uuidString, "00000016-0000-3512-2118-0009af100700")
        XCTAssertEqual(ZeppCharacteristic.chunkedRead.uuidString, "00000017-0000-3512-2118-0009af100700")
        XCTAssertEqual(ZeppCharacteristic.activityControl.uuidString, "00000004-0000-3512-2118-0009af100700")
        XCTAssertEqual(ZeppCharacteristic.activityData.uuidString, "00000005-0000-3512-2118-0009af100700")
        XCTAssertEqual(ZeppCharacteristic.heartRateMeasurement.uuidString, "2A37")
    }
}

final class MappingAndSummaryTests: XCTestCase {

    private let t0 = date(1_790_632_800)

    func testActivityMapsHeartRateAndStepsDroppingNoReadings() throws {
        let parsed = try ZeppRecordParser.parse(.activity, data: hex("01 20 0c 48 00 00 00 00") + hex("01 20 00 ff 00 00 00 00")
                                                + hex("01 20 05 00 00 00 00 00"), start: t0)
        XCTAssertEqual(ZeppMetricMapping.samples(from: parsed), [
            QuantitySample(kind: .heartRate, start: t0, value: 72),
            QuantitySample(kind: .steps, start: t0, end: t0 + 60, value: 12),
            QuantitySample(kind: .steps, start: t0 + 120, end: t0 + 180, value: 5),
        ])
    }

    func testCleanMappings() throws {
        let resting = try ZeppRecordParser.parse(.restingHeartRate, data: le32(1_790_600_000) + [8, 55] + le32(1_790_600_001) + [8, 0], start: t0)
        XCTAssertEqual(ZeppMetricMapping.samples(from: resting), [QuantitySample(kind: .restingHeartRate, start: date(1_790_600_000), value: 55)])

        let spo2 = try ZeppRecordParser.parse(.spo2, data: [0x02] + le32(1_790_600_000) + [0x80 | 97] + [UInt8](repeating: 0, count: 60), start: t0)
        XCTAssertEqual(ZeppMetricMapping.samples(from: spo2), [QuantitySample(kind: .spo2, start: date(1_790_600_000), value: 0.97)])
        XCTAssertEqual(MetricKind.spo2.unit, "fraction")

        let temp = try ZeppRecordParser.parse(.temperature, data: le16(0x7fff) + le16(3312) + le16(0x5a5a) + le16(0x5a5a)
                                              + le16(0x7fff) + le16(0x7fff) + le16(0x5a5a) + le16(0x5a5a), start: t0)
        XCTAssertEqual(ZeppMetricMapping.samples(from: temp), [QuantitySample(kind: .temperature, start: t0, value: 33.12)])

        let resp = try ZeppRecordParser.parse(.sleepRespiratoryRate, data: le32(1_790_600_000) + [8, 14, 0, 1] + le32(1_790_600_300) + [8, 0, 0, 1], start: t0)
        XCTAssertEqual(ZeppMetricMapping.samples(from: resp), [QuantitySample(kind: .respiratoryRate, start: date(1_790_600_000), value: 14)])

        let manual = try ZeppRecordParser.parse(.manualHeartRate, data: le32(1_790_600_000) + [8, 90], start: t0)
        XCTAssertEqual(ZeppMetricMapping.samples(from: manual), [QuantitySample(kind: .heartRate, start: date(1_790_600_000), value: 90)])
    }

    func testDeferredTypesProduceNoSamplesAndSayWhy() throws {
        let hrv = try ZeppRecordParser.parse(.hrv, data: hex("8c e4 ba 6a 08 2a"), start: t0)
        XCTAssertEqual(ZeppMetricMapping.samples(from: hrv), [])
        for type in ZeppFetchType.allCases {
            let mapped: Set<ZeppFetchType> = [.activity, .manualHeartRate, .restingHeartRate, .spo2, .temperature, .sleepRespiratoryRate]
            XCTAssertEqual(ZeppMetricMapping.deferredReason(for: type) == nil, mapped.contains(type), "\(type)")
        }
        XCTAssertTrue(ZeppMetricMapping.deferredReason(for: .hrv)!.contains("RMSSD"))
    }

    func testRoundSummaryHasAggregatesOnly() {
        var fetch = ZeppHistoryFetch(plan: [(.hrv, date(1_790_632_800))], now: date(1_790_633_430),
                                     configuration: .init(timeZone: TimeZone(secondsFromGMT: 7200)!))
        _ = fetch.start()
        _ = fetch.receiveControl(hex("10 01 01 0c 00 00 00 ea 07 09 1d 00 05 00 08"))
        _ = fetch.receiveData(hex("00 8c e4 ba 6a 08 2a b8 e5 ba 6a 08 39"))
        guard case .roundReady(let round)? = fetch.receiveControl(hex("10 02 01 39 62 bb d7")).first else { return XCTFail() }
        XCTAssertEqual(ZeppRoundSummary.describe(round),
                       "HRV [0x49]: 2 record(s), 12 B, CRC ok, 2026-09-28T22:05:00Z … 2026-09-28T22:10:00Z — 42–57 ms (RMSSD per Amazfit, unverified on the strap)")
    }
}
