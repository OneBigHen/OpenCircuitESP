import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Review-224 S4 (#215): with the Helio Strap chosen the bedtime reminder still runs (it is the
/// wearer's own schedule); the sedentary and wear reminders, which judge the ring's own signals, do
/// not. Each case also checks the ring still gets the reminder, so the strap's silence is the gate
/// and not a setup that fires nothing. All values are synthetic.
@MainActor
final class StrapReminderTests: XCTestCase {
    private let suite = "test.StrapReminderTests"
    private var defaults: UserDefaults!
    private let bed = 20 * 60, wake = 6 * 60
    private var now: Date {
        Calendar.current.date(bySettingHour: 19, minute: 45, second: 0, of: Date(timeIntervalSince1970: 1_789_862_400))!
    }

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        defaults.set(true, forKey: ReminderDefaults.sedentaryEnabled)
        defaults.set(50, forKey: ReminderDefaults.sedentaryIntervalMin)
        defaults.set(true, forKey: ReminderDefaults.wearEnabled)
        defaults.set(true, forKey: ReminderDefaults.bedtimeEnabled)
        defaults.set(30, forKey: ReminderDefaults.bedtimeMinutesBefore)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func candidates(ring: Bool) -> [HealthNotification] {
        HealthNotificationCenter.reminderCandidates(session: nil, sleepBedMinutes: bed, sleepWakeMinutes: wake,
                                                    sleepEnabled: true, includeSedentary: true, ringReminders: ring,
                                                    store: nil, now: now, defaults: defaults)
    }

    func testWithTheStrapChosenASedentaryStretchFiresOnlyTheBedtimeReminder() {
        // Three hours without steps while the ring was heard from five minutes ago.
        defaults.set(now.addingTimeInterval(-3 * 3600).timeIntervalSince1970, forKey: ReminderDefaults.lastActivityAt)
        defaults.set(now.addingTimeInterval(-5 * 60).timeIntervalSince1970, forKey: ReminderDefaults.lastRingDataAt)
        let ring = candidates(ring: true)
        XCTAssertTrue(ring.contains(.sedentaryReminder))
        XCTAssertTrue(ring.contains(.bedtimeReminder))
        XCTAssertEqual(candidates(ring: false), [.bedtimeReminder])
    }

    func testWithTheStrapChosenASilentRingFiresOnlyTheBedtimeReminder() {
        // A ring paired once and silent for three hours.
        defaults.set(["5B1E4C2A-0000-4000-8000-00000000A0B1"], forKey: "com.opencircuit.ring.peripheralIDs")
        defaults.set(now.addingTimeInterval(-3 * 3600).timeIntervalSince1970, forKey: ReminderDefaults.lastRingDataAt)
        let ring = candidates(ring: true)
        XCTAssertTrue(ring.contains(.wearReminder))
        XCTAssertTrue(ring.contains(.bedtimeReminder))
        XCTAssertEqual(candidates(ring: false), [.bedtimeReminder])
    }

    /// Review-224b F-1: a strap sync ends by evaluating reminders, as the ring's post-sync hook does,
    /// and that pass (no ring signals, sedentary deferred) yields the bedtime reminder in its window.
    func testAStrapSyncEvaluatesTheBedtimeReminder() {
        XCTAssertTrue(HelioSyncEndStep.allCases.contains(.evaluateReminders))
        let pass = HealthNotificationCenter.reminderCandidates(session: nil, sleepBedMinutes: bed, sleepWakeMinutes: wake,
                                                               sleepEnabled: true, includeSedentary: false,
                                                               ringReminders: false, store: nil, now: now, defaults: defaults)
        XCTAssertEqual(pass, [.bedtimeReminder])
    }

    /// Review-224c N-b: the hook runs every step, in order, and fires once per sync.
    func testTheSyncEndHookRunsEveryStepOncePerSync() {
        var ran: [HelioSyncEndStep] = []
        HelioSyncEndStep.runAll { ran.append($0) }
        XCTAssertEqual(ran, HelioSyncEndStep.allCases)
        XCTAssertEqual(ran.filter { $0 == .evaluateReminders }.count, 1)

        // `syncing` as the session reports it: two syncs, the second ended by a link drop (→ nil).
        let observed: [Bool?] = [nil, false, true, true, false, false, true, nil, nil]
        let ends = zip(observed, observed.dropFirst()).filter { HelioSyncEndStep.syncEnded(from: $0, to: $1) }.count
        XCTAssertEqual(ends, 2, "one run per sync, however many times `syncing` is re-published")
    }
}
