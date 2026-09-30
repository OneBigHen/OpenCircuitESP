// Find device (§11, §13.2, §15.4) and the capability gate (§14): message parsing, the idle →
// buzzing → stopped model with its phone-side stops, one-shot emulation, the owed stop after a link
// loss, find phone, and "unknown means unsupported".

import XCTest
@testable import ZeppKit

final class ControlCapabilityTests: XCTestCase {

    func testSupportNeedsTheStrapAuthAndAListedEndpoint() {
        let full = ControlsFixtures.strapCapabilities()
        for control in [ZeppControl.findDevice, .buzz, .findPhone, .alarms, .hapticAlerts] {
            XCTAssertEqual(full.support(control), .supported, "\(control)")
        }
        // Listed or not, patterns are never exposed in v1.
        XCTAssertEqual(full.support(.vibrationPatterns), .unsupported(.notInV1))

        let bare = ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices)
        XCTAssertEqual(bare.support(.findDevice), .unsupported(.endpointNotListed(0x001A)))
        XCTAssertEqual(bare.support(.buzz), .unsupported(.endpointNotListed(0x001A)))
        XCTAssertEqual(bare.support(.alarms), .unsupported(.endpointNotListed(0x000F)))
        XCTAssertEqual(bare.support(.hapticAlerts), .unsupported(.endpointNotListed(0x000A)))

        for control in ZeppControl.allCases {
            XCTAssertEqual(ControlsFixtures.strapCapabilities(model: .helioRing).support(control), .unsupported(.notHelioStrap))
            XCTAssertEqual(ControlsFixtures.strapCapabilities(model: nil).support(control), .unsupported(.notHelioStrap))
            XCTAssertEqual(ControlsFixtures.strapCapabilities(authenticated: false).support(control), .unsupported(.notAuthenticated))
            XCTAssertEqual(ZeppControlCapabilities(model: .helioStrap, isAuthenticated: true, services: nil).support(control),
                           .unsupported(.noServicesList))
            XCTAssertFalse(ZeppControlCapabilities.disconnected.isSupported(control))
        }
        XCTAssertThrowsError(try bare.require(.findDevice)) {
            XCTAssertEqual($0 as? ZeppControlError, .unsupported(.findDevice, .endpointNotListed(0x001A)))
        }
        XCTAssertNoThrow(try full.require(.alarms))
    }

    func testHapticAlertsNeedEveryPieceOfEvidence() {
        let reply = ZeppConfig.parseReadReply(hex("04 01 08 03 01 02 02 10 00 02 00 64 14 0b 01"))
        let caps = ZeppConfigCapabilities.parse(hex("02 03 01 08"))
        let full = ZeppHapticAlertSettings(capabilities: ControlsFixtures.strapCapabilities(), configCapabilities: caps, healthReply: reply)
        XCTAssertEqual(full.settings.map(\.alert), [.highHeartRate, .relaxReminder])    // only what was reported

        func settings(_ configCapabilities: ZeppConfigCapabilities?, _ reply: ZeppConfigReadReply?,
                      capabilities: ZeppControlCapabilities = ControlsFixtures.strapCapabilities()) -> [ZeppHapticAlert] {
            ZeppHapticAlertSettings(capabilities: capabilities, configCapabilities: configCapabilities, healthReply: reply)
                .settings.map(\.alert)
        }
        XCTAssertEqual(settings(caps, reply, capabilities: ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices)), [])
        XCTAssertEqual(settings(nil, reply), [])                                                          // no caps reply
        XCTAssertEqual(settings(ZeppConfigCapabilities.parse(hex("02 04 01 08")), reply), [])              // service v4
        XCTAssertEqual(settings(ZeppConfigCapabilities.parse(hex("02 03 01 03")), reply), [])              // HEALTH not listed
        XCTAssertEqual(settings(caps, nil), [])
        XCTAssertEqual(settings(caps, ZeppConfig.parseReadReply(hex("04 01 08 04 01 01 02 10 00 02 00 64"))), [])   // HEALTH v4
        XCTAssertEqual(settings(caps, ZeppConfig.parseReadReply(hex("04 01 08 03 00 01 02 10 00"))), [])            // no constraints
        XCTAssertEqual(settings(caps, ZeppConfig.parseReadReply(hex("04 01 03 02 01 01 12 10 00 02 00 01"))), [])   // another group
        XCTAssertEqual(settings(caps, ZeppConfig.parseReadReply(hex("04 01 08 03 01 01 02 0b 01"))), [])            // wrong type
        XCTAssertEqual(settings(caps, ZeppConfig.parseReadReply(hex("04 01 08 03 01 01 02 10 00 00"))), [])         // no allowed values
        XCTAssertEqual(settings(caps, ZeppConfig.parseReadReply(hex("04 01 08 03 01 02 14 0b 01 14 0b 00"))), [])   // twice
        XCTAssertThrowsError(try ZeppHapticAlertSettings(capabilities: .disconnected, configCapabilities: caps, healthReply: reply)
            .writeRequest(.highHeartRate, value: .byte(100))) {
            XCTAssertEqual($0 as? ZeppHapticAlertSettings.Error, .unsupported(.highHeartRate))
        }
    }

    func testConfigCapabilitiesAndConstraintParsing() {
        XCTAssertEqual(ZeppConfigCapabilities.request, [0x01])
        XCTAssertEqual(ZeppConfigCapabilities.parse(hex("02 03 03 08 03 0a")), ZeppConfigCapabilities(serviceVersion: 3, groups: [8, 3, 10]))
        XCTAssertNil(ZeppConfigCapabilities.parse(hex("02 03 03 08")))                   // truncated
        XCTAssertNil(ZeppConfigCapabilities.parse(hex("04 03 00")))
        XCTAssertNil(ZeppConfigCapabilities.parse([]))
        XCTAssertEqual(ZeppConfig.readRequest(group: 0x03, arguments: [0x09, 0x12], includeConstraints: true), hex("03 01 03 02 09 12"))
        XCTAssertEqual(ZeppConfig.readRequest(group: 0x08, arguments: [0x13], includeConstraints: false),
                       ZeppConfig.readRequest(group: 0x08, arguments: [0x13]))
        XCTAssertNil(ZeppConfig.writeRequest(group: 0x08, groupVersion: 3, entries: []))
        XCTAssertNil(ZeppConfig.writeRequest(group: 0x08, groupVersion: 3, entries: [(0x42, .hourMinute(hour: 1, minute: 2))]))

        var payload = hex("04 01 08 03 01 06")
        payload += hex("01 10 05 02 05 0a")
        payload += hex("02 11 02 aa bb 01 cc")
        payload += hex("03 01 f6 ff 00 00 10 00")
        payload += hex("04 02 02 01 00 02 00 00 05 00 00 10 00")
        payload += hex("05 03 78 56 34 12 00 00 00 00 ff 00 00 00")
        payload += hex("06 21 61 00 04 02 61 00 62 00")
        let reply = ZeppConfig.parseReadReply(payload)
        XCTAssertEqual(reply?.isPartial, false)
        XCTAssertEqual(reply?.entries.map(\.constraint), [
            .allowedValues([5, 10]), .allowedValues([0xcc]), .shortRange(min: 0, max: 16),
            .shortList(minCount: 0, maxCount: 5, min: 0, max: 16), .intRange(min: 0, max: 255),
            .stringChoices(maxLength: 4, choices: ["a", "b"]),
        ])
        // Truncating anywhere never traps and never yields more entries than the full reply.
        for length in 0..<payload.count {
            if let partial = ZeppConfig.parseReadReply(Array(payload.prefix(length))) {
                XCTAssertLessThanOrEqual(partial.entries.count, 6)
            }
        }
    }
}

final class FindDeviceTests: XCTestCase {

    private let t0 = date(1_790_764_496)
    private func find(_ payload: [UInt8]) -> ZeppControlMessage {
        ZeppControlMessage(endpoint: ZeppEndpoint.findDevice, payload: payload)
    }

    /// A machine on a supporting connection with the capabilities reply for `version` (nil: none).
    private func connectedMachine(version: UInt8?, configuration: ZeppFindDevice.Configuration = .init()) -> ZeppFindDevice {
        var machine = ZeppFindDevice(configuration: configuration)
        XCTAssertEqual(machine.connected(ControlsFixtures.strapCapabilities()).messages, [find([0x01])])
        if let version { _ = machine.receive([0x02, 0x01, version], now: t0) }
        return machine
    }

    func testMessageParsing() {
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("02 01 02")), .capabilities(version: 2))
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("02 01 01")), .capabilities(version: 1))
        for malformed in ["02", "02 01", "02 01 02 00", "02 00 02", "02 02 02"] {
            XCTAssertEqual(ZeppFindDeviceMessage.parse(hex(malformed)), .malformedCapabilities, malformed)
        }
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("04")), .startAcknowledged)
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("04 99 99")), .startAcknowledged)   // no further bytes read
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("07")), .stoppedByStrap)
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("11")), .findPhoneRequested)
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("13")), .findPhoneEnded)
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("15 00")), .findPhoneMode(.vibrateOnly))
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("15 01")), .findPhoneMode(.ring))
        XCTAssertEqual(ZeppFindDeviceMessage.parse(hex("15 07")), .findPhoneMode(.other(7)))
        XCTAssertNil(ZeppFindDeviceMessage.parse(hex("15")))
        XCTAssertNil(ZeppFindDeviceMessage.parse([]))
        for opcode: UInt8 in [0x00, 0x01, 0x03, 0x05, 0x06, 0x08, 0x09, 0x10, 0x12, 0x14, 0x16, 0xff] {
            XCTAssertNil(ZeppFindDeviceMessage.parse([opcode]), "opcode \(opcode)")
        }
        XCTAssertEqual(ZeppFindDeviceCommand.capabilitiesRequest, [0x01])
        XCTAssertEqual(ZeppFindDeviceCommand.start, [0x03])
        XCTAssertEqual(ZeppFindDeviceCommand.stop, [0x06])
        XCTAssertEqual(ZeppFindDeviceCommand.findPhoneAck, [0x12, 0x01])
        XCTAssertEqual(ZeppFindDeviceCommand.endFindPhone, [0x14])
        var gen = TestBytes(seed: 0x1a)
        for _ in 0..<3000 { _ = ZeppFindDeviceMessage.parse(gen.bytes(gen.int(0...6))) }
    }

    func testUnsupportedConnectionSendsNothing() {
        for capabilities in [ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices),
                             ControlsFixtures.strapCapabilities(model: .helioRing),
                             ControlsFixtures.strapCapabilities(authenticated: false)] {
            var machine = ZeppFindDevice()
            XCTAssertEqual(machine.connected(capabilities), .init())
            XCTAssertThrowsError(try machine.start(now: t0)) {
                guard case ZeppControlError.unsupported(.findDevice, _)? = $0 as? ZeppControlError else { return XCTFail("\($0)") }
            }
            XCTAssertThrowsError(try machine.buzz(now: t0))
            XCTAssertEqual(machine.receive([0x11], now: t0), .init())         // no 12 01 either
            XCTAssertEqual(machine.stop(), .init())
            XCTAssertEqual(machine.state, .idle)
        }
        var fresh = ZeppFindDevice()                                           // never connected
        XCTAssertThrowsError(try fresh.start(now: t0))
    }

    func testContinuousFindStopsByUserOrAt60Seconds() throws {
        var machine = connectedMachine(version: 2)
        XCTAssertEqual(machine.version, 2)
        XCTAssertEqual(machine.mode, .continuous)
        XCTAssertEqual(try machine.start(now: t0).messages, [find([0x03])])
        XCTAssertEqual(machine.state, .buzzing(.find, mode: .continuous, since: t0))
        XCTAssertThrowsError(try machine.start(now: t0)) { XCTAssertEqual($0 as? ZeppFindDevice.Error, .alreadyActive) }
        XCTAssertThrowsError(try machine.buzz(now: t0)) { XCTAssertEqual($0 as? ZeppFindDevice.Error, .alreadyActive) }
        XCTAssertEqual(machine.receive([0x04], now: t0 + 0.2).events, [.startAcknowledged])
        XCTAssertEqual(machine.nextDeadline, t0 + 60)                         // no re-send in continuous mode
        XCTAssertEqual(machine.tick(now: t0 + 59.9), .init())
        let timeout = machine.tick(now: t0 + 60)
        XCTAssertEqual(timeout.messages, [find([0x06])])
        XCTAssertEqual(timeout.events, [.stopped(.phoneTimeout)])
        XCTAssertEqual(machine.state, .stopped(.phoneTimeout))
        XCTAssertNil(machine.nextDeadline)
        XCTAssertEqual(machine.tick(now: t0 + 61), .init())

        _ = try machine.start(now: t0 + 100)                                  // a new find after a stop
        XCTAssertEqual(machine.stop(), .init(messages: [find([0x06])], events: [.stopped(.user)]))
        XCTAssertEqual(machine.stop(), .init())                               // nothing left to stop
    }

    func testOneShotEmulationResendsAfterEachAckUntilTheCap() throws {
        for version: UInt8? in [1, nil] {                                     // version < 2, or no reply
            var machine = connectedMachine(version: version)
            XCTAssertEqual(machine.mode, .oneShotEmulation)
            var starts = try machine.start(now: t0).messages.filter { $0.payload == [0x03] }.count
            var stops = 0
            var t = t0
            while machine.isBuzzing {
                t += 1
                _ = machine.receive([0x04], now: t)                           // the strap acks each start 1 s later
                guard let deadline = machine.nextDeadline else { return XCTFail("nothing scheduled") }
                t = deadline
                let out = machine.tick(now: t)
                starts += out.messages.filter { $0.payload == [0x03] }.count
                stops += out.messages.filter { $0.payload == [0x06] }.count
            }
            // 03 at 0, 11, 22, 33, 44, 55 (each 10 s after the ack at +1), then 06 at 60.
            XCTAssertEqual(starts, 6, "version \(String(describing: version))")
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(t, t0 + 60)
            XCTAssertEqual(machine.state, .stopped(.phoneTimeout))
        }
        // Without acks there is nothing to re-send: one 03, then the 06 at 60 s.
        var quiet = connectedMachine(version: 1)
        _ = try quiet.start(now: t0)
        XCTAssertEqual(quiet.nextDeadline, t0 + 60)
    }

    func testMalformedCapabilitiesReplyMeansOneShot() {
        var machine = connectedMachine(version: nil)
        XCTAssertEqual(machine.receive(hex("02 01 03 00"), now: t0).events, [.capabilities(version: nil)])
        XCTAssertNil(machine.version)
        XCTAssertEqual(machine.mode, .oneShotEmulation)
        XCTAssertEqual(machine.receive(hex("02 01 03"), now: t0).events, [.capabilities(version: 3)])
        XCTAssertEqual(machine.mode, .continuous)
        // §11.2: a malformed reply is ignored; it does not undo a well-formed one.
        XCTAssertEqual(machine.receive(hex("02 01"), now: t0).events, [.capabilities(version: nil)])
        XCTAssertEqual(machine.version, 3)
    }

    func testBuzzIsStartThenStopAfter500ms() throws {
        var machine = connectedMachine(version: 1)
        XCTAssertEqual(try machine.buzz(now: t0).messages, [find([0x03])])
        XCTAssertEqual(machine.nextDeadline, t0 + 0.5)
        _ = machine.receive([0x04], now: t0 + 0.1)                           // no re-send for a buzz
        XCTAssertEqual(machine.nextDeadline, t0 + 0.5)
        XCTAssertEqual(machine.tick(now: t0 + 0.49), .init())
        XCTAssertEqual(machine.tick(now: t0 + 0.5), .init(messages: [find([0x06])], events: [.stopped(.buzzEnded)]))
    }

    func testStrapStopIsPairedWithAStop() throws {
        var machine = connectedMachine(version: 2)
        XCTAssertEqual(machine.receive([0x07], now: t0), .init())            // not buzzing: ignored
        _ = try machine.start(now: t0)
        XCTAssertEqual(machine.receive([0x07], now: t0 + 30), .init(messages: [find([0x06])], events: [.stopped(.strapStopped)]))
        XCTAssertEqual(machine.state, .stopped(.strapStopped))
        XCTAssertEqual(machine.tick(now: t0 + 60), .init())                  // no second stop
    }

    func testLinkLossOwesAStopToTheNextSupportingConnection() throws {
        var machine = connectedMachine(version: 2)
        _ = try machine.start(now: t0)
        machine.connectionLost()
        XCTAssertEqual(machine.state, .stopped(.linkLost))
        XCTAssertTrue(machine.isStopOwed)
        XCTAssertNil(machine.nextDeadline)
        XCTAssertNil(machine.version)
        XCTAssertThrowsError(try machine.start(now: t0))                      // disconnected

        // A connection without find device can't carry it: still owed, nothing sent.
        XCTAssertEqual(machine.connected(ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices)), .init())
        XCTAssertTrue(machine.isStopOwed)
        // The next one that can sends it once, before anything else.
        XCTAssertEqual(machine.connected(ControlsFixtures.strapCapabilities()),
                       .init(messages: [find([0x06]), find([0x01])], events: [.owedStopSent]))
        XCTAssertFalse(machine.isStopOwed)
        XCTAssertEqual(machine.connected(ControlsFixtures.strapCapabilities()).messages, [find([0x01])])

        // Reconnecting without reporting the loss counts as a loss too.
        _ = try machine.start(now: t0)
        XCTAssertEqual(machine.connected(ControlsFixtures.strapCapabilities()).messages, [find([0x06]), find([0x01])])
        XCTAssertEqual(machine.state, .stopped(.linkLost))
    }

    func testAStopOwedFromAnEarlierProcessGoesOutOnTheFirstSupportingConnection() {
        // #215 phase 4: the app persists "a find may be running" and seeds a new machine with it, so a
        // process the system ended mid-find still stops the strap.
        var machine = ZeppFindDevice(stopOwed: true)
        XCTAssertTrue(machine.isStopOwed)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.connected(ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices)), .init())
        XCTAssertTrue(machine.isStopOwed, "a connection without find device can't carry it")
        XCTAssertEqual(machine.connected(ControlsFixtures.strapCapabilities()),
                       .init(messages: [find([0x06]), find([0x01])], events: [.owedStopSent]))
        XCTAssertFalse(machine.isStopOwed)
        XCTAssertFalse(ZeppFindDevice().isStopOwed, "nothing is owed by default")
    }

    func testFindPhoneIsAnsweredAndEnded() {
        var machine = connectedMachine(version: 2)
        XCTAssertEqual(machine.receive([0x15, 0x01], now: t0), .init())      // no request yet
        XCTAssertEqual(machine.receive([0x11], now: t0), .init(messages: [find([0x12, 0x01])], events: [.findPhoneRequested]))
        XCTAssertTrue(machine.isFindPhoneActive)
        XCTAssertEqual(machine.receive([0x15, 0x00], now: t0).events, [.findPhoneMode(.vibrateOnly)])
        XCTAssertEqual(machine.receive([0x13], now: t0).events, [.findPhoneEnded])
        XCTAssertFalse(machine.isFindPhoneActive)
        XCTAssertEqual(machine.endFindPhone(), .init())

        _ = machine.receive([0x11], now: t0)
        XCTAssertEqual(machine.endFindPhone(), .init(messages: [find([0x14])], events: [.findPhoneEnded]))
        _ = machine.receive([0x11], now: t0)
        machine.connectionLost()
        XCTAssertFalse(machine.isFindPhoneActive)
    }

    func testConfigurationIsCappedAt60Seconds() {
        XCTAssertEqual(ZeppFindDevice.Configuration(maxDuration: 600).maxDuration, 60)
        XCTAssertEqual(ZeppFindDevice.Configuration(maxDuration: -1).maxDuration, 0)
        XCTAssertEqual(ZeppFindDevice.Configuration(maxDuration: 10).maxDuration, 10)
        XCTAssertEqual(ZeppFindDevice.Configuration().buzzLength, 0.5)
        XCTAssertEqual(ZeppFindDevice.Configuration().oneShotResendDelay, 10)
    }
}
