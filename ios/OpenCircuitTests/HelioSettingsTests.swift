import XCTest
import ZeppKit
@testable import OpenCircuit

// The strap's settings and alerts in the app (#228, #230): `HelioSession` drives
// `ZeppHealthConfigEditor` against the simulated strap (`FakeZeppDevice`). Every key and setting is
// made up.

private let keyHex = "00112233445566778899aabbccddeeff"

/// The endpoints a Helio lists (§3.5), config encrypted.
private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x0082, 0),
]

/// A HEALTH read reply with constraints, made-up values: HR smart; active HR off; sleep on;
/// breathing on; stress `stress`; SpO₂ off; high HR off (0/100/110/120); low HR off (0/40/45/50);
/// relax off; low SpO₂ off (0/80/85/90).
private func settingsReply(stress: Bool = true, spo2: Bool = false, highHR: UInt8 = 0) -> [UInt8] {
    let entries: [[UInt8]] = [
        [0x01, 0x10, 0xff, 0x04, 0x00, 0xff, 0x05, 0x0a],
        [0x04, 0x0b, 0x00], [0x11, 0x0b, 0x01], [0x12, 0x0b, 0x01],
        [0x13, 0x0b, stress ? 0x01 : 0x00], [0x31, 0x0b, spo2 ? 0x01 : 0x00],
        [0x02, 0x10, highHR, 0x04, 0, 100, 110, 120], [0x03, 0x10, 0x00, 0x04, 0, 40, 45, 50],
        [0x14, 0x0b, 0x00], [0x32, 0x10, 0x00, 0x04, 0, 80, 85, 90],
    ]
    return [0x04, 0x01, 0x08, 0x03, 0x01, UInt8(entries.count)] + entries.flatMap { $0 }
}

@MainActor
private final class SettingsTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }
    func write(_ write: ZeppWrite) {
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) { inbox.append((characteristic, nil, enabled)) }
    func read(_ characteristic: ZeppCharacteristic) {
        if characteristic == .batteryLevel { inbox.append((characteristic, [64], false)) }
    }
    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 100_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes {
                session?.received(characteristic, bytes)
            } else {
                session?.notificationStateChanged(characteristic, enabled: enabled, failed: false)
            }
        }
    }
}

@MainActor
private final class Keys: HelioKeyStoring {
    var text: String?
    var isRejected = false
    init(_ text: String?) { self.text = text }
    func load() -> ZeppAuthKey? { text.flatMap(HelioKeyText.parse) }
    func save(pasted text: String) throws -> Bool { self.text = text; return true }
    func forget() { text = nil }
    func markRejected() { isRejected = true }
}

@MainActor
final class HelioSettingsTests: XCTestCase {
    private let strapID = "5B1E4C2A-0000-4000-8000-0000000000B2"
    private var now = Date(timeIntervalSince1970: 1_789_905_600)

    private func makeStrap() -> FakeZeppDevice {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = services
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        device.configCapabilitiesReply = [0x02, 0x03, 0x05, 0x00, 0x0b, 0x08, 0x09, 0x0a]
        device.configReplies[ZeppHealthConfigEditor.readRequest] = settingsReply()
        return device
    }

    private func connect(_ device: FakeZeppDevice, key: String? = keyHex) -> (HelioSession, SettingsTransport) {
        let transport = SettingsTransport(device: device)
        let keys = Keys(key)
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys, sink: nil,
                                   findState: HelioFindState(), clock: { [unowned self] in self.now },
                                   autoTick: false, autoSyncOnConnect: false)
        transport.session = session
        session.start()
        transport.drain()
        return (session, transport)
    }

    func testConnectingWritesNoSettingAndReadsNoneUntilAScreenAsks() {
        let device = makeStrap()
        let (session, _) = connect(device)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(device.configWrites, [], "§15.1: nothing is written at setup")
        XCTAssertTrue(session.canUseHealthSettings)
        XCTAssertEqual(session.healthConfigEditor?.state, .notRead)
    }

    func testReadingShowsTheStrapsValuesAndFeedsTheRecordingWarnings() throws {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readHealthSettings()
        transport.drain()
        let config = try XCTUnwrap(session.healthConfigEditor?.config)
        XCTAssertEqual(config.value(.heartRateMonitoring), .byte(0xff))
        XCTAssertEqual(config.availability(.lowSpO2Alert), .needs(.allDaySpO2))
        XCTAssertEqual(session.recordingWarnings, ["All-day SpO₂ is off, so automatic SpO₂ readings will be empty."])
        XCTAssertEqual(HelioSettingsDisplayCache.entry(strap: strapID)?.config, config, "kept for display only")
        XCTAssertEqual(device.configWrites, [])
    }

    func testOneChangeWritesOneArgThenShowsTheReRead() throws {
        let device = makeStrap()
        device.onConfigWrite = { write in
            if write == [0x05, 0x08, 0x03, 0x00, 0x01, 0x31, 0x0b, 0x01] {
                device.configReplies[ZeppHealthConfigEditor.readRequest] = settingsReply(spo2: true)
            }
        }
        let (session, transport) = connect(device)
        session.readHealthSettings()
        transport.drain()
        XCTAssertNil(session.changeHealthSetting(.allDaySpO2, from: .bool(false), to: .bool(true)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [[0x05, 0x08, 0x03, 0x00, 0x01, 0x31, 0x0b, 0x01]])
        XCTAssertEqual(session.healthSettingsNotice, "Saved on the strap.")
        XCTAssertEqual(session.healthConfigEditor?.config?.value(.allDaySpO2), .bool(true))
        XCTAssertEqual(session.healthConfigEditor?.config?.availability(.lowSpO2Alert), .available)
        XCTAssertEqual(session.recordingWarnings, [], "the warning follows the strap's new value")
    }

    func testARejectedWriteShowsTheStrapsActualValueAndSaysSo() throws {
        let device = makeStrap()
        device.configWriteAckStatus = 0x02
        let (session, transport) = connect(device)
        session.readHealthSettings()
        transport.drain()
        XCTAssertNil(session.changeHealthSetting(.highHeartRateAlert, from: .byte(0), to: .byte(110)))
        transport.drain()
        XCTAssertEqual(device.configWrites.count, 1, "never retried")
        XCTAssertEqual(session.healthConfigEditor?.config?.value(.highHeartRateAlert), .byte(0), "the re-read value")
        XCTAssertEqual(session.healthSettingsNotice,
                       "The strap didn't accept the change. Its current value is shown. Nothing was retried.")
    }

    func testAValueChangedElsewhereIsNotOverwritten() throws {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readHealthSettings()
        transport.drain()
        device.configReplies[ZeppHealthConfigEditor.readRequest] = settingsReply(highHR: 120)   // changed in Zepp
        XCTAssertNil(session.changeHealthSetting(.highHeartRateAlert, from: .byte(0), to: .byte(110)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [])
        XCTAssertEqual(session.healthConfigEditor?.config?.value(.highHeartRateAlert), .byte(120))
        XCTAssertTrue(session.healthSettingsNotice?.contains("changed on the strap") == true)
    }

    func testRefusedChangesSendNothing() throws {
        let device = makeStrap()
        let (session, transport) = connect(device)
        session.readHealthSettings()
        transport.drain()
        XCTAssertEqual(session.changeHealthSetting(.lowSpO2Alert, from: .byte(0), to: .byte(90)), "Needs all-day SpO₂ on.")
        XCTAssertEqual(session.changeHealthSetting(.highHeartRateAlert, from: .byte(0), to: .byte(105)),
                       "The strap doesn't allow that value.")
        XCTAssertEqual(session.changeHealthSetting(.stressMonitoring, from: .bool(true), to: .bool(true)),
                       "That's already the strap's setting.")
        transport.drain()
        XCTAssertEqual(device.configWrites, [])
    }

    func testAKeylessStrapOffersNoChanges() {
        let device = makeStrap()
        let (session, transport) = connect(device, key: nil)
        XCTAssertEqual(session.phase, .keyless)
        XCTAssertFalse(session.canUseHealthSettings)
        session.readHealthSettings()
        XCTAssertNotNil(session.changeHealthSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [])
        let reason = HelioSettingsCopy.blockedReason(status: HelioStatus.keyNeeded, sessionCanChange: false, offered: nil)
        XCTAssertEqual(reason, "Add the strap's key to change its settings.")
    }

    func testEveryStatusExplainsItselfAndOnlyAUsableSessionUnblocks() {
        let kinds: [HelioStatus] = [HelioStatus.busy, .keyNeeded, .rejected,
                                    HelioStatus(kind: .disconnected, title: "Not connected", detail: nil, tone: .neutral),
                                    HelioStatus(kind: .settingUp, title: "", detail: nil, tone: .working)]
        for status in kinds {
            XCTAssertNotNil(HelioSettingsCopy.blockedReason(status: status, sessionCanChange: false, offered: nil))
        }
        let ready = HelioStatus(kind: .ready, title: "Connected", detail: nil, tone: .good)
        XCTAssertNil(HelioSettingsCopy.blockedReason(status: ready, sessionCanChange: true, offered: true))
        XCTAssertEqual(HelioSettingsCopy.blockedReason(status: ready, sessionCanChange: false, offered: false),
                       "The strap didn't offer its health settings on this connection.")
        XCTAssertTrue(HelioSettingsCopy.blockedReason(status: HelioStatus.busy, sessionCanChange: false, offered: nil)!
            .contains("Another phone or app"))
    }

    func testCopyNamesValuesTheWayTheStrapMeansThem() {
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0xff), for: .heartRateMonitoring), "Smart")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(0), for: .heartRateMonitoring), "Off")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(10), for: .heartRateMonitoring), "Every 10 min")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(120), for: .highHeartRateAlert), "Above 120 bpm")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(45), for: .lowHeartRateAlert), "Below 45 bpm")
        XCTAssertEqual(HelioSettingsCopy.value(.byte(90), for: .lowSpO2Alert), "Below 90 %")
        XCTAssertEqual(HelioSettingsCopy.needs(.stressMonitoring), "Needs stress monitoring on. Turn it on in Measurement.")
        XCTAssertNil(HelioSettingsCopy.offConsequence(.activeHeartRateMonitoring, .bool(false)),
                     "§5.5: it doesn't gate recording, so off is never a warning")
        XCTAssertTrue(HelioSettingsCopy.explanation(.activeHeartRateMonitoring).contains("doesn't decide whether heart rate is recorded"))
        XCTAssertTrue(HelioSettingsCopy.alertsHeader.contains("separate from OpenCircuit's notifications"))
        for setting in ZeppHealthSetting.allCases {
            let text = HelioSettingsCopy.explanation(setting)
            if ZeppHealthSetting.measurement.contains(setting) {
                XCTAssertFalse(text.contains { $0.isASCII && $0.isNumber }, "battery cost in words: no invented figures")
            }
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "no emoji")
        }
    }
}
