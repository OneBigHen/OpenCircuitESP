import XCTest
@testable import OpenCircuitKit

final class WorkoutLiveMetricsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_789_862_400)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testAveragePaceNeedsRealDistanceAndTime() {
        XCTAssertNil(WorkoutPace.averageSecPerKm(distanceMeters: nil, activeSeconds: 600))
        XCTAssertNil(WorkoutPace.averageSecPerKm(distanceMeters: 20, activeSeconds: 600))
        XCTAssertNil(WorkoutPace.averageSecPerKm(distanceMeters: 500, activeSeconds: 5))
        XCTAssertEqual(WorkoutPace.averageSecPerKm(distanceMeters: 2000, activeSeconds: 600) ?? 0, 300, accuracy: 0.001)
    }

    func testAveragePaceSlowerThanAnHourPerKmIsNotAPace() {
        XCTAssertNil(WorkoutPace.averageSecPerKm(distanceMeters: 60, activeSeconds: 600))
    }

    func testCurrentPaceUsesTheLastThirtySeconds() {
        let fixes = (0...10).map { WorkoutDistanceFix(at: at(Double($0) * 5), cumulativeMeters: Double($0) * 15) }
        // 3 m/s => 333.3 s/km, over the window ending at 50 s.
        let pace = WorkoutPace.currentSecPerKm(fixes: fixes, now: at(52))
        XCTAssertEqual(pace ?? 0, 1000.0 / 3, accuracy: 0.01)
    }

    func testCurrentPaceIsNilWhenFixesWentStale() {
        let fixes = [WorkoutDistanceFix(at: at(0), cumulativeMeters: 0), WorkoutDistanceFix(at: at(10), cumulativeMeters: 40)]
        XCTAssertNotNil(WorkoutPace.currentSecPerKm(fixes: fixes, now: at(20)))
        XCTAssertNil(WorkoutPace.currentSecPerKm(fixes: fixes, now: at(60)))
    }

    func testCurrentPaceIsNilWithTooLittleMovementOrOneFix() {
        XCTAssertNil(WorkoutPace.currentSecPerKm(fixes: [], now: at(0)))
        XCTAssertNil(WorkoutPace.currentSecPerKm(fixes: [WorkoutDistanceFix(at: at(0), cumulativeMeters: 0)], now: at(1)))
        let still = [WorkoutDistanceFix(at: at(0), cumulativeMeters: 0), WorkoutDistanceFix(at: at(20), cumulativeMeters: 5)]
        XCTAssertNil(WorkoutPace.currentSecPerKm(fixes: still, now: at(21)))
    }

    func testLiveZoneIsNeverGivenForAStaleOrMissingReading() {
        XCTAssertNil(WorkoutPace.liveZone(bpm: nil, isStale: false, maxHR: 190))
        XCTAssertNil(WorkoutPace.liveZone(bpm: 150, isStale: true, maxHR: 190))
        XCTAssertNil(WorkoutPace.liveZone(bpm: 80, isStale: false, maxHR: 190))
        XCTAssertEqual(WorkoutPace.liveZone(bpm: 160, isStale: false, maxHR: 190), 4)
    }

    func testCallPausesARunningWorkoutAndAsksAfterwards() {
        var call = WorkoutCallPause()
        XCTAssertTrue(call.callConnected(workoutRunning: true, workoutPaused: false))
        XCTAssertFalse(call.callConnected(workoutRunning: true, workoutPaused: true), "a second call changes nothing")
        XCTAssertTrue(call.allCallsEnded(workoutRunning: true, workoutPaused: true))
        XCTAssertTrue(call.resumePromptPending)
        call.clear()
        XCTAssertFalse(call.resumePromptPending)
        XCTAssertFalse(call.pausedForCall)
    }

    func testAWorkoutThePersonAlreadyPausedIsLeftAloneAndNeverPrompted() {
        var call = WorkoutCallPause()
        XCTAssertFalse(call.callConnected(workoutRunning: true, workoutPaused: true))
        XCTAssertFalse(call.allCallsEnded(workoutRunning: true, workoutPaused: true))
    }

    func testNoWorkoutNoPause() {
        var call = WorkoutCallPause()
        XCTAssertFalse(call.callConnected(workoutRunning: false, workoutPaused: false))
    }

    func testNoPromptIfThePersonResumedDuringTheCallOrTheWorkoutEnded() {
        var call = WorkoutCallPause()
        _ = call.callConnected(workoutRunning: true, workoutPaused: false)
        XCTAssertFalse(call.allCallsEnded(workoutRunning: true, workoutPaused: false), "resumed mid-call")
        XCTAssertFalse(call.pausedForCall)
        _ = call.callConnected(workoutRunning: true, workoutPaused: false)
        XCTAssertFalse(call.allCallsEnded(workoutRunning: false, workoutPaused: false), "ended mid-call")
    }
}

final class WorkoutPaceTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_789_862_400)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testOnlyMovementIsKeptSoPaceAgesOutWhenFixesStop() {
        var tracker = WorkoutPaceTracker()
        for s in stride(from: 0.0, through: 20, by: 5) { tracker.observe(distanceMeters: s * 3, at: at(s)) }
        XCTAssertNotNil(tracker.currentSecPerKm(now: at(21)))
        for s in stride(from: 25.0, through: 60, by: 5) { tracker.observe(distanceMeters: 60, at: at(s)) }   // no new fixes
        XCTAssertNil(tracker.currentSecPerKm(now: at(60)))
    }

    func testResetStartsANewLeg() {
        var tracker = WorkoutPaceTracker()
        tracker.observe(distanceMeters: 0, at: at(0)); tracker.observe(distanceMeters: 40, at: at(10))
        tracker.reset()
        XCTAssertNil(tracker.currentSecPerKm(now: at(11)))
        tracker.observe(distanceMeters: nil, at: at(12))
        XCTAssertTrue(tracker.fixes.isEmpty)
    }
}
