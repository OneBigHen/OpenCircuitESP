// Edge cases of ZeppSettingsEditor's one write path, ported from review-240's probes, plus the
// §17.8 step 1 gate on the write itself (review-240 S1, S2). Every value is made up.

import XCTest
@testable import ZeppKit
import ZeppKitTesting

private let caps = ZeppConfigCapabilities(serviceVersion: 3, groups: [0x00, 0x0b, 0x08, 0x09, 0x0a])
private let t = date(1_790_764_496)

private func writes(_ out: ZeppSettingsEditor.Output) -> [[UInt8]] { out.messages.map(\.payload).filter { $0.first == 0x05 } }

/// HEALTH v3 full read: stress on, relax off, high HR 0 (0/100/110/120), SpO₂ off, low SpO₂ 0.
private let healthFull = hex("04 01 08 03 01 05 13 0b 01 14 0b 00 02 10 00 04 00 64 6e 78 31 0b 00 32 10 00 04 00 50 55 5a")

private func readEditor(_ capabilities: ZeppConfigCapabilities? = caps) throws -> ZeppSettingsEditor {
    var e = ZeppSettingsEditor(capabilities: ControlsFixtures.strapCapabilities(), configCapabilities: capabilities)
    _ = try e.read(groups: [0x08], now: t)
    _ = e.receive(healthFull, now: t)
    return e
}

final class SettingsEdgeTests: XCTestCase {

    /// review-240 S1/S2: a sync or backgrounding between the tap and the pre-read's reply. The caller
    /// says `mayWrite: false`: the change ends refused as busy and nothing is sent.
    func testAWriteTheCallerMayNotSendNowIsRefusedAndNothingGoesOut() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .stressMonitoring, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t)
        let out = e.receive(hex("04 01 08 03 01 01 13 0b 01"), now: t, mayWrite: false)
        XCTAssertEqual(out.messages, [], "no write, and no further read")
        XCTAssertEqual(out.events, [.read(group: 0x08), .refused(change, .busy)])
        XCTAssertFalse(e.isBusy)
        XCTAssertEqual(e.snapshot.value(.stressMonitoring), .bool(true), "the screen keeps the strap's value")
        // The next change, once allowed, goes out normally.
        _ = try e.change(change, now: t)
        XCTAssertEqual(writes(e.receive(hex("04 01 08 03 01 01 13 0b 01"), now: t)), [hex("05 08 03 00 01 13 0b 00")])
    }

    /// `mayWrite` only gates the write: plain reads and re-reads after a write already sent still run.
    func testMayWriteFalseNeverBlocksReadsOrTheReRead() throws {
        var e = try readEditor()
        let change = ZeppSettingsEditor.Change(setting: .stressMonitoring, from: .bool(true), to: .bool(false))
        _ = try e.change(change, now: t)
        _ = e.receive(hex("04 01 08 03 01 01 13 0b 01"), now: t)
        XCTAssertEqual(e.receive(hex("06 01"), now: t, mayWrite: false).messages.map(\.payload), [hex("03 01 08 01 13")])
        let out = e.receive(hex("04 01 08 03 01 01 13 0b 00"), now: t, mayWrite: false)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertTrue(check.tookChange)
        var r = ZeppSettingsEditor(capabilities: ControlsFixtures.strapCapabilities(), configCapabilities: caps)
        _ = try r.read(groups: [0x08], now: t)
        XCTAssertEqual(r.receive(healthFull, now: t, mayWrite: false).events, [.read(group: 0x08)])
    }

    /// The pre-read reports a HEALTH version the spec doesn't describe (4): refuse, write nothing.
    func testPreReadAtAnUndescribedVersionWritesNothing() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t)
        let out = e.receive(hex("04 01 08 04 01 01 13 0b 01"), now: t)
        XCTAssertEqual(writes(out), [])
    }

    /// The pre-read (family read) doesn't report the parent: relax reminder must not be written.
    func testPreReadWithoutTheParentWritesNoChild() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .relaxReminder, from: .bool(false), to: .bool(true)), now: t)
        let out = e.receive(hex("04 01 08 03 01 01 14 0b 00"), now: t)
        XCTAssertEqual(writes(out), [])
    }

    /// The parent turned off between the screen's read and the pre-read: refuse the child.
    func testParentOffOnPreReadWritesNoChild() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .relaxReminder, from: .bool(false), to: .bool(true)), now: t)
        let out = e.receive(hex("04 01 08 03 01 02 13 0b 00 14 0b 00"), now: t)
        XCTAssertEqual(writes(out), [])
    }

    /// The pre-read narrows the allowed list so the picked value is gone: refuse.
    func testPreReadNarrowingTheAllowedListWritesNothing() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .highHeartRateAlert, from: .byte(0), to: .byte(110)), now: t)
        let out = e.receive(hex("04 01 08 03 01 01 02 10 00 02 00 64"), now: t)
        XCTAssertEqual(writes(out), [])
    }

    /// The pre-read retypes the arg (bool instead of byte): refuse, and hide.
    func testPreReadRetypingTheArgWritesNothing() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .highHeartRateAlert, from: .byte(0), to: .byte(110)), now: t)
        let out = e.receive(hex("04 01 08 03 01 01 02 0b 00"), now: t)
        XCTAssertEqual(writes(out), [])
        XCTAssertEqual(e.snapshot.availability(.highHeartRateAlert), .notReported)
    }

    /// Config service version 4: nothing offered, so nothing read or written.
    func testUnknownConfigServiceVersionOffersNothing() throws {
        let v4 = ZeppConfigCapabilities(serviceVersion: 4, groups: [0x08, 0x09])
        var e = ZeppSettingsEditor(capabilities: ControlsFixtures.strapCapabilities(), configCapabilities: v4)
        XCTAssertThrowsError(try e.read(groups: [0x08], now: t))
        XCTAssertThrowsError(try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t))
        var none = ZeppSettingsEditor(capabilities: ControlsFixtures.strapCapabilities(), configCapabilities: nil)
        XCTAssertThrowsError(try none.read(groups: [0x08], now: t))
    }

    /// A re-read whose parse stops early (unknown type code first): never "took".
    func testPartialReReadNeverCountsAsTaken() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t)
        _ = e.receive(hex("04 01 08 03 01 01 13 0b 01"), now: t)
        _ = e.receive(hex("06 01"), now: t)
        let out = e.receive(hex("04 01 08 03 01 02 13 77 00 13 0b 00"), now: t)
        guard case .writeChecked(let check)? = out.events.first else { return XCTFail("\(out.events)") }
        XCTAssertFalse(check.tookChange)
    }

    /// A re-read reply for the WRONG group while verifying a HEALTH write: never "took".
    func testWrongGroupReReadNeverCountsAsTaken() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t)
        _ = e.receive(hex("04 01 08 03 01 01 13 0b 01"), now: t)
        _ = e.receive(hex("06 01"), now: t)
        let out = e.receive(hex("04 01 09 01 01 01 13 0b 00"), now: t)
        XCTAssertFalse(out.events.contains { if case .writeChecked(let c) = $0 { return c.tookChange }; return false })
    }

    /// A stray `06 01` that arrives during the pre-read must not count as the ack of the coming write.
    func testStrayAckDuringPreReadIsIgnored() throws {
        var e = try readEditor()
        _ = try e.change(.init(setting: .stressMonitoring, from: .bool(true), to: .bool(false)), now: t)
        XCTAssertEqual(e.receive(hex("06 01"), now: t), .init())
        XCTAssertEqual(writes(e.receive(hex("04 01 08 03 01 01 13 0b 01"), now: t)), [hex("05 08 03 00 01 13 0b 00")])
        XCTAssertTrue(e.isBusy, "still waiting for the real ack")
    }

    /// WORKOUT `40` and HEALTH `05` are unreachable through the editor, whatever the strap reports.
    func testArgs40And05AreNeverWritable() throws {
        XCTAssertFalse(ZeppSetting.allCases.contains { $0.group == 0x09 && $0.argument == 0x40 })
        XCTAssertFalse(ZeppSetting.allCases.contains { $0.group == 0x08 && $0.argument == 0x05 })
        var e = ZeppSettingsEditor(capabilities: ControlsFixtures.strapCapabilities(), configCapabilities: caps)
        _ = try e.read(groups: [0x09], now: t)
        _ = e.receive(hex("04 01 09 01 01 03 40 11 01 03 02 01 03 41 0b 00 42 10 01 03 00 01 02"), now: t)
        for setting in ZeppSetting.allCases where setting.group == 0x09 {
            XCTAssertNotEqual(setting.argument, 0x40)
        }
    }
}
