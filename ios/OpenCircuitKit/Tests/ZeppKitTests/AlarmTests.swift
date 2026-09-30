// Alarms (§12, §15.2): record round-trips over the edge cases, rejection of invalid input, the list
// reply's validation, parsers against truncated and garbage input, and the read-before-write editor.

import XCTest
@testable import ZeppKit

final class AlarmCodecTests: XCTestCase {

    private func roundTrip(_ alarm: ZeppAlarm, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try alarm.record()
        XCTAssertEqual(record.count, 10, file: file, line: line)
        XCTAssertEqual(Array(record[5...]), [0, 0, 0, 0, 0], file: file, line: line)
        let back = try XCTUnwrap(ZeppAlarm.parse(record: record[...]), file: file, line: line)
        XCTAssertTrue(back.hasSameSetting(as: alarm), "\(alarm.summary) → \(back.summary)", file: file, line: line)
        // And through a one-alarm list reply, as the strap would return it (byte [8] = 01).
        var returned = record
        returned[8] = 0x01
        guard case .success(let listed) = ZeppAlarmList.parse([0x0a, 0x01] + returned) else {
            return XCTFail("list rejected \(alarm.summary)", file: file, line: line)
        }
        XCTAssertEqual(listed.count, 1, file: file, line: line)
        XCTAssertTrue(listed[0].hasSameSetting(as: alarm), file: file, line: line)
    }

    func testRoundTripsAtTheEdges() throws {
        try roundTrip(ZeppAlarm(slot: 0, hour: 0, minute: 0))                          // 00:00, once
        try roundTrip(ZeppAlarm(slot: 9, hour: 23, minute: 59))                        // 23:59, last slot
        try roundTrip(ZeppAlarm(slot: 4, hour: 12, minute: 0, days: .once))            // no days
        try roundTrip(ZeppAlarm(slot: 5, hour: 7, minute: 15, days: .everyDay))        // all days
        try roundTrip(ZeppAlarm(slot: 1, hour: 6, minute: 30, days: .weekdays, isEnabled: false))
        try roundTrip(ZeppAlarm(slot: 2, hour: 9, minute: 15, days: .weekend, smartWake: true))
        let singles: [(ZeppAlarmDays, UInt8)] = [(.monday, 0x01), (.tuesday, 0x02), (.wednesday, 0x04), (.thursday, 0x08),
                                                 (.friday, 0x10), (.saturday, 0x20), (.sunday, 0x40)]
        for (day, bit) in singles {
            let alarm = ZeppAlarm(slot: 3, hour: 23, minute: 59, days: day)
            XCTAssertEqual(try alarm.record()[4], bit)
            try roundTrip(alarm)
        }
        XCTAssertEqual(try ZeppAlarm(slot: 0, hour: 0, minute: 0).record(), hex("04 00 00 00 00 00 00 00 00 00"))
        XCTAssertEqual(try ZeppAlarm(slot: 9, hour: 23, minute: 59, days: .everyDay).record(),
                       hex("04 09 17 3b 7f 00 00 00 00 00"))
        XCTAssertEqual(try ZeppAlarm(slot: 2, hour: 1, minute: 2, isEnabled: false, smartWake: true).record()[0], 0x01)
    }

    func testInvalidInputIsRejectedAndNeverEncoded() {
        let cases: [(ZeppAlarm, ZeppAlarmError)] = [
            (ZeppAlarm(slot: 10, hour: 6, minute: 0), .slotOutOfRange(10)),
            (ZeppAlarm(slot: 255, hour: 6, minute: 0), .slotOutOfRange(255)),
            (ZeppAlarm(slot: 0, hour: 24, minute: 0), .hourOutOfRange(24)),
            (ZeppAlarm(slot: 0, hour: 6, minute: 60), .minuteOutOfRange(60)),
            (ZeppAlarm(slot: 0, hour: 6, minute: 0, days: ZeppAlarmDays(rawValue: 0x80)), .invalidDays(0x80)),
            (ZeppAlarm(slot: 0, hour: 6, minute: 0, days: ZeppAlarmDays(rawValue: 0xff)), .invalidDays(0xff)),
        ]
        for (alarm, error) in cases {
            XCTAssertThrowsError(try alarm.record()) { XCTAssertEqual($0 as? ZeppAlarmError, error) }
            XCTAssertThrowsError(try ZeppAlarmCommand.createOrReplace(alarm)) { XCTAssertEqual($0 as? ZeppAlarmError, error) }
        }
        XCTAssertThrowsError(try ZeppAlarmCommand.delete(slot: 10)) { XCTAssertEqual($0 as? ZeppAlarmError, .slotOutOfRange(10)) }
        XCTAssertNoThrow(try ZeppAlarmCommand.delete(slot: 9))
        // Only smart wake (bit 0) and enabled (bit 2) are ever written, whatever the strap returned.
        guard case .success(let read) = ZeppAlarmList.parse(hex("0a 01 fe 04 08 00 01 11 22 33 44 55")) else { return XCTFail() }
        XCTAssertEqual(read[0].rawFlags, 0xfe)
        XCTAssertEqual(try ZeppAlarmCommand.createOrReplace(read[0]), hex("03 01 04 04 08 00 01 00 00 00 00 00"))
    }

    func testListValidation() {
        let r0 = hex("04 00 06 1e 1f 00 00 00 01 00")
        let r3 = hex("01 03 09 0f 60 00 00 00 01 00")
        XCTAssertEqual(try? ZeppAlarmList.parse(hex("0a 00")).get(), [])
        // Sorted by slot whatever the strap's order.
        XCTAssertEqual(try? ZeppAlarmList.parse([0x0a, 0x02] + r3 + r0).get().map(\.slot), [0, 3])

        func failure(_ payload: [UInt8]) -> ZeppAlarmListError? {
            if case .failure(let error) = ZeppAlarmList.parse(payload) { return error }
            return nil
        }
        XCTAssertEqual(failure([]), .notAList)
        XCTAssertEqual(failure(hex("0a")), .notAList)
        XCTAssertEqual(failure(hex("04 01")), .notAList)
        XCTAssertEqual(failure([0x0a, 0x02] + r0), .lengthMismatch(count: 2, length: 12))           // short
        XCTAssertEqual(failure([0x0a, 0x01] + r0 + [0x00]), .lengthMismatch(count: 1, length: 13))  // long
        let eleven = (0..<11).flatMap { i -> [UInt8] in [0x04, UInt8(i), 6, 0, 0, 0, 0, 0, 1, 0] }
        XCTAssertEqual(failure([0x0a, 0x0b] + eleven), .tooManyAlarms(11))
        XCTAssertEqual(failure([0x0a, 0x01] + hex("04 0a 06 00 00 00 00 00 01 00")), .slotOutOfRange(10))
        XCTAssertEqual(failure([0x0a, 0x02] + r0 + r0), .duplicateSlot(0))
        XCTAssertEqual(failure([0x0a, 0x01] + hex("04 01 18 00 00 00 00 00 01 00")), .invalidAlarm(slot: 1, .hourOutOfRange(24)))
        XCTAssertEqual(failure([0x0a, 0x01] + hex("04 01 06 3c 00 00 00 00 01 00")), .invalidAlarm(slot: 1, .minuteOutOfRange(60)))
        XCTAssertEqual(failure([0x0a, 0x01] + hex("04 01 06 00 80 00 00 00 01 00")), .invalidAlarm(slot: 1, .invalidDays(0x80)))
        // Ten alarms is the documented maximum and is fine.
        let ten = (0..<10).flatMap { i -> [UInt8] in [0x04, UInt8(i), 6, 0, 0, 0, 0, 0, 1, 0] }
        XCTAssertEqual(try? ZeppAlarmList.parse([0x0a, 0x0a] + ten).get().count, 10)
    }

    func testRepliesAndUnknownOpcodes() {
        XCTAssertEqual(ZeppAlarmReply.parse(hex("04 02")), .createAck(status: 0x02))
        XCTAssertEqual(ZeppAlarmReply.parse(hex("04")), .createAck(status: nil))
        XCTAssertEqual(ZeppAlarmReply.parse(hex("08 01")), .updateAck(status: 0x01))
        XCTAssertEqual(ZeppAlarmReply.parse(hex("0f")), .changedOnStrap)
        XCTAssertEqual(ZeppAlarmReply.parse(hex("0f 99 99")), .changedOnStrap)
        for opcode: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x10, 0xff] {
            XCTAssertNil(ZeppAlarmReply.parse([opcode, 0x01]), "opcode \(opcode)")
        }
        XCTAssertNil(ZeppAlarmReply.parse([]))
    }

    func testDaysListAndSummaries() {
        XCTAssertEqual(ZeppAlarmDays(list: "mon,wed,fri"), [.monday, .wednesday, .friday])
        XCTAssertEqual(ZeppAlarmDays(list: "Mon+Sun"), [.monday, .sunday])
        XCTAssertEqual(ZeppAlarmDays(list: "weekdays"), .weekdays)
        XCTAssertEqual(ZeppAlarmDays(list: "WEEKEND"), .weekend)
        XCTAssertEqual(ZeppAlarmDays(list: "daily"), .everyDay)
        XCTAssertEqual(ZeppAlarmDays(list: "weekdays,sat"), [.weekdays, .saturday])
        XCTAssertEqual(ZeppAlarmDays(list: "once"), .once)
        for bad in ["", ",", "funday", "once,mon", "monday", "1"] {
            XCTAssertNil(ZeppAlarmDays(list: bad), bad)
        }
        XCTAssertEqual(ZeppAlarmDays(list: "mon,"), .monday)          // an empty token is skipped
        XCTAssertEqual(ZeppAlarmDays.once.summary, "once")
        XCTAssertEqual(ZeppAlarmDays.everyDay.summary, "daily")
        XCTAssertEqual(ZeppAlarmDays.weekdays.summary, "weekdays")
        XCTAssertEqual(ZeppAlarmDays([.monday, .friday]).summary, "mon fri")
        XCTAssertEqual(ZeppAlarmDays(rawValue: 0x81).summary, "mon +bit7")
        XCTAssertEqual(ZeppAlarm(slot: 0, hour: 6, minute: 5, days: .weekdays).summary, "slot 0  06:05  weekdays  on")
    }

    /// Truncations of example G and random bytes: no trap, no over-read, never a partial list.
    func testParsersSurviveTruncationAndGarbage() {
        let g = hex("0a 02 04 00 06 1e 1f 00 00 00 01 00 01 03 09 0f 60 00 00 00 01 00")
        for length in 0..<g.count {
            let prefix = Array(g.prefix(length))
            if case .success = ZeppAlarmList.parse(prefix) { XCTFail("accepted a \(length)-byte prefix") }
            _ = ZeppAlarmReply.parse(prefix)
        }
        for length in 0...12 { _ = ZeppAlarm.parse(record: hex("04 00 06 1e 1f 00 00 00 01 00 ff ff").prefix(length)) }
        XCTAssertNil(ZeppAlarm.parse(record: hex("04 00 06")[...]))
        var gen = TestBytes(seed: 0x0a1a)
        for _ in 0..<5000 {
            let length = gen.int(0...120)
            var bytes = gen.bytes(length)
            if !bytes.isEmpty, gen.int(0...1) == 0 { bytes[0] = 0x0a }
            if case .success(let alarms) = ZeppAlarmList.parse(bytes) {
                XCTAssertEqual(bytes.count, 2 + 10 * alarms.count)
                XCTAssertTrue(alarms.allSatisfy { (try? $0.validate()) != nil })
            }
            _ = ZeppAlarmReply.parse(bytes)
        }
    }
}

final class AlarmEditorTests: XCTestCase {

    private let t0 = date(1_790_764_496)
    private let listG = hex("0a 02 04 00 06 1e 1f 00 00 00 01 00 01 03 09 0f 60 00 00 00 01 00")
    private let listSlot3 = hex("0a 01 01 03 09 0f 60 00 00 00 01 00")

    private func alarmsEndpoint(_ payload: [UInt8]) -> ZeppControlMessage {
        ZeppControlMessage(endpoint: ZeppEndpoint.alarms, payload: payload)
    }

    /// An editor that has read `list` and (optionally) seen `06 01`.
    private func readyEditor(list: [UInt8], timeSet: Bool = true) throws -> ZeppAlarmEditor {
        var editor = ZeppAlarmEditor(capabilities: ControlsFixtures.strapCapabilities())
        XCTAssertEqual(try editor.read(now: t0).messages, [alarmsEndpoint([0x09])])
        _ = editor.receive(list, now: t0 + 1)
        if timeSet { XCTAssertTrue(editor.noteTimeSetReply([0x06, 0x01])) }
        return editor
    }

    func testUnsupportedSendsNothing() {
        for capabilities in [ControlsFixtures.strapCapabilities(ControlsFixtures.bareServices),
                             ControlsFixtures.strapCapabilities(model: .helioRing),
                             ControlsFixtures.strapCapabilities(authenticated: false),
                             ZeppControlCapabilities(model: .helioStrap, isAuthenticated: true, services: nil),
                             .disconnected] {
            var editor = ZeppAlarmEditor(capabilities: capabilities)
            XCTAssertThrowsError(try editor.read(now: t0)) {
                guard case ZeppControlError.unsupported(.alarms, _)? = $0 as? ZeppControlError else { return XCTFail("\($0)") }
            }
            XCTAssertThrowsError(try editor.add(hour: 6, minute: 0, now: t0))
            XCTAssertThrowsError(try editor.delete(slot: 0, now: t0))
            XCTAssertFalse(editor.canView)
            XCTAssertFalse(editor.canEdit)
            XCTAssertEqual(editor.receive(listG, now: t0), .init())           // unsolicited: ignored
            XCTAssertEqual(editor.list, .notRead)
        }
    }

    func testReadThenAddToTheLowestFreeSlotThenVerify() throws {
        var editor = try readyEditor(list: listSlot3, timeSet: false)
        XCTAssertTrue(editor.canView)
        XCTAssertFalse(editor.canEdit)
        XCTAssertThrowsError(try editor.add(hour: 6, minute: 30, days: .weekdays, now: t0)) {
            XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .timeNotSet)
        }
        XCTAssertFalse(editor.noteTimeSetReply([0x08, 0x01]))      // a DST reply is not a time set
        XCTAssertFalse(editor.noteTimeSetReply([0x06, 0x02]))
        XCTAssertTrue(editor.noteTimeSetReply([0x06, 0x01]))
        XCTAssertTrue(editor.canEdit)

        // Example F: slot 3 is taken, so the new alarm goes to slot 0.
        let write = try editor.add(hour: 6, minute: 30, days: .weekdays, now: t0 + 2)
        XCTAssertEqual(write.messages, [alarmsEndpoint(hex("03 01 04 00 06 1e 1f 00 00 00 00 00"))])
        XCTAssertTrue(editor.isBusy)
        XCTAssertThrowsError(try editor.read(now: t0 + 2)) { XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .busy) }
        XCTAssertThrowsError(try editor.add(hour: 7, minute: 0, now: t0 + 2)) { XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .busy) }

        let ack = editor.receive(hex("04 01"), now: t0 + 3)
        let written = ZeppAlarm(slot: 0, hour: 6, minute: 30, days: .weekdays)
        XCTAssertEqual(ack.messages, [alarmsEndpoint([0x09])])          // re-read (§15.2 step 7)
        XCTAssertEqual(ack.events, [.writeAcknowledged(.set(written))])

        let check = editor.receive(listG, now: t0 + 4)
        guard case .writeChecked(let result)? = check.events.first else { return XCTFail("\(check)") }
        XCTAssertTrue(result.slotMatches)
        XCTAssertTrue(result.otherSlotsUnchanged)
        XCTAssertEqual(result.list.map(\.slot), [0, 3])
        XCTAssertEqual(check.messages, [])
        XCTAssertEqual(editor.freeSlots, [1, 2, 4, 5, 6, 7, 8, 9])
        XCTAssertTrue(editor.canEdit)
    }

    func testCheckReportsAWrongSlotAndOtherSlotsThatMoved() throws {
        var editor = try readyEditor(list: listSlot3)
        _ = try editor.add(hour: 6, minute: 30, days: .weekdays, now: t0)
        _ = editor.receive(hex("04 01"), now: t0)
        // The re-read shows slot 0 at 06:31, and slot 3 gone.
        let events = editor.receive(hex("0a 01 04 00 06 1f 1f 00 00 00 01 00"), now: t0).events
        guard case .writeChecked(let result)? = events.first else { return XCTFail("\(events)") }
        XCTAssertFalse(result.slotMatches)
        XCTAssertFalse(result.otherSlotsUnchanged)
    }

    func testReplaceKeepsOneSlotAndRefusesWhatV1DoesNotOffer() throws {
        var editor = try readyEditor(list: listG)
        var slot3 = try XCTUnwrap(editor.alarms?.first { $0.slot == 3 })
        slot3.isEnabled = true                                            // enable: a replace (§12.2)
        XCTAssertEqual(try editor.replace(slot3, now: t0).messages,
                       [alarmsEndpoint(hex("03 01 05 03 09 0f 60 00 00 00 00 00"))])   // smart wake kept

        editor = try readyEditor(list: listG)
        var toggled = try XCTUnwrap(editor.alarms?.first { $0.slot == 3 })
        toggled.smartWake = false
        XCTAssertThrowsError(try editor.replace(toggled, now: t0)) { XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .smartWakeNotOffered) }
        XCTAssertThrowsError(try editor.replace(ZeppAlarm(slot: 5, hour: 1, minute: 0), now: t0)) {
            XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .slotEmpty(5))
        }
        var bad = try XCTUnwrap(editor.alarms?.first { $0.slot == 0 })
        bad.hour = 24
        XCTAssertThrowsError(try editor.replace(bad, now: t0)) {
            XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .invalidAlarm(.hourOutOfRange(24)))
        }
        XCTAssertThrowsError(try editor.add(hour: 6, minute: 60, now: t0)) {
            XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .invalidAlarm(.minuteOutOfRange(60)))
        }
        XCTAssertFalse(editor.isBusy)                                    // nothing went out
    }

    func testDeleteOnlyAnExistingSlotAndVerifyItIsGone() throws {
        var editor = try readyEditor(list: listG)
        XCTAssertThrowsError(try editor.delete(slot: 4, now: t0)) { XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .slotEmpty(4)) }
        XCTAssertEqual(try editor.delete(slot: 0, now: t0).messages, [alarmsEndpoint(hex("05 01 00"))])
        XCTAssertEqual(editor.receive(hex("04 01"), now: t0), .init())    // a create ack is not ours
        XCTAssertEqual(editor.receive(hex("06 01"), now: t0).messages, [alarmsEndpoint([0x09])])
        let events = editor.receive(listSlot3, now: t0).events
        guard case .writeChecked(let result)? = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue(result.slotMatches)
        XCTAssertTrue(result.otherSlotsUnchanged)
    }

    func testNoFreeSlot() throws {
        let ten = (0..<10).flatMap { i -> [UInt8] in [0x04, UInt8(i), 6, 0, 0, 0, 0, 0, 1, 0] }
        var editor = try readyEditor(list: [0x0a, 0x0a] + ten)
        XCTAssertEqual(editor.freeSlots, [])
        XCTAssertThrowsError(try editor.add(hour: 6, minute: 0, now: t0)) { XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .noFreeSlot) }
    }

    func testChangedOnStrapForcesAReRead() throws {
        var editor = try readyEditor(list: listSlot3)
        XCTAssertEqual(editor.receive([0x0f], now: t0).events, [.changedOnStrap])
        XCTAssertTrue(editor.isListStale)
        XCTAssertFalse(editor.canEdit)
        XCTAssertTrue(editor.canView)                                     // still viewable, not editable
        XCTAssertThrowsError(try editor.add(hour: 6, minute: 0, now: t0)) {
            XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .listChangedOnStrap)
        }
        _ = try editor.read(now: t0)
        _ = editor.receive([0x0f], now: t0)                               // a change while the read is in flight
        _ = editor.receive(listSlot3, now: t0)
        XCTAssertTrue(editor.isListStale)                                 // the list may predate it
        _ = try editor.read(now: t0)
        _ = editor.receive(listSlot3, now: t0)
        XCTAssertFalse(editor.isListStale)
        XCTAssertTrue(editor.canEdit)
    }

    func testFailedAckIsReportedNotRetried() throws {
        var editor = try readyEditor(list: listSlot3)
        _ = try editor.add(hour: 6, minute: 0, now: t0)
        let failed = editor.receive(hex("04 02"), now: t0)
        XCTAssertEqual(failed.messages, [])
        XCTAssertEqual(failed.events, [.writeFailed(.set(ZeppAlarm(slot: 0, hour: 6, minute: 0)), .status(0x02))])
        XCTAssertTrue(editor.isListStale)
        XCTAssertFalse(editor.canEdit)

        editor = try readyEditor(list: listSlot3)
        _ = try editor.delete(slot: 3, now: t0)
        XCTAssertEqual(editor.receive(hex("06"), now: t0).events, [.writeFailed(.delete(slot: 3), .status(nil))])
    }

    func testTimeouts() throws {
        var editor = ZeppAlarmEditor(capabilities: ControlsFixtures.strapCapabilities(),
                                     configuration: .init(replyTimeout: 5))
        _ = try editor.read(now: t0)
        XCTAssertEqual(editor.nextDeadline, t0 + 5)
        XCTAssertEqual(editor.tick(now: t0 + 4.9), .init())
        XCTAssertEqual(editor.tick(now: t0 + 5).events, [.listUnreadable(.timedOut)])
        XCTAssertEqual(editor.list, .unreadable(.timedOut))
        XCTAssertFalse(editor.canView)
        XCTAssertEqual(editor.receive(listG, now: t0 + 6), .init())       // too late: ignored
        XCTAssertNil(editor.nextDeadline)

        editor = try readyEditor(list: listSlot3)
        _ = try editor.add(hour: 6, minute: 0, now: t0)
        XCTAssertEqual(editor.tick(now: t0 + 5).events, [.writeFailed(.set(ZeppAlarm(slot: 0, hour: 6, minute: 0)), .noAck)])
        XCTAssertTrue(editor.isListStale)

        editor = try readyEditor(list: listSlot3)
        _ = try editor.add(hour: 6, minute: 0, now: t0)
        _ = editor.receive(hex("04 01"), now: t0 + 1)
        XCTAssertEqual(editor.tick(now: t0 + 6).events, [.writeUnverified(.set(ZeppAlarm(slot: 0, hour: 6, minute: 0)), .timedOut)])
        XCTAssertFalse(editor.canView)
    }

    func testMalformedListMeansNoViewAndNoWrites() throws {
        var editor = ZeppAlarmEditor(capabilities: ControlsFixtures.strapCapabilities())
        _ = try editor.read(now: t0)
        let r0 = hex("04 00 06 1e 1f 00 00 00 01 00")
        XCTAssertEqual(editor.receive([0x0a, 0x02] + r0 + r0, now: t0).events, [.listUnreadable(.duplicateSlot(0))])
        XCTAssertFalse(editor.canView)
        XCTAssertNil(editor.alarms)
        XCTAssertEqual(editor.freeSlots, [])
        editor.noteTimeSetReply([0x06, 0x01])
        XCTAssertThrowsError(try editor.add(hour: 6, minute: 0, now: t0)) { XCTAssertEqual($0 as? ZeppAlarmEditor.Error, .listNotRead) }
        // A later well-formed read recovers.
        _ = try editor.read(now: t0)
        _ = editor.receive(listG, now: t0)
        XCTAssertTrue(editor.canEdit)
    }
}
