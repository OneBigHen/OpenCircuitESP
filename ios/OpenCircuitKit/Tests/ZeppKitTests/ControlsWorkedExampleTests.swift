// Device controls (§11–§13): the spec's worked examples E, F, G and H byte for byte, the §13.1
// layout illustration, and the §3.5 endpoint rows the addendum added.

import XCTest
@testable import ZeppKit

final class ControlsWorkedExampleTests: XCTestCase {

    private let exampleBPayload = hex("01 01 ea 07 09 1e 0c 00 00 08")
    private let startCiphertext = hex("8f 01 cd 1e ad c4 db 8b e8 24 03 ae 5b ff 55 45")
    private let stopCiphertext = hex("75 74 e9 d5 fa 93 f4 4d a0 fb 8c 33 b2 52 53 cd")
    private let exampleFPayload = hex("03 01 04 00 06 1e 1f 00 00 00 00 00")
    private let exampleFCiphertext = hex("29 21 7f fc d3 8d a4 6a aa de c6 76 68 0b e7 b8 1e 23 15 f1 6c 90 5e e2 98 9b 17 90 c0 78 3d 6c")

    /// Handles 1–2 on the (plaintext) auth endpoint, then example C's session and example B as
    /// handle 3, so the next message is handle 4 with sequence 0x2933d232 (§11.7).
    private func transportAfterExampleB(maxWriteLength: Int) throws -> ZeppChunkedTransport {
        var transport = ZeppChunkedTransport(maxWriteLength: maxWriteLength)
        _ = try transport.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00])
        _ = try transport.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00])
        transport.install(session: try ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: SpecC.sequenceSeed))
        _ = try transport.encode(endpoint: ZeppEndpoint.activityFetch, payload: exampleBPayload)
        XCTAssertEqual(transport.session?.nextSequence, 0x2933_d232)
        return transport
    }

    // MARK: §3.5 rows added by the addendum

    func testControlEndpointsAndDefaultEncryption() {
        XCTAssertEqual(ZeppEndpoint.alarms, 0x000F)
        XCTAssertEqual(ZeppEndpoint.vibrationPatterns, 0x0018)
        XCTAssertEqual(ZeppEndpoint.findDevice, 0x001A)
        XCTAssertEqual(ZeppEndpoint.notifications, 0x001E)
        let encryption = ZeppEndpointEncryption()
        XCTAssertFalse(encryption.isEncrypted(0x000F))
        XCTAssertTrue(encryption.isEncrypted(0x0018))
        XCTAssertTrue(encryption.isEncrypted(0x001A))
        XCTAssertTrue(encryption.isEncrypted(0x001E))
        XCTAssertEqual(ZeppEndpoint.displayName(0x001A), "find device")
        XCTAssertEqual(ZeppEndpoint.displayName(0x000F), "alarms")
        XCTAssertNil(ZeppEndpoint.displayName(0x1234))
    }

    // MARK: Worked example E (§11.7)

    func testWorkedExampleECrypto() throws {
        var crypto = try ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: 0x2933_d232)
        XCTAssertEqual(crypto.messageKey(handle: 0x04), hex("88 41 6a 02 27 96 2b af 77 ca 05 a4 c9 d9 ea fb"))
        XCTAssertEqual(crypto.messageKey(handle: 0x05), hex("89 40 6b 03 26 97 2a ae 76 cb 04 a5 c8 d8 eb fa"))
        XCTAssertEqual(ZeppCRC32.checksum(hex("03 32 d2 33 29")), 0xe374_a1e5)
        XCTAssertEqual(ZeppCRC32.checksum(hex("06 33 d2 33 29")), 0x9328_49f0)
        XCTAssertEqual(try crypto.seal(ZeppFindDeviceCommand.start, handle: 0x04), startCiphertext)
        XCTAssertEqual(crypto.nextSequence, 0x2933_d233)
        XCTAssertEqual(try crypto.seal(ZeppFindDeviceCommand.stop, handle: 0x05), stopCiphertext)
        XCTAssertEqual(crypto.nextSequence, 0x2933_d234)
        // The padded plaintext the spec lists, recovered by decryption.
        let opened = try crypto.open(startCiphertext, handle: 0x04, plaintextLength: 1)
        XCTAssertEqual(opened.payload, [0x03])
        XCTAssertEqual(opened.trailerSequence, 0x2933_d232)
        XCTAssertEqual(opened.trailerCRCMatches, true)
    }

    func testWorkedExampleEOnTheWireAtMTU247() throws {
        var transport = try transportAfterExampleB(maxWriteLength: 244)
        let start = try transport.encode(endpoint: ZeppEndpoint.findDevice, payload: ZeppFindDeviceCommand.start)
        XCTAssertEqual(start, [hex("03 0f 00 04 00 01 00 00 00 1a 00") + startCiphertext])
        XCTAssertEqual(start[0].count, 27)
        let stop = try transport.encode(endpoint: ZeppEndpoint.findDevice, payload: ZeppFindDeviceCommand.stop)
        XCTAssertEqual(stop, [hex("03 0f 00 05 00 01 00 00 00 1a 00") + stopCiphertext])
        XCTAssertEqual(transport.session?.nextSequence, 0x2933_d234)
    }

    func testWorkedExampleEStartAtMTU23() throws {
        var transport = try transportAfterExampleB(maxWriteLength: 20)
        XCTAssertEqual(try transport.encode(endpoint: ZeppEndpoint.findDevice, payload: ZeppFindDeviceCommand.start), [
            hex("03 09 00 04 00 01 00 00 00 1a 00 8f 01 cd 1e ad c4 db 8b e8"),
            hex("03 0e 00 04 01 24 03 ae 5b ff 55 45"),
        ])
    }

    /// "If the services list had flagged 0x001A plaintext, the start would instead be one 12-byte
    /// chunk."
    func testWorkedExampleEPlaintextVariant() throws {
        var transport = ZeppChunkedTransport(maxWriteLength: 244)
        transport.apply(servicesList: ZeppServicesList(entries: [.init(endpoint: 0x001A, encrypted: false)]))
        for _ in 0..<3 { _ = try transport.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00]) }
        let start = try transport.encode(endpoint: ZeppEndpoint.findDevice, payload: ZeppFindDeviceCommand.start)
        XCTAssertEqual(start, [hex("03 07 00 04 00 01 00 00 00 1a 00 03")])
    }

    // MARK: Worked example F (§12.6)

    func testWorkedExampleFRecordAndPayloads() throws {
        let alarm = ZeppAlarm(slot: 0, hour: 6, minute: 30, days: .weekdays, isEnabled: true, smartWake: false)
        XCTAssertEqual(try alarm.record(), hex("04 00 06 1e 1f 00 00 00 00 00"))
        XCTAssertEqual(try ZeppAlarmCommand.createOrReplace(alarm), exampleFPayload)
        XCTAssertEqual(ZeppAlarmDays.weekdays.rawValue, 0x1f)

        var disabled = alarm
        disabled.isEnabled = false
        XCTAssertEqual(try ZeppAlarmCommand.createOrReplace(disabled), hex("03 01 00 00 06 1e 1f 00 00 00 00 00"))
        XCTAssertEqual(try ZeppAlarmCommand.delete(slot: 0), hex("05 01 00"))
        XCTAssertEqual(ZeppAlarmCommand.readAll, [0x09])
        XCTAssertEqual(ZeppAlarmReply.parse(hex("04 01")), .createAck(status: 0x01))
        XCTAssertEqual(ZeppAlarmReply.parse(hex("06 01")), .deleteAck(status: 0x01))
    }

    func testWorkedExampleFPlaintextChunks() throws {
        for (writeLength, expected) in [
            (244, [hex("03 07 00 06 00 0c 00 00 00 0f 00 03 01 04 00 06 1e 1f 00 00 00 00 00")]),
            (20, [hex("03 01 00 06 00 0c 00 00 00 0f 00 03 01 04 00 06 1e 1f 00 00"),
                  hex("03 06 00 06 01 00 00 00")]),
        ] {
            var transport = ZeppChunkedTransport(maxWriteLength: writeLength)
            for _ in 0..<5 { _ = try transport.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00]) }
            XCTAssertEqual(try transport.encode(endpoint: ZeppEndpoint.alarms, payload: exampleFPayload), expected,
                           "write length \(writeLength)")
        }
        XCTAssertEqual(hex("03 07 00 06 00 0c 00 00 00 0f 00 03 01 04 00 06 1e 1f 00 00 00 00 00").count, 23)
    }

    /// The encrypted variant continues example E's session: sequence 0x2933d234, handle 6.
    func testWorkedExampleFEncryptedVariant() throws {
        var crypto = try ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: 0x2933_d234)
        XCTAssertEqual(crypto.messageKey(handle: 0x06), hex("8a 43 68 00 25 94 29 ad 75 c8 07 a6 cb db e8 f9"))
        XCTAssertEqual(ZeppCRC32.checksum(exampleFPayload + hex("34 d2 33 29")), 0xe7a1_48e8)
        XCTAssertEqual(try crypto.seal(exampleFPayload, handle: 0x06), exampleFCiphertext)
        XCTAssertEqual(crypto.nextSequence, 0x2933_d235)

        var transport = try transportAfterExampleB(maxWriteLength: 244)
        _ = try transport.encode(endpoint: ZeppEndpoint.findDevice, payload: ZeppFindDeviceCommand.start)
        _ = try transport.encode(endpoint: ZeppEndpoint.findDevice, payload: ZeppFindDeviceCommand.stop)
        transport.apply(servicesList: ZeppServicesList(entries: [.init(endpoint: 0x000F, encrypted: true)]))
        let chunks = try transport.encode(endpoint: ZeppEndpoint.alarms, payload: exampleFPayload)
        XCTAssertEqual(chunks, [hex("03 0f 00 06 00 0c 00 00 00 0f 00") + exampleFCiphertext])
        XCTAssertEqual(chunks[0].count, 43)
        XCTAssertEqual(transport.session?.nextSequence, 0x2933_d235)
    }

    // MARK: Worked example G (§12.7)

    func testWorkedExampleGListDecodes() throws {
        let payload = hex("0a 02 04 00 06 1e 1f 00 00 00 01 00 01 03 09 0f 60 00 00 00 01 00")
        XCTAssertEqual(payload.count, 22)
        guard case .list(.success(let alarms))? = ZeppAlarmReply.parse(payload) else { return XCTFail() }
        XCTAssertEqual(alarms.count, 2)

        XCTAssertEqual(alarms[0].slot, 0)
        XCTAssertTrue(alarms[0].isEnabled)
        XCTAssertFalse(alarms[0].smartWake)
        XCTAssertEqual(alarms[0].hour, 6)
        XCTAssertEqual(alarms[0].minute, 30)
        XCTAssertEqual(alarms[0].days, .weekdays)
        XCTAssertEqual(alarms[0].rawFlags, 0x04)
        XCTAssertEqual(alarms[0].unknownTail, hex("00 00 00 01 00"))   // [8] = 01, ignored
        XCTAssertTrue(alarms[0].hasSameSetting(as: ZeppAlarm(slot: 0, hour: 6, minute: 30, days: .weekdays)))

        XCTAssertEqual(alarms[1].slot, 3)
        XCTAssertFalse(alarms[1].isEnabled)
        XCTAssertTrue(alarms[1].smartWake)
        XCTAssertEqual(alarms[1].hour, 9)
        XCTAssertEqual(alarms[1].minute, 15)
        XCTAssertEqual(alarms[1].days, [.saturday, .sunday])
        XCTAssertEqual(alarms[1].days, .weekend)

        var editor = ZeppAlarmEditor(capabilities: ControlsFixtures.strapCapabilities())
        _ = try editor.read(now: date(0))
        _ = editor.receive(payload, now: date(1))
        XCTAssertEqual(editor.freeSlots, [1, 2, 4, 5, 6, 7, 8, 9])
    }

    // MARK: Worked example H (§13.4)

    private let exampleHReply = hex("04 01 08 03 01 04"
                                    + " 02 10 00 07 00 64 6e 78 82 8c 96"
                                    + " 03 10 00 04 00 28 2d 32"
                                    + " 14 0b 00"
                                    + " 32 10 5a 04 50 55 5a 00")

    func testWorkedExampleHReadRequestAndReply() throws {
        XCTAssertEqual(ZeppHapticAlertSettings.readRequest, hex("03 01 08 04 02 03 14 32"))
        let reply = try XCTUnwrap(ZeppConfig.parseReadReply(exampleHReply))
        XCTAssertEqual(reply.group, 0x08)
        XCTAssertEqual(reply.groupVersion, 3)
        XCTAssertTrue(reply.includesConstraints)
        XCTAssertFalse(reply.isPartial)
        XCTAssertEqual(reply.entries, [
            ZeppConfigEntry(argument: 0x02, value: .byte(0), constraint: .allowedValues(hex("00 64 6e 78 82 8c 96"))),
            ZeppConfigEntry(argument: 0x03, value: .byte(0), constraint: .allowedValues(hex("00 28 2d 32"))),
            ZeppConfigEntry(argument: 0x14, value: .bool(false)),
            ZeppConfigEntry(argument: 0x32, value: .byte(0x5a), constraint: .allowedValues(hex("50 55 5a 00"))),
        ])
    }

    func testWorkedExampleHWriteHighHeartRate120() throws {
        let settings = ZeppHapticAlertSettings(capabilities: ControlsFixtures.strapCapabilities(),
                                               configCapabilities: ZeppConfigCapabilities.parse(hex("02 03 01 08")),
                                               healthReply: ZeppConfig.parseReadReply(exampleHReply))
        XCTAssertEqual(settings.groupVersion, 3)
        XCTAssertEqual(settings.settings.map(\.alert), [.highHeartRate, .lowHeartRate, .relaxReminder, .lowSpO2])
        XCTAssertEqual(settings.setting(.lowSpO2)?.value, .byte(90))
        XCTAssertEqual(settings.setting(.lowSpO2)?.allowedValues, [80, 85, 90, 0])
        XCTAssertNil(settings.setting(.relaxReminder)?.allowedValues)

        XCTAssertEqual(try settings.writeRequest(.highHeartRate, value: .byte(120)), hex("05 08 03 00 01 02 10 78"))
        XCTAssertEqual(ZeppConfig.parseWriteAck(hex("06 01")), 0x01)
        XCTAssertNil(ZeppConfig.parseWriteAck(hex("04 01")))
        XCTAssertNil(ZeppConfig.parseWriteAck(hex("06")))

        // "A value outside the list must be refused on the phone and never sent."
        XCTAssertThrowsError(try settings.writeRequest(.highHeartRate, value: .byte(125))) {
            XCTAssertEqual($0 as? ZeppHapticAlertSettings.Error, .valueNotAllowed(.highHeartRate, .byte(125)))
        }
        XCTAssertThrowsError(try settings.writeRequest(.highHeartRate, value: .bool(true)))
        XCTAssertThrowsError(try settings.writeRequest(.relaxReminder, value: .byte(1)))
        XCTAssertEqual(try settings.writeRequest(.relaxReminder, value: .bool(true)), hex("05 08 03 00 01 14 0b 01"))
        XCTAssertEqual(try settings.writeRequest(.lowHeartRate, value: .byte(0)), hex("05 08 03 00 01 03 10 00"))
    }

    // MARK: §13.1 layout illustration (never sent in v1)

    func testVibrationPatternLayoutIllustration() {
        let pair = ZeppVibrationPatternCommand.Pair(onMilliseconds: 400, offMilliseconds: 200)
        XCTAssertEqual(ZeppVibrationPatternCommand.set(type: 0x05, pattern: [pair, pair], playNow: true),
                       hex("03 05 01 01 02 90 01 c8 00 90 01 c8 00"))
        XCTAssertEqual(ZeppVibrationPatternCommand.set(type: 0x05, pattern: nil, playNow: false), hex("03 05 00 00 00"))
        XCTAssertNil(ZeppVibrationPatternCommand.set(type: 0x05, pattern: [], playNow: false))
        let long = ZeppVibrationPatternCommand.Pair(onMilliseconds: 6000, offMilliseconds: 4001)
        XCTAssertNil(ZeppVibrationPatternCommand.set(type: 0x05, pattern: [long], playNow: false))   // > 10 s
        let edge = ZeppVibrationPatternCommand.Pair(onMilliseconds: 6000, offMilliseconds: 4000)
        XCTAssertNotNil(ZeppVibrationPatternCommand.set(type: 0x05, pattern: [edge], playNow: false))
        XCTAssertEqual(ZeppVibrationPatternCommand.parseReply(hex("04 01")), 0x01)
        XCTAssertNil(ZeppVibrationPatternCommand.parseReply(hex("04")))
    }
}

/// Capability snapshots shared by the controls tests.
enum ControlsFixtures {
    /// Every §3.5 endpoint a strap with all the controls would list, with its default flag.
    static let controlServices: [(endpoint: UInt16, flag: UInt8)] = [
        (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x0018, 1), (0x001A, 1), (0x0029, 1), (0x0047, 0), (0x0082, 0),
    ]
    /// A strap without any control endpoint (and without config).
    static let bareServices: [(endpoint: UInt16, flag: UInt8)] = [
        (0x0000, 0), (0x0029, 1), (0x0047, 0), (0x004B, 1), (0x0082, 0),
    ]

    static func servicesList(_ services: [(endpoint: UInt16, flag: UInt8)]) -> ZeppServicesList {
        ZeppServicesList(entries: services.map { .init(endpoint: $0.endpoint, encrypted: $0.flag == 1) })
    }

    static func strapCapabilities(_ services: [(endpoint: UInt16, flag: UInt8)] = controlServices,
                                  model: ZeppDeviceModel? = .helioStrap,
                                  authenticated: Bool = true) -> ZeppControlCapabilities {
        ZeppControlCapabilities(model: model, isAuthenticated: authenticated, services: servicesList(services))
    }
}
