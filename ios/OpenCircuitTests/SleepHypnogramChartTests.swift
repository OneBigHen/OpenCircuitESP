import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// The shared hypnogram's pure helpers: which segment a touch reads out, and where the step lines go.
// Every time is synthetic.

@MainActor
final class SleepHypnogramChartTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func seg(_ from: Double, _ to: Double, _ stage: SleepStage) -> SleepSegment {
        SleepSegment(start: at(from), end: at(to), stage: stage)
    }

    func testPlottedDropsInBedAndEmptySegmentsAndSortsByTime() {
        let plotted = SleepHypnogramChart.plotted([
            seg(30, 60, .asleepDeep), seg(0, 90, .inBed), seg(0, 30, .asleepCore), seg(60, 60, .awake),
        ])
        XCTAssertEqual(plotted.map(\.stage), [.asleepCore, .asleepDeep])
    }

    func testATouchReadsTheSegmentUnderItAndABoundaryBelongsToTheNextOne() {
        let plotted = SleepHypnogramChart.plotted([seg(0, 30, .asleepCore), seg(30, 50, .asleepREM)])
        XCTAssertEqual(SleepHypnogramChart.segment(at: at(10), in: plotted)?.stage, .asleepCore)
        XCTAssertEqual(SleepHypnogramChart.segment(at: at(30), in: plotted)?.stage, .asleepREM)
        XCTAssertNil(SleepHypnogramChart.segment(at: at(50), in: plotted), "past the night: nothing")
        XCTAssertNil(SleepHypnogramChart.segment(at: at(-1), in: plotted), "before the night: nothing")
    }

    func testStepLinesJoinOnlyTouchingSegmentsOfDifferentStages() {
        let plotted = SleepHypnogramChart.plotted([
            seg(0, 30, .asleepCore), seg(30, 40, .asleepCore),   // same stage: no line
            seg(42, 60, .asleepDeep),                             // 2 min apart: joined
            seg(120, 150, .awake),                                // an hour apart: not joined
        ])
        let steps = SleepHypnogramChart.transitions(plotted)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.time, at(42))
        XCTAssertEqual(steps.first?.from, .light)
        XCTAssertEqual(steps.first?.to, .deep)
    }

    func testTheReadoutSpanGivesHoursOnlyPastAnHour() {
        XCTAssertTrue(SleepHypnogramChart.span(seg(0, 37, .asleepREM)).hasSuffix("· 37m"))
        XCTAssertTrue(SleepHypnogramChart.span(seg(0, 95, .asleepCore)).hasSuffix("· 1h 35m"))
    }

    func testATapPicksABlockATapOnItAgainOrOnNothingClears() {
        let plotted = SleepHypnogramChart.plotted([seg(0, 30, .asleepCore), seg(30, 50, .asleepREM)])
        let first = SleepHypnogramChart.nextSelection(tapped: at(10), current: nil, in: plotted)
        XCTAssertEqual(first, at(10), "a tap on a block picks it")
        XCTAssertEqual(SleepHypnogramChart.nextSelection(tapped: at(40), current: first, in: plotted), at(40),
                       "a tap on another block moves the pick")
        XCTAssertNil(SleepHypnogramChart.nextSelection(tapped: at(20), current: first, in: plotted),
                     "a second tap on the same block clears it")
        XCTAssertNil(SleepHypnogramChart.nextSelection(tapped: at(90), current: first, in: plotted),
                     "a tap off every block clears it")
    }
}
