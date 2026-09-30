import XCTest
@testable import OpenCircuit

/// The live readout's "low–high so far" (review #220 N1). Synthetic readings only.
final class LiveSessionRangeTests: XCTestCase {

    /// A long measurement: the chart buffer trims to its last 120 readings, but "so far" must still
    /// include the low from the start of the session.
    func testTheRangeCoversTheWholeSessionNotJustTheChartBuffer() {
        var buffer = LiveBuffer()
        var range = LiveSessionRange()
        let readings: [Double] = [48] + (0..<199).map { 60 + Double($0 % 7) }   // 200 readings, low first
        for (i, v) in readings.enumerated() {
            buffer.append(value: v, at: Double(i))
            range.include(v)
        }
        XCTAssertEqual(buffer.points.count, buffer.capacity)
        XCTAssertEqual(buffer.points.map(\.value).min(), 60, "the buffer has dropped the session's low")
        XCTAssertEqual(range.range, 48...66)
        XCTAssertEqual(range.count, 200)
    }

    func testOneReadingHasNoRangeAndResetStartsOver() {
        var range = LiveSessionRange()
        XCTAssertNil(range.range)
        range.include(97)
        XCTAssertNil(range.range, "one reading spans nothing")
        range.include(95)
        XCTAssertEqual(range.range, 95...97)
        range.include(.nan)
        XCTAssertEqual(range.count, 2, "a non-finite reading is ignored")
        range.reset()
        XCTAssertNil(range.range)
        XCTAssertEqual(range, LiveSessionRange())
    }
}
