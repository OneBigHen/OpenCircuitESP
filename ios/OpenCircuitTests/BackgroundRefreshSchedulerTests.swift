import BackgroundTasks
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

final class BackgroundRefreshSchedulerTests: XCTestCase {
    func testRequestUsesExpectedIdentifierAndFifteenMinuteEarliestBeginDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let scheduler = BackgroundRefreshScheduler(
            scheduler: RecordingScheduler(),
            now: { now },
            window: { _ in nil }   // no sleep window in sight → plain interval
        )

        let request = scheduler.makeRequest()

        XCTAssertEqual(request.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(
            request.earliestBeginDate?.timeIntervalSince1970,
            now.addingTimeInterval(15 * 60).timeIntervalSince1970
        )
    }

    func testScheduleSubmitsRefreshRequest() {
        let recording = RecordingScheduler()
        let now = Date(timeIntervalSince1970: 2_000)
        let scheduler = BackgroundRefreshScheduler(
            scheduler: recording,
            now: { now },
            window: { _ in nil }
        )

        scheduler.schedule()

        XCTAssertEqual(recording.cancelledIdentifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(recording.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(
            recording.submitted?.earliestBeginDate?.timeIntervalSince1970,
            now.addingTimeInterval(15 * 60).timeIntervalSince1970
        )
    }

    /// #233 item 5 (the strap only): a refresh aimed at a held night's margin end, never under a
    /// minute away. `schedule()`'s own aim is untouched (the tests above).
    func testAStrapRefreshAimedAtAMarginEndIsAtLeastAMinuteAway() {
        let recording = RecordingScheduler()
        let now = Date(timeIntervalSince1970: 3_000)
        let scheduler = BackgroundRefreshScheduler(scheduler: recording, now: { now }, window: { _ in nil })
        scheduler.scheduleRefresh(notBefore: now.addingTimeInterval(17 * 60))
        XCTAssertEqual(recording.cancelledIdentifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(recording.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertTrue(recording.submitted is BGAppRefreshTaskRequest)
        XCTAssertEqual(recording.submitted?.earliestBeginDate, now.addingTimeInterval(17 * 60))
        scheduler.scheduleRefresh(notBefore: now.addingTimeInterval(-600))
        XCTAssertEqual(recording.submitted?.earliestBeginDate, now.addingTimeInterval(60))
    }

    /// Review-225e SF-3: a strap night's margin refresh survives the app leaving the front, whose
    /// `schedule()` cancels and resubmits `bgrefresh`. With the ring chosen, the request stays exactly
    /// `schedule()`'s. A date that has passed, or a flush that wrote the night, ends it.
    func testAStrapMarginRefreshSurvivesTheBackgroundScheduleAndTheRingsRequestIsUnchanged() {
        let suite = "BackgroundRefreshSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 4_000)
        let margin = now.addingTimeInterval(17 * 60)

        // A foreground flush held a night: the refresh is aimed at the margin's end, and kept.
        let recording = RecordingScheduler()
        let scheduler = BackgroundRefreshScheduler(scheduler: recording, now: { now }, window: { _ in nil })
        StrapNightRefresh.record(margin, scheduler: scheduler, defaults: defaults)
        XCTAssertEqual(recording.submitted?.earliestBeginDate, margin)

        // The app leaves the front: `schedule()` replaces it, then the strap's margin request is back.
        scheduler.schedule()
        XCTAssertEqual(recording.submitted?.earliestBeginDate, now.addingTimeInterval(15 * 60), "schedule() replaced it")
        XCTAssertTrue(StrapNightRefresh.resubmit(scheduler, strapChosen: true, now: now, defaults: defaults))
        XCTAssertEqual(recording.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(recording.submitted?.earliestBeginDate, margin, "the margin request survives")

        // Ring chosen: the request is exactly schedule()'s.
        let ringRecording = RecordingScheduler()
        let ringScheduler = BackgroundRefreshScheduler(scheduler: ringRecording, now: { now }, window: { _ in nil })
        ringScheduler.schedule()
        let scheduled = ringRecording.submitted
        XCTAssertFalse(StrapNightRefresh.resubmit(ringScheduler, strapChosen: false, now: now, defaults: defaults))
        XCTAssertTrue(ringRecording.submitted === scheduled, "nothing submitted after schedule()")
        XCTAssertEqual(ringRecording.submitted?.earliestBeginDate, ringScheduler.makeRequest().earliestBeginDate)

        // Passed: cleared, nothing submitted.
        XCTAssertFalse(StrapNightRefresh.resubmit(scheduler, strapChosen: true, now: margin.addingTimeInterval(1), defaults: defaults))
        XCTAssertNil(StrapNightRefresh.pending(now: now, defaults: defaults), "cleared once passed")

        // A flush that wrote the night clears a pending one.
        StrapNightRefresh.record(margin, scheduler: scheduler, defaults: defaults)
        StrapNightRefresh.record(nil, scheduler: scheduler, defaults: defaults)
        XCTAssertNil(StrapNightRefresh.pending(now: now, defaults: defaults))
    }

    /// #119: a request submitted with the sleep window in progress (e.g. the scenePhase
    /// backgrounding as the user goes to bed) aims at windowEnd − lead, so iOS's discretionary
    /// grant lands on the one run that matters — the morning drain — not mid-night.
    func testRequestInsideSleepWindowAimsAtMorning() {
        let now = Date(timeIntervalSince1970: 100_000)
        let window = DateInterval(start: now.addingTimeInterval(-3_600),
                                  end: now.addingTimeInterval(7 * 3_600))
        let scheduler = BackgroundRefreshScheduler(
            scheduler: RecordingScheduler(),
            now: { now },
            window: { _ in window }
        )

        let request = scheduler.makeRequest()
        let processing = scheduler.makeProcessingRequest()

        let aimed = window.end.addingTimeInterval(-BackgroundSyncPolicy.morningLeadTime)
        XCTAssertEqual(request.earliestBeginDate?.timeIntervalSince1970, aimed.timeIntervalSince1970)
        XCTAssertEqual(processing.earliestBeginDate?.timeIntervalSince1970, aimed.timeIntervalSince1970)
    }
}

private final class RecordingScheduler: BGTaskScheduling {
    private(set) var cancelledIdentifier: String?
    private(set) var submitted: BGTaskRequest?

    func register(forTaskWithIdentifier identifier: String,
                  using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool {
        true
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        cancelledIdentifier = identifier
    }

    func submit(_ taskRequest: BGTaskRequest) throws {
        submitted = taskRequest
    }
}
