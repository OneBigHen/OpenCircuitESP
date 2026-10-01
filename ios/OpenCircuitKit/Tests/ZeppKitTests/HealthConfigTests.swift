// ZeppHealthConfigEditor (#228, #230): the §15.3 config write sequence as a pure machine, then over
// the simulated strap's real chunking and encryption. Every value and allowed list is made up.

import XCTest
@testable import ZeppKit
import ZeppKitTesting

/// A HEALTH (`08`) read reply with constraints included, built from entries.
private func healthReply(version: UInt8 = 0x03, _ entries: [[UInt8]]) -> [UInt8] {
    [0x04, 0x01, 0x08, version, 0x01, UInt8(entries.count)] + entries.flatMap { $0 }
}

private func byteEntry(_ arg: UInt8, _ value: UInt8, allowed: [UInt8]) -> [UInt8] {
    [arg, 0x10, value, UInt8(allowed.count)] + allowed
}

private func boolEntry(_ arg: UInt8, _ on: Bool) -> [UInt8] { [arg, 0x0b, on ? 0x01 : 0x00] }

/// Made-up settings: HR smart; active HR off; sleep on; breathing off; stress on; SpO₂ off; high HR
/// off (allowed 0/100/110/120); low HR off (0/40/45/50); relax off; low SpO₂ off (0/80/85/90).
private struct Settings {
    var heartRate: UInt8 = 0xff
    var heartRateAllowed: [UInt8] = [0x00, 0xff, 0x01, 0x05, 0x0a, 0x1e]
    var activeHR = false
    var sleep = true
    var breathing = false
    var stress = true
    var spo2 = false
    var highHR: UInt8 = 0
    var highHRAllowed: [UInt8] = [0, 100, 110, 120]
    var lowHR: UInt8 = 0
    var relax = false
    var lowSpO2: UInt8 = 0
    var version: UInt8 = 0x03

    var reply: [UInt8] {
        healthReply(version: version, [
            byteEntry(0x01, heartRate, allowed: heartRateAllowed), boolEntry(0x04, activeHR), boolEntry(0x11, sleep),
            boolEntry(0x12, breathing), boolEntry(0x13, stress), boolEntry(0x31, spo2),
            byteEntry(0x02, highHR, allowed: highHRAllowed), byteEntry(0x03, lowHR, allowed: [0, 40, 45, 50]),
            boolEntry(0x14, relax), byteEntry(0x32, lowSpO2, allowed: [0, 80, 85, 90]),
        ])
    }
}

private let configCaps = ZeppConfigCapabilities(serviceVersion: 3, groups: [0x00, 0x0b, 0x08, 0x09, 0x0a])
private let t0 = date(1_790_764_496)

private func editor(_ capabilities: ZeppControlCapabilities = ControlsFixtures.strapCapabilities(),
                    configCapabilities: ZeppConfigCapabilities? = configCaps) -> ZeppHealthConfigEditor {
    ZeppHealthConfigEditor(capabilities: capabilities, configCapabilities: configCapabilities)
}

private func readEditor(_ settings: Settings = Settings()) throws -> ZeppHealthConfigEditor {
    var e = editor()
    _ = try e.read(now: t0)
    _ = e.receive(settings.reply, now: t0)
    XCTAssertNotNil(e.config)
    return e
}

private func payloads(_ out: ZeppHealthConfigEditor.Output) -> [[UInt8]] {
    out.messages.map { msg in
        XCTAssertEqual(msg.endpoint, ZeppEndpoint.config)
        return msg.payload
    }
}

final class HealthConfigTests: XCTestCase {

    func testReadRequestNamesEverySettingWithConstraints() {
        XCTAssertEqual(ZeppHealthConfigEditor.readRequest, hex("03 01 08 0a 01 04 11 12 13 31 02 03 14 32"))
        XCTAssertFalse(ZeppHealthSetting.allCases.map(\.argument).contains(0x05),
                       "heart-rate push (0x05) is unsettled in the spec, so never offered")
        XCTAssertEqual(Set(ZeppHealthSetting.measurement + ZeppHealthSetting.alerts), Set(ZeppHealthSetting.allCases))
    }

    func testParseKeepsOnlyWellTypedSettingsAndTheirAllowedValues() throws {
        let config = try XCTUnwrap(ZeppHealthConfig(try XCTUnwrap(ZeppConfig.parseReadReply(Settings().reply))))
        XCTAssertEqual(config.groupVersion, 3)
        XCTAssertEqual(config.entries.count, 10)
        XCTAssertEqual(config.options(.heartRateMonitoring), [0x00, 0xff, 0x01, 0x05, 0x0a, 0x1e].map(ZeppConfigValue.byte))
        XCTAssertEqual(config.options(.stressMonitoring), [.bool(false), .bool(true)])
        XCTAssertEqual(config.availability(.relaxReminder), .available, "stress is on")
        XCTAssertEqual(config.availability(.lowSpO2Alert), .needs(.allDaySpO2), "all-day SpO₂ is off")

        // Wrong type (stress as a byte), a byte without constraints values, a duplicate arg.
        let odd = healthReply([
            [0x13, 0x10, 0x01, 0x02, 0x00, 0x01], byteEntry(0x02, 0, allowed: []),
            boolEntry(0x11, true), boolEntry(0x11, false), boolEntry(0x14, true),
        ])
        let oddConfig = try XCTUnwrap(ZeppHealthConfig(try XCTUnwrap(ZeppConfig.parseReadReply(odd))))
        XCTAssertEqual(oddConfig.availability(.stressMonitoring), .notReported)
        XCTAssertEqual(oddConfig.availability(.highHeartRateAlert), .notReported)
        XCTAssertEqual(oddConfig.availability(.highAccuracySleep), .notReported)
        XCTAssertEqual(oddConfig.availability(.relaxReminder), .needs(.stressMonitoring),
                       "a prerequisite the strap didn't report is not 'on'")

        // A version the args aren't known at, a reply without constraints, another group.
        var v4 = Settings()
        v4.version = 4
        XCTAssertNil(ZeppHealthConfig(try XCTUnwrap(ZeppConfig.parseReadReply(v4.reply))))
        XCTAssertNil(ZeppHealthConfig(try XCTUnwrap(ZeppConfig.parseReadReply(hex("04 01 08 03 00 01 13 0b 01")))))
        XCTAssertNil(ZeppHealthConfig(try XCTUnwrap(ZeppConfig.parseReadReply(hex("04 01 09 01 01 01 13 0b 01")))))
    }

    func testAChangeReadsFirstWritesOneArgEchoingTheVersionThenReReads() throws {
        var e = try readEditor()
        let change = ZeppHealthConfigEditor.Change(setting: .allDaySpO2, from: .bool(false), to: .bool(true))
        // 1. A fresh read, never the write straight away.
        XCTAssertEqual(payloads(try e.change(change, now: t0)), [ZeppHealthConfigEditor.readRequest])
        XCTAssertEqual(e.changeInFlight, change)
        XCTAssertThrowsError(try e.read(now: t0)) { XCTAssertEqual($0 as? ZeppHealthConfigEditor.Error, .busy) }
        // 2–3. The read still holds `from`: exactly one arg, one message, version echoed.
        var out = e.receive(Settings().reply, now: t0)
        XCTAssertEqual(payloads(out), [hex("05 08 03 00 01 31 0b 01")])
        // 4. `06 01`, then 5. the re-read.
        out = e.receive([0x06, 0x01], now: t0)
        XCTAssertEqual(payloads(out), [ZeppHealthConfigEditor.readRequest])
        XCTAssertEqual(out.events, [.writeAcknowledged(change)])
        var after = Settings()
        after.spo2 = true
        out = e.receive(after.reply, now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertNil(check.failure)
        XCTAssertTrue(check.matches)
        XCTAssertTrue(check.otherSettingsUnchanged)
        XCTAssertEqual(check.readBack, .bool(true))
        XCTAssertEqual(e.config?.availability(.lowSpO2Alert), .available, "the alert's prerequisite is on now")
        XCTAssertFalse(e.isBusy)
    }

    func testTheGroupVersionIsEchoedFromTheRead() throws {
        var v2 = Settings()
        v2.version = 0x02
        var e = try readEditor(v2)
        _ = try e.change(.init(setting: .highHeartRateAlert, from: .byte(0), to: .byte(110)), now: t0)
        XCTAssertEqual(payloads(e.receive(v2.reply, now: t0)), [hex("05 08 02 00 01 02 10 6e")])
    }

    func testNothingTheUserDidNotChangeOrTheStrapDoesNotOfferIsSent() throws {
        var e = try readEditor()
        func refuses(_ change: ZeppHealthConfigEditor.Change, _ expected: ZeppHealthConfigEditor.Error,
                     line: UInt = #line) {
            XCTAssertThrowsError(try e.change(change, now: t0), line: line) {
                XCTAssertEqual($0 as? ZeppHealthConfigEditor.Error, expected, line: line)
            }
            XCTAssertFalse(e.isBusy, line: line)
        }
        refuses(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(true)), .unchanged(.stressMonitoring))
        refuses(.init(setting: .highHeartRateAlert, from: .byte(0), to: .byte(125)), .valueNotAllowed(.highHeartRateAlert, .byte(125)))
        refuses(.init(setting: .stressMonitoring, from: .bool(true), to: .byte(0)), .valueNotAllowed(.stressMonitoring, .byte(0)))
        refuses(.init(setting: .lowSpO2Alert, from: .byte(0), to: .byte(90)), .prerequisiteOff(.lowSpO2Alert, needs: .allDaySpO2))

        var fresh = editor()
        XCTAssertThrowsError(try fresh.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t0)) {
            XCTAssertEqual($0 as? ZeppHealthConfigEditor.Error, .notRead)
        }
        let partial = healthReply([boolEntry(0x13, true)])
        var few = editor()
        _ = try few.read(now: t0)
        _ = few.receive(partial, now: t0)
        XCTAssertThrowsError(try few.change(.init(setting: .allDaySpO2, from: .bool(false), to: .bool(true)), now: t0)) {
            XCTAssertEqual($0 as? ZeppHealthConfigEditor.Error, .notReported(.allDaySpO2))
        }
    }

    func testAValueChangedOnTheStrapSinceTheUserSawItIsNotOverwritten() throws {
        var e = try readEditor()
        let change = ZeppHealthConfigEditor.Change(setting: .stressMonitoring, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t0)
        var meanwhile = Settings()
        meanwhile.stress = false   // changed in Zepp, say
        let out = e.receive(meanwhile.reply, now: t0)
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events.last, .changedOnStrap(change, current: .bool(false)))
        XCTAssertEqual(e.config?.value(.stressMonitoring), .bool(false), "the screen shows the strap's value")
        XCTAssertFalse(e.isBusy)
    }

    func testTheFreshReadRevalidatesAgainstTheStrapsCurrentAllowedValues() throws {
        var e = try readEditor()
        let change = ZeppHealthConfigEditor.Change(setting: .highHeartRateAlert, from: .byte(0), to: .byte(120))
        _ = try e.change(change, now: t0)
        var narrower = Settings()
        narrower.highHRAllowed = [0, 100, 110]
        let out = e.receive(narrower.reply, now: t0)
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events.last, .refused(change, .valueNotAllowed(.highHeartRateAlert, .byte(120))))

        // A prerequisite turned off on the strap meanwhile.
        var f = try readEditor()
        let relax = ZeppHealthConfigEditor.Change(setting: .relaxReminder, from: .bool(false), to: .bool(true))
        _ = try f.change(relax, now: t0)
        var stressOff = Settings()
        stressOff.stress = false
        let refused = f.receive(stressOff.reply, now: t0)
        XCTAssertEqual(refused.messages, [])
        XCTAssertEqual(refused.events.last, .refused(relax, .prerequisiteOff(.relaxReminder, needs: .stressMonitoring)))
    }

    func testARejectedWriteStillEndsWithTheStrapsActualValue() throws {
        var e = try readEditor()
        let change = ZeppHealthConfigEditor.Change(setting: .heartRateMonitoring, from: .byte(0xff), to: .byte(0x0a))
        _ = try e.change(change, now: t0)
        XCTAssertEqual(payloads(e.receive(Settings().reply, now: t0)), [hex("05 08 03 00 01 01 10 0a")])
        var out = e.receive([0x06, 0x02], now: t0)
        XCTAssertEqual(payloads(out), [ZeppHealthConfigEditor.readRequest], "re-read, never retry the write")
        XCTAssertEqual(out.events, [.writeNotAcknowledged(change, .status(0x02))])
        out = e.receive(Settings().reply, now: t0)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertEqual(check.failure, .status(0x02))
        XCTAssertFalse(check.matches)
        XCTAssertEqual(check.readBack, .byte(0xff))
        XCTAssertEqual(out.messages, [])
    }

    func testTimeouts() throws {
        // No ack: re-read anyway; that re-read times out too: unverified, and nothing more is sent.
        var e = try readEditor()
        let change = ZeppHealthConfigEditor.Change(setting: .highAccuracySleep, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t0)
        _ = e.receive(Settings().reply, now: t0)
        XCTAssertEqual(e.tick(now: t0.addingTimeInterval(4)), .init(), "not yet")
        var out = e.tick(now: t0.addingTimeInterval(5))
        XCTAssertEqual(payloads(out), [ZeppHealthConfigEditor.readRequest])
        XCTAssertEqual(out.events, [.writeNotAcknowledged(change, .noAck)])
        out = e.tick(now: t0.addingTimeInterval(10))
        XCTAssertEqual(out.events, [.writeUnverified(change, failure: .noAck, .timedOut)])
        XCTAssertEqual(out.messages, [])
        XCTAssertNil(e.config, "the strap's value is unknown now: nothing stale is shown as current")
        XCTAssertThrowsError(try e.change(change, now: t0)) { XCTAssertEqual($0 as? ZeppHealthConfigEditor.Error, .notRead) }
        // A late ack is ignored.
        XCTAssertEqual(e.receive([0x06, 0x01], now: t0), .init())

        // The pre-read times out: nothing is written.
        var f = try readEditor()
        _ = try f.change(change, now: t0)
        out = f.tick(now: t0.addingTimeInterval(5))
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events, [.readFailed(.timedOut), .refused(change, .notRead)])
    }

    func testGatesAndMalformedReplies() throws {
        let noConfig = ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices)
        var e = editor(noConfig)
        XCTAssertFalse(e.isOffered)
        XCTAssertThrowsError(try e.read(now: t0)) {
            XCTAssertEqual($0 as? ZeppControlError, .unsupported(.hapticAlerts, .endpointNotListed(ZeppEndpoint.config)))
        }
        for caps in [nil, ZeppConfigCapabilities(serviceVersion: 3, groups: [0x00, 0x0a]),
                     ZeppConfigCapabilities(serviceVersion: 4, groups: [0x08])] {
            var g = editor(configCapabilities: caps)
            XCTAssertFalse(g.isOffered)
            XCTAssertThrowsError(try g.read(now: t0)) { XCTAssertEqual($0 as? ZeppHealthConfigEditor.Error, .groupNotOffered) }
        }
        XCTAssertFalse(editor(ControlsFixtures.strapCapabilities(authenticated: false)).isOffered)
        XCTAssertFalse(editor(ControlsFixtures.strapCapabilities(model: nil)).isOffered)

        var m = editor()
        _ = try m.read(now: t0)
        XCTAssertEqual(m.receive(hex("04 00 08"), now: t0).events, [.readFailed(.malformed)], "status not 01")
        _ = try m.read(now: t0)
        var v9 = Settings()
        v9.version = 9
        XCTAssertEqual(m.receive(v9.reply, now: t0).events, [.readFailed(.unknownGroupVersion(9))])
        XCTAssertEqual(m.state, .unreadable(.unknownGroupVersion(9)))
    }

    func testGarbageNeverProducesAWrite() throws {
        var bytes = TestBytes(seed: 228)
        for _ in 0..<2000 {
            var e = try readEditor()
            if bytes.int(0...1) == 0 { _ = try e.read(now: t0) }
            var payload = bytes.bytes(bytes.int(0...40))
            if !payload.isEmpty, bytes.int(0...1) == 0 { payload[0] = [0x04, 0x06][bytes.int(0...1)] }
            let out = e.receive(payload, now: t0)
            XCTAssertFalse(out.messages.contains { $0.payload.first == 0x05 }, "only a user change can lead to a write")
        }
    }

    func testOverTheEncryptedLinkWithTheSimulatedStrap() throws {
        let device = FakeZeppDevice(authKey: hex("00112233445566778899aabbccddeeff"), privateKey: SpecC.strapDrawnPrivate,
                                    random: SpecC.strapRandom, writeLength: 20)
        device.services = ControlsFixtures.controlServices
        var settings = Settings()
        device.configReplies[ZeppHealthConfigEditor.readRequest] = settings.reply
        device.onConfigWrite = { write in
            // The strap applies `05 08 03 00 01 13 0b 00`: stress off.
            if write == hex("05 08 03 00 01 13 0b 00") { settings.stress = false }
            device.configReplies[ZeppHealthConfigEditor.readRequest] = settings.reply
        }
        var link = ZeppLink(authKey: SpecC.authKey, random: .system, maxWriteLength: 20)
        XCTAssertEqual(pump(&link, device, link.startAuthentication().writes), [.authenticated])
        var list: ZeppServicesList?
        for case .message(let m) in pump(&link, device, try link.send(endpoint: ZeppEndpoint.servicesList,
                                                                       payload: ZeppServicesList.request)) {
            list = ZeppServicesList.parse(m.payload)
        }
        link.apply(servicesList: try XCTUnwrap(list))
        var e = ZeppHealthConfigEditor(capabilities: ZeppControlCapabilities(model: .helioStrap, isAuthenticated: true,
                                                                             services: list))
        var events: [ZeppHealthConfigEditor.Event] = []
        func run(_ messages: [ZeppControlMessage]) throws {
            var queue = messages
            while !queue.isEmpty {
                let next = queue.removeFirst()
                for case .message(let reply) in pump(&link, device, try link.send(endpoint: next.endpoint, payload: next.payload)) {
                    XCTAssertTrue(reply.wasEncrypted, "config is encrypted by default (§5.5)")
                    if reply.payload.first == 0x02 {
                        e.noteConfigCapabilities(ZeppConfigCapabilities.parse(reply.payload))
                        continue
                    }
                    let out = e.receive(reply.payload, now: t0)
                    events += out.events
                    queue += out.messages
                }
            }
        }
        device.configCapabilitiesReply = hex("02 03 05 00 0b 08 09 0a")
        try run([ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: ZeppConfigCapabilities.request)])
        XCTAssertTrue(e.isOffered)
        try run(try e.read(now: t0).messages)
        XCTAssertEqual(device.configWrites, [], "reading writes nothing")
        try run(try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t0).messages)
        XCTAssertEqual(device.configWrites, [hex("05 08 03 00 01 13 0b 00")], "exactly one write, one arg")
        guard case .writeChecked(let check)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(check.matches)
        XCTAssertEqual(e.config?.availability(.relaxReminder), .needs(.stressMonitoring))
        XCTAssertEqual(device.failures, [])
    }
}
