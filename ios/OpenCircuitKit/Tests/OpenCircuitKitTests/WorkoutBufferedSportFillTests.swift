import XCTest
@testable import OpenCircuitKit

/// A manual workout's live-HR gaps are filled from the ring's own buffered `0x4d` records, never
/// double-counted, and the workout's window suppresses auto-detection (tester report 2026-09-27).
/// The frame is the already-committed fixture from `AutomaticWorkoutDetectionTests` — 9 records,
/// 10 s apart, HR 85–89.
final class WorkoutBufferedSportFillTests: XCTestCase {

    private let frameHex = "4d 00 12 0c 47 47 fb 57 00 03 6a c7 08 00 0c 47 48 05 59 00 02 1e c7 09 00 0c 47 48 0f 58 00 03 1d c7 06 00 0c 47 48 19 55 00 00 79 c6 04 00 0c 47 48 23 58 00 02 55 bf 04 00 0c 47 48 2d 55 00 01 07 bf 03 00 0c 47 48 37 59 00 01 c4 c7 05 00 0c 47 48 41 59 00 02 9d c7 00 00 0c 47 48 4b 58 00 02 b7 c7 00 00 b5"

    private func records() throws -> [HistoricalSportFrame.Sample] {
        let bytes = frameHex.split(separator: " ").map { UInt8($0, radix: 16)! }
        return try XCTUnwrap(HistoricalSportFrame.decode(bytes))
    }

    private func window(_ r: [HistoricalSportFrame.Sample], pad: TimeInterval = 60) -> DateInterval {
        DateInterval(start: r.first!.endDate.addingTimeInterval(-10 - pad), end: r.last!.endDate.addingTimeInterval(pad))
    }

    /// The phone was away the whole time: every buffered record becomes a workout HR sample.
    func testNoLiveDataUsesEveryBufferedRecord() throws {
        let r = try records()
        let fill = WorkoutBufferedSportFill.fill(captured: [], buffered: r, window: window(r))
        XCTAssertEqual(fill.hrSamples.count, r.count)
        XCTAssertEqual(fill.hrSamples.map(\.bpm), r.compactMap(\.heartRate))
        XCTAssertEqual(fill.hrSamples.first?.end.timeIntervalSince(fill.hrSamples.first!.start), 10)
        XCTAssertEqual(fill.cursors.count, r.count)
    }

    /// Live data covering a record's interval wins — no double count.
    func testLiveCoverageWins() throws {
        let r = try records()
        let live = HRSample(bpm: 140, start: r[3].endDate.addingTimeInterval(-6), end: r[3].endDate.addingTimeInterval(-4))
        let fill = WorkoutBufferedSportFill.fill(captured: [live], buffered: r, window: window(r))
        XCTAssertEqual(fill.hrSamples.count, r.count - 1)
        XCTAssertFalse(fill.cursors.contains(r[3].cursor))
    }

    /// Review 2026-09-28: live `0x4e` frames that produced NO HR sample (warm-up, dropout, frames the
    /// 2-s poll missed) still had their steps summed live — their buffered records must be skipped
    /// entirely, or those steps count twice. Coverage is by the ring's own cursor, any phase offset.
    func testLiveFramesWithoutHRStillCoverTheirRecords() throws {
        let r = try records()
        for phase: UInt32 in [0, 3, 9] {                          // 0x4e cursor offset within the 10 s
            let liveCursors = Set(r[2...5].map { $0.cursor - phase })
            let fill = WorkoutBufferedSportFill.fill(captured: [], buffered: r, window: window(r),
                                                     liveFrameCursors: liveCursors)
            XCTAssertEqual(fill.cursors.count, r.count - 4, "phase \(phase)")
            for i in 2...5 { XCTAssertFalse(fill.cursors.contains(r[i].cursor), "phase \(phase) record \(i)") }
        }
        // A frame just outside a record's interval does not cover it.
        let outside = WorkoutBufferedSportFill.fill(captured: [], buffered: r, window: window(r),
                                                    liveFrameCursors: [r[4].cursor + 1])
        XCTAssertTrue(outside.cursors.contains(r[4].cursor))
    }

    /// Records outside the workout window never enter it; a second merge adds nothing new.
    func testWindowAndIdempotence() throws {
        let r = try records()
        let half = DateInterval(start: r[0].endDate.addingTimeInterval(-10), end: r[4].endDate)
        let first = WorkoutBufferedSportFill.fill(captured: [], buffered: r, window: half)
        XCTAssertEqual(first.hrSamples.count, 5)
        let again = WorkoutBufferedSportFill.fill(captured: [], buffered: r, window: half, alreadyMerged: first.cursors)
        XCTAssertTrue(again.hrSamples.isEmpty)
        XCTAssertEqual(again.steps, 0)
    }

    /// #283 B2: `stepRecords` must carry every record `steps` counts, each with its own end time, so
    /// a caller can filter it by time (a workout pause) the same way it already filters `hrSamples` —
    /// `steps` alone is a pre-summed scalar with no way to exclude part of the window.
    func testStepRecordsMatchTheScalarTotalAndEachRecordsOwnEnd() throws {
        let r = try records()
        let fill = WorkoutBufferedSportFill.fill(captured: [], buffered: r, window: window(r))
        XCTAssertEqual(fill.stepRecords.count, fill.hrSamples.count,
                       "every HR-bearing record in this fixture also has steps")
        XCTAssertEqual(fill.stepRecords.reduce(0) { $0 + $1.steps }, fill.steps,
                       "stepRecords must sum to exactly the scalar total")
        XCTAssertEqual(fill.stepRecords.map(\.end), r.map(\.endDate),
                       "each record's own end, in the same order fill() walks them")

        // Filtering stepRecords down to a sub-window must exclude exactly those records' steps.
        let excludedEnd = r[3].endDate
        let filtered = fill.stepRecords.filter { $0.end != excludedEnd }
        XCTAssertEqual(filtered.reduce(0) { $0 + $1.steps }, fill.steps - r[3].steps)
    }

    /// The manual workout's window overlaps every candidate built from its own records, so
    /// resolving it suppresses the "detected walk".
    func testWorkoutWindowSpanCoversItsOwnRecords() throws {
        let r = try records()
        let span = CursorSpan(window: window(r, pad: 0))
        for rec in r { XCTAssertTrue(span.overlaps(CursorSpan(point: rec.cursor))) }
        XCTAssertFalse(span.overlaps(CursorSpan(point: r.last!.cursor + 3600)))
    }
}
