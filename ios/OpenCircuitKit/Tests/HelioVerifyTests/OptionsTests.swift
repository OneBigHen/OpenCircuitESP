// HelioVerify's write gating at option-parse time (adapted from the #221 review's options probe,
// which compiled a verbatim copy of `parseOptions`; the parser is now tested directly). Nothing here
// touches Bluetooth or a strap.

import XCTest
@testable import HelioVerify

final class OptionsTests: XCTestCase {

    private let key = ["--key-file", "/nonexistent/test.key"]

    private func accepted(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> Options? {
        do {
            return try parseOptions(args)
        } catch {
            XCTFail("rejected \(args): \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertRejected(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parseOptions(args), "accepted \(args)", file: file, line: line) { error in
            guard case OptionsError.invalid = error else {
                return XCTFail("\(args): \(error), not a usage error", file: file, line: line)
            }
        }
    }

    func testReadOnlyModesAreAcceptedAndNeverSetTheClock() {
        for extra in [[], ["--find"], ["--find", "60"], ["--vibrate"], ["--alerts"], ["--alarms"],
                      ["--find", "5", "--vibrate", "--alerts", "--alarms", "--trace"]] {
            let o = accepted(key + extra)
            XCTAssertEqual(o?.setTime, false, "\(extra)")
            XCTAssertEqual(o?.allowWrite, false, "\(extra)")
        }
    }

    func testAlarmWritesNeedAllowWriteAndSetTheClockFirst() {
        assertRejected(key + ["--set-alarm", "07:00"])
        assertRejected(key + ["--delete-alarm", "3"])
        assertRejected(key + ["--set-alarm", "07:00", "--alarms"])
        XCTAssertEqual(accepted(key + ["--set-alarm", "07:00", "--allow-write"])?.setTime, true)
        XCTAssertEqual(accepted(key + ["--delete-alarm", "3", "--allow-write"])?.setTime, true)
        assertRejected(key + ["--set-alarm", "07:00", "--delete-alarm", "3", "--allow-write"])
        assertRejected(["--set-alarm", "07:00", "--allow-write"])
        assertRejected(key + ["--allow-write"])
        assertRejected(key + ["--allow-write", "--alarms"])
    }

    func testSetTime() {
        XCTAssertEqual(accepted(key + ["--set-time"])?.setTime, true)
        XCTAssertEqual(accepted(key + ["--set-time", "--alarms"])?.setTime, true)
        XCTAssertEqual(accepted(key + ["--set-time", "--find"])?.setTime, true)
        assertRejected(key + ["--set-time", "--allow-write"])
    }

    func testArgumentValidation() {
        for extra in [["--find", "0"], ["--find", "61"], ["--find", "nan"], ["--find", "inf"],
                      ["--delete-alarm", "10", "--allow-write"], ["--delete-alarm", "-1", "--allow-write"],
                      ["--set-alarm", "24:00", "--allow-write"], ["--set-alarm", "7:5", "--allow-write"],
                      ["--set-alarm", "07:30,once,mon", "--allow-write"]] {
            assertRejected(key + extra)
        }
        XCTAssertEqual(accepted(key + ["--set-alarm", "07:30,", "--allow-write"])?.setTime, true)
        let alarm = accepted(key + ["--set-alarm", "07:30,mon+wed", "--allow-write"])?.setAlarm
        XCTAssertEqual(alarm?.hour, 7)
        XCTAssertEqual(alarm?.minute, 30)
    }

    func testHelpIsNotAUsageError() {
        XCTAssertThrowsError(try parseOptions(["--help"])) { XCTAssertEqual($0 as? OptionsError, .help) }
        XCTAssertThrowsError(try parseOptions(key + ["-h"])) { XCTAssertEqual($0 as? OptionsError, .help) }
    }
}
