// ZeppByteReader's bounds: every read past the end returns nil instead of trapping, including for a
// reader built with an offset past the end (#219 review N1: `take(0)` and `nulTerminatedString()`
// used to trap there).

import XCTest
@testable import ZeppKit

final class ByteReaderTests: XCTestCase {

    func testReaderBuiltPastTheEndIsAtTheEndAndNeverTraps() {
        var reader = ZeppByteReader([1, 2, 3], offset: 5)
        XCTAssertEqual(reader.offset, 3)
        XCTAssertEqual(reader.remaining, 0)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertNil(reader.u8())
        XCTAssertEqual(reader.take(0), [])
        XCTAssertNil(reader.take(1))
        XCTAssertNil(reader.nulTerminatedString())
        XCTAssertTrue(reader.skip(0))
        XCTAssertFalse(reader.skip(1))
    }

    func testOffsetsAreClampedAtBothEnds() {
        for offset in [Int.min, -1, 0] {
            var reader = ZeppByteReader([0x41, 0x00], offset: offset)
            XCTAssertEqual(reader.offset, 0)
            XCTAssertEqual(reader.nulTerminatedString(), "A")
        }
        for offset in [2, 3, Int.max] {
            var reader = ZeppByteReader([0x41, 0x00], offset: offset)
            XCTAssertEqual(reader.offset, 2)
            XCTAssertEqual(reader.take(0), [])
            XCTAssertNil(reader.nulTerminatedString())
        }
        var empty = ZeppByteReader([], offset: 1)
        XCTAssertEqual(empty.take(0), [])
        XCTAssertNil(empty.nulTerminatedString())
    }

    func testTakeZeroAndNulStringAtTheExactEnd() {
        var reader = ZeppByteReader([0x41, 0x00])
        XCTAssertEqual(reader.nulTerminatedString(), "A")
        XCTAssertEqual(reader.take(0), [])
        XCTAssertNil(reader.nulTerminatedString())
    }
}
