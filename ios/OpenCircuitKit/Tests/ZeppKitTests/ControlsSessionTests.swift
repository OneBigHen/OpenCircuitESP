// Device controls against the simulated strap (FakeZeppDevice): auth, a services list, then find
// device, alarms and haptic alerts end to end through ZeppLink's real chunking and encryption; and a
// strap whose services list lacks the control endpoints, which must yield "unsupported" and receive
// nothing.

import XCTest
@testable import ZeppKit
import ZeppKitTesting

private struct SetupFailed: Error {
    let step: String
}

/// One authenticated connection to a `FakeZeppDevice`, routing the strap's messages to the control
/// machines and sending what they answer, the way an app's BLE layer would.
private final class ControlSession {
    var link: ZeppLink
    let device: FakeZeppDevice
    let capabilities: ZeppControlCapabilities
    var find = ZeppFindDevice()
    var editor: ZeppAlarmEditor
    var now = date(1_790_764_496)
    private(set) var findEvents: [ZeppFindDevice.Event] = []
    private(set) var alarmEvents: [ZeppAlarmEditor.Event] = []
    private(set) var otherMessages: [ZeppMessage] = []

    init(services: [(endpoint: UInt16, flag: UInt8)], model: ZeppDeviceModel = .helioStrap, writeLength: Int = 244) throws {
        let device = FakeZeppDevice(authKey: hex("00112233445566778899aabbccddeeff"), privateKey: SpecC.strapDrawnPrivate,
                                    random: SpecC.strapRandom, writeLength: writeLength)
        device.services = services
        var link = ZeppLink(authKey: SpecC.authKey, random: .system, maxWriteLength: writeLength)
        guard pump(&link, device, link.startAuthentication().writes) == [.authenticated] else {
            throw SetupFailed(step: "handshake")
        }
        var list: ZeppServicesList?
        for case .message(let m) in pump(&link, device, try link.send(endpoint: ZeppEndpoint.servicesList,
                                                                       payload: ZeppServicesList.request)) {
            list = ZeppServicesList.parse(m.payload)
        }
        guard let list else { throw SetupFailed(step: "services list") }
        link.apply(servicesList: list)
        let capabilities = ZeppControlCapabilities(model: model, isAuthenticated: link.isAuthenticated, services: list)
        self.device = device
        self.link = link
        self.capabilities = capabilities
        self.editor = ZeppAlarmEditor(capabilities: capabilities)
    }

    /// Sends the messages, then keeps routing replies and sending what the machines answer until quiet.
    func run(_ messages: [ZeppControlMessage]) throws {
        var queue = messages
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for case .message(let reply) in pump(&link, device, try link.send(endpoint: next.endpoint, payload: next.payload)) {
                queue += route(reply)
            }
        }
    }

    /// Delivers a strap-originated message and runs whatever the phone answers.
    func strapSends(endpoint: UInt16, _ payload: [UInt8]) throws {
        var answers = [ZeppControlMessage]()
        for notification in device.unsolicited(endpoint: endpoint, payload) {
            let out = link.receive(notification.bytes)
            for case .message(let m) in out.events { answers += route(m) }
            _ = pump(&link, device, out.writes)
        }
        try run(answers)
    }

    func run(_ output: ZeppFindDevice.Output) throws {
        findEvents += output.events
        try run(output.messages)
    }

    func run(_ output: ZeppAlarmEditor.Output) throws {
        alarmEvents += output.events
        try run(output.messages)
    }

    private func route(_ message: ZeppMessage) -> [ZeppControlMessage] {
        switch message.endpoint {
        case ZeppEndpoint.findDevice:
            let out = find.receive(message.payload, now: now)
            findEvents += out.events
            return out.messages
        case ZeppEndpoint.alarms:
            let out = editor.receive(message.payload, now: now)
            alarmEvents += out.events
            return out.messages
        case ZeppEndpoint.time:
            editor.noteTimeSetReply(message.payload)
            return []
        default:
            otherMessages.append(message)
            return []
        }
    }
}

final class ControlsSessionTests: XCTestCase {

    private let slot3Record = hex("01 03 09 0f 60 00 00 00 01 00")

    func testFindDeviceAndAlarmsWithAStrapThatAdvertisesThem() throws {
        for writeLength in [20, 244] {
            let session = try ControlSession(services: ControlsFixtures.controlServices, writeLength: writeLength)
            let device = session.device
            XCTAssertEqual(session.capabilities.support(.findDevice), .supported)
            XCTAssertEqual(session.capabilities.support(.alarms), .supported)
            XCTAssertEqual(session.capabilities.support(.vibrationPatterns), .unsupported(.notInV1))

            // Find device: capabilities (read-only) at connect, then start and stop, all encrypted.
            try session.run(session.find.connected(session.capabilities))
            XCTAssertEqual(session.find.version, 2)
            XCTAssertEqual(session.find.mode, .continuous)
            try session.run(try session.find.start(now: session.now))
            XCTAssertTrue(device.isBuzzing)
            XCTAssertEqual(session.find.state, .buzzing(.find, mode: .continuous, since: session.now))
            session.now += 5
            try session.run(session.find.stop())
            XCTAssertFalse(device.isBuzzing)
            XCTAssertEqual(session.find.state, .stopped(.user))
            XCTAssertEqual(device.findOpcodes, [0x01, 0x03, 0x06])
            XCTAssertEqual(session.findEvents, [.capabilities(version: 2), .startAcknowledged, .stopped(.user)])

            // Alarms: list (Zepp's alarm in slot 3), time set, add one, read it back.
            device.alarmRecords = [3: slot3Record]
            try session.run(try session.editor.read(now: session.now))
            XCTAssertEqual(session.editor.alarms?.map(\.slot), [3])
            XCTAssertTrue(session.editor.canView)
            XCTAssertFalse(session.editor.canEdit)                            // clock not set yet
            try session.run([ZeppControlMessage(endpoint: ZeppEndpoint.time,
                                                payload: ZeppTimeCommand.setTime(session.now, timeZone: utc))])
            XCTAssertTrue(session.editor.isTimeSet)
            XCTAssertTrue(session.editor.canEdit)
            try session.run(try session.editor.add(hour: 6, minute: 30, days: .weekdays, now: session.now))

            // Exactly example F's payload, one write, and the re-read.
            XCTAssertEqual(device.alarmCommands, [[0x09], hex("03 01 04 00 06 1e 1f 00 00 00 00 00"), [0x09]])
            XCTAssertEqual(device.alarmRecords[3], slot3Record)              // Zepp's alarm untouched
            XCTAssertEqual(device.alarmRecords.keys.sorted(), [0, 3])
            guard case .writeChecked(let check)? = session.alarmEvents.last else { return XCTFail("\(session.alarmEvents)") }
            XCTAssertTrue(check.slotMatches)
            XCTAssertTrue(check.otherSlotsUnchanged)
            XCTAssertEqual(check.list.map(\.summary), ["slot 0  06:30  weekdays  on", "slot 3  09:15  weekend  off  smart wake"])
            XCTAssertEqual(session.editor.freeSlots, [1, 2, 4, 5, 6, 7, 8, 9])

            XCTAssertEqual(device.failures, [], "MTU \(writeLength)")
            XCTAssertEqual(device.receivedEndpoints,
                           [0x0082, 0x0082, 0x0000, 0x001A, 0x001A, 0x001A, 0x000F, 0x0047, 0x000F, 0x000F])
            XCTAssertEqual(session.otherMessages.map(\.endpoint), [])
        }
    }

    func testAStrapWithoutTheControlEndpointsGetsNothing() throws {
        let session = try ControlSession(services: ControlsFixtures.bareServices)
        for control in [ZeppControl.findDevice, .buzz, .findPhone, .alarms, .hapticAlerts] {
            XCTAssertEqual(session.capabilities.support(control), .unsupported(.endpointNotListed(control.endpoint)), "\(control)")
        }
        XCTAssertEqual(session.capabilities.support(.vibrationPatterns), .unsupported(.notInV1))

        try session.run(session.find.connected(session.capabilities))
        XCTAssertThrowsError(try session.find.start(now: session.now))
        XCTAssertThrowsError(try session.find.buzz(now: session.now))
        try session.run(session.find.stop())
        XCTAssertThrowsError(try session.editor.read(now: session.now))
        XCTAssertThrowsError(try session.editor.add(hour: 6, minute: 30, now: session.now))
        XCTAssertThrowsError(try session.editor.delete(slot: 0, now: session.now))
        XCTAssertFalse(session.editor.canView)
        let alerts = ZeppHapticAlertSettings(capabilities: session.capabilities,
                                             configCapabilities: ZeppConfigCapabilities.parse(hex("02 03 01 08")),
                                             healthReply: ZeppConfig.parseReadReply(hex("04 01 08 03 01 01 14 0b 01")))
        XCTAssertEqual(alerts.settings, [])

        // Nothing reached the strap after the services list.
        XCTAssertEqual(session.device.receivedEndpoints, [0x0082, 0x0082, 0x0000])
        XCTAssertEqual(session.device.findOpcodes, [])
        XCTAssertEqual(session.device.alarmCommands, [])
        XCTAssertEqual(session.device.failures, [])
    }

    func testTheHelioRingIsOutOfScope() throws {
        let session = try ControlSession(services: ControlsFixtures.controlServices, model: .helioRing)
        try session.run(session.find.connected(session.capabilities))
        XCTAssertThrowsError(try session.find.start(now: session.now))
        XCTAssertThrowsError(try session.editor.read(now: session.now))
        try session.strapSends(endpoint: ZeppEndpoint.findDevice, [0x11])    // not even a 12 01
        XCTAssertEqual(session.device.receivedEndpoints, [0x0082, 0x0082, 0x0000])
    }

    func testStrapInitiatedMessagesOverTheLink() throws {
        let session = try ControlSession(services: ControlsFixtures.controlServices, writeLength: 20)
        try session.run(session.find.connected(session.capabilities))
        try session.run(try session.find.start(now: session.now))
        // The strap stops on its own: the phone still pairs the start with a 06.
        try session.strapSends(endpoint: ZeppEndpoint.findDevice, [0x07])
        XCTAssertEqual(session.find.state, .stopped(.strapStopped))
        XCTAssertFalse(session.device.isBuzzing)
        // Find phone: answered with 12 01.
        try session.strapSends(endpoint: ZeppEndpoint.findDevice, [0x11])
        try session.strapSends(endpoint: ZeppEndpoint.findDevice, [0x15, 0x01])
        XCTAssertEqual(session.device.findOpcodes, [0x01, 0x03, 0x06, 0x12])
        XCTAssertEqual(Array(session.findEvents.suffix(2)), [.findPhoneRequested, .findPhoneMode(.ring)])
        try session.run(session.find.endFindPhone())
        XCTAssertEqual(session.device.findOpcodes.last, 0x14)
        XCTAssertEqual(session.device.failures, [])
    }

    func testBuzzOverTheLink() throws {
        let session = try ControlSession(services: ControlsFixtures.controlServices)
        try session.run(session.find.connected(session.capabilities))
        try session.run(try session.find.buzz(now: session.now))
        XCTAssertTrue(session.device.isBuzzing)
        XCTAssertEqual(session.find.nextDeadline, session.now + 0.5)
        try session.run(session.find.tick(now: session.now + 0.5))
        XCTAssertFalse(session.device.isBuzzing)
        XCTAssertEqual(session.device.findOpcodes, [0x01, 0x03, 0x06])
    }

    func testAlarmChangeAnnouncedByTheStrapForcesAReRead() throws {
        let session = try ControlSession(services: ControlsFixtures.controlServices)
        session.device.announcesAlarmChanges = true
        session.device.alarmRecords = [3: slot3Record]
        try session.run(try session.editor.read(now: session.now))
        try session.run([ZeppControlMessage(endpoint: ZeppEndpoint.time, payload: ZeppTimeCommand.setTime(session.now, timeZone: utc))])
        try session.run(try session.editor.add(hour: 7, minute: 0, now: session.now))
        XCTAssertTrue(session.alarmEvents.contains(.changedOnStrap))
        XCTAssertTrue(session.editor.isListStale)
        XCTAssertThrowsError(try session.editor.add(hour: 8, minute: 0, now: session.now)) {
            XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .listChangedOnStrap)
        }
        try session.run(try session.editor.read(now: session.now))
        XCTAssertTrue(session.editor.canEdit)
        XCTAssertEqual(session.editor.alarms?.map(\.slot), [0, 3])
    }

    func testRefusedAlarmWriteIsReportedAndNotRetried() throws {
        let session = try ControlSession(services: ControlsFixtures.controlServices)
        session.device.alarmAckStatus = 0x02
        session.device.alarmRecords = [3: slot3Record]
        try session.run(try session.editor.read(now: session.now))
        try session.run([ZeppControlMessage(endpoint: ZeppEndpoint.time, payload: ZeppTimeCommand.setTime(session.now, timeZone: utc))])
        try session.run(try session.editor.add(hour: 7, minute: 0, now: session.now))
        XCTAssertEqual(session.alarmEvents.last, .writeFailed(.set(ZeppAlarm(slot: 0, hour: 7, minute: 0)), .status(0x02)))
        XCTAssertEqual(session.device.alarmCommands, [[0x09], hex("03 01 04 00 07 00 00 00 00 00 00 00")])
        XCTAssertEqual(session.device.alarmRecords.keys.sorted(), [3])
    }

    func testHapticAlertsReadAndWriteOverTheLink() throws {
        let session = try ControlSession(services: ControlsFixtures.controlServices, writeLength: 20)
        session.device.configReplies[ZeppHapticAlertSettings.readRequest] =
            hex("04 01 08 03 01 04 02 10 00 07 00 64 6e 78 82 8c 96 03 10 00 04 00 28 2d 32 14 0b 00 32 10 5a 04 50 55 5a 00")
        try session.run([ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: ZeppConfigCapabilities.request),
                         ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: ZeppHapticAlertSettings.readRequest)])
        let replies = session.otherMessages.filter { $0.endpoint == ZeppEndpoint.config }
        XCTAssertEqual(replies.count, 2)
        XCTAssertTrue(replies.allSatisfy(\.wasEncrypted))
        let alerts = ZeppHapticAlertSettings(capabilities: session.capabilities,
                                             configCapabilities: ZeppConfigCapabilities.parse(replies[0].payload),
                                             healthReply: ZeppConfig.parseReadReply(replies[1].payload))
        XCTAssertEqual(alerts.settings.count, 4)
        try session.run([ZeppControlMessage(endpoint: ZeppEndpoint.config,
                                            payload: try alerts.writeRequest(.highHeartRate, value: .byte(120)))])
        XCTAssertEqual(session.device.configWrites, [hex("05 08 03 00 01 02 10 78")])
        XCTAssertEqual(ZeppConfig.parseWriteAck(session.otherMessages.last?.payload ?? []), 0x01)
        XCTAssertEqual(session.device.failures, [])
    }
}
