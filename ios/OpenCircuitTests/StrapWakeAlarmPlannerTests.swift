import AppIntents
import XCTest
import ZeppKit
@testable import OpenCircuit

/// Shortcuts' wake alarm (#260, decision 52b, 52c): the pure planner's rules, the managed-slot mark,
/// the per-device descriptor fields (decision 51e) and the one Shortcuts provider. Every strap id and
/// alarm here is made up.
@MainActor
final class StrapWakeAlarmPlannerTests: XCTestCase {
    private let strapA = "5B1E4C2A-0000-4000-8000-0000000000E1"
    private let strapB = "5B1E4C2A-0000-4000-8000-0000000000E2"

    private func alarm(_ slot: UInt8, _ hour: UInt8, _ minute: UInt8, _ days: ZeppAlarmDays = .once,
                       on: Bool = true, smartWake: Bool = false) -> ZeppAlarm {
        ZeppAlarm(slot: slot, hour: hour, minute: minute, days: days, isEnabled: on, smartWake: smartWake)
    }

    private func record(_ alarm: ZeppAlarm, strap: String? = nil) -> ManagedStrapAlarm {
        ManagedStrapAlarm(strapID: strap ?? strapA, alarm: alarm)
    }

    private func set(_ hour: UInt8, _ minute: UInt8, _ days: ZeppAlarmDays = .once) -> StrapWakeAlarmRequest.Kind {
        .set(StrapWakeAlarmTime(hour: hour, minute: minute, days: days))
    }

    private func plan(_ alarms: [ZeppAlarm], _ record: ManagedStrapAlarm?, _ request: StrapWakeAlarmRequest.Kind,
                      strap: String? = nil) -> StrapWakeAlarmPlanner.Plan {
        StrapWakeAlarmPlanner.plan(alarms: alarms, strapID: strap ?? strapA, record: record, request: request)
    }

    // MARK: set

    func testTheSameSettingAlreadyOnTheStrapWritesNothing() {
        // The person's own 07:00 in slot 4: nothing is added beside it, and it doesn't become ours.
        let mine = alarm(4, 7, 0)
        XCTAssertEqual(plan([mine], nil, set(7, 0)), .init(action: .none(.alreadySet), forgetRecord: false))
        // The managed slot already holding it: the same.
        let ours = alarm(2, 6, 30, .weekdays)
        XCTAssertEqual(plan([ours, mine], record(ours), set(6, 30, .weekdays)),
                       .init(action: .none(.alreadySet), forgetRecord: false))
    }

    func testANewTimeReplacesTheManagedSlotWhileItStillMatches() {
        let ours = alarm(2, 6, 30)
        let other = alarm(0, 9, 15, .weekend, on: false)
        XCTAssertEqual(plan([other, ours], record(ours), set(7, 45, .everyDay)),
                       .init(action: .replace(alarm(2, 7, 45, .everyDay)), forgetRecord: false))
    }

    func testAManagedSlotTheUserEditedIsForgottenAndANewOneAdded() {
        let written = alarm(2, 6, 30)
        let edited = alarm(2, 8, 0)   // changed on the Alarms screen or in Zepp
        XCTAssertEqual(plan([edited], record(written), set(7, 0)),
                       .init(action: .add(StrapWakeAlarmTime(hour: 7, minute: 0, days: .once)), forgetRecord: true))
        // A repeating alarm the person turned off is an edit too.
        let daily = alarm(3, 6, 0, .everyDay)
        let turnedOff = alarm(3, 6, 0, .everyDay, on: false)
        XCTAssertEqual(plan([turnedOff], record(daily), set(6, 0, .everyDay)),
                       .init(action: .add(StrapWakeAlarmTime(hour: 6, minute: 0, days: .everyDay)), forgetRecord: true))
    }

    func testAManagedSlotThatIsGoneIsForgottenAndANewOneAdded() {
        let written = alarm(2, 6, 30)
        XCTAssertEqual(plan([alarm(0, 9, 0)], record(written), set(6, 30)),
                       .init(action: .add(StrapWakeAlarmTime(hour: 6, minute: 30, days: .once)), forgetRecord: true))
    }

    func testNoFreeSlotRefuses() {
        let full = (0..<UInt8(10)).map { alarm($0, 5, $0) }
        XCTAssertEqual(plan(full, nil, set(7, 0)), .init(action: .refuse(.noFreeSlot), forgetRecord: false))
        // The managed slot was edited and every other slot is taken: forgotten, then refused.
        var edited = full
        edited[4] = alarm(4, 11, 11)
        XCTAssertEqual(plan(edited, record(alarm(4, 5, 4)), set(7, 0)),
                       .init(action: .refuse(.noFreeSlot), forgetRecord: true))
    }

    func testAOnceAlarmTheStrapDisabledAfterItFiredIsReEnabled() {
        // §13.5 🔴: what the strap does with a fired once-alarm is unknown; disabling it is one answer.
        let written = alarm(1, 6, 30)
        let fired = alarm(1, 6, 30, on: false)
        XCTAssertEqual(plan([fired], record(written), set(6, 30)),
                       .init(action: .replace(alarm(1, 6, 30)), forgetRecord: false), "same time: enabled again")
        XCTAssertEqual(plan([fired], record(written), set(7, 10, .weekdays)),
                       .init(action: .replace(alarm(1, 7, 10, .weekdays)), forgetRecord: false))
    }

    func testARecordForAnotherStrapIsNoRecord() {
        // Strap B happens to hold, in the same slot, exactly what was written to strap A.
        let onA = alarm(2, 6, 30)
        let p = plan([alarm(2, 6, 30, .once)], record(onA, strap: strapA), set(7, 0), strap: strapB)
        XCTAssertEqual(p, .init(action: .add(StrapWakeAlarmTime(hour: 7, minute: 0, days: .once)), forgetRecord: false),
                       "never replaced, and strap A's record is kept for strap A")
        XCTAssertEqual(plan([alarm(2, 6, 30)], record(onA, strap: strapA), .clear, strap: strapB),
                       .init(action: .none(.nothingToClear), forgetRecord: false))
    }

    // MARK: clear

    func testClearDeletesOnlyAManagedSlotThatStillMatches() {
        let ours = alarm(2, 6, 30)
        let mine = alarm(5, 6, 30)
        XCTAssertEqual(plan([ours, mine], record(ours), .clear), .init(action: .delete(slot: 2), forgetRecord: false))
        XCTAssertEqual(plan([alarm(2, 6, 30, on: false), mine], record(ours), .clear),
                       .init(action: .delete(slot: 2), forgetRecord: false), "the fired once-alarm is still ours")
        XCTAssertEqual(plan([alarm(2, 8, 0), mine], record(ours), .clear),
                       .init(action: .none(.changedOnStrap), forgetRecord: true), "edited: left as it is")
        XCTAssertEqual(plan([mine], record(ours), .clear),
                       .init(action: .none(.changedOnStrap), forgetRecord: true), "gone")
        XCTAssertEqual(plan([mine], nil, .clear), .init(action: .none(.nothingToClear), forgetRecord: false),
                       "the person's identical alarm in another slot is never deleted")
    }

    // MARK: no other slot, ever

    func testNoPlanEverNamesASlotOtherThanTheManagedOne() {
        var rng = SeededGenerator(seed: 260)
        let requests: [StrapWakeAlarmRequest.Kind] = [set(6, 30), set(7, 0, .weekdays), set(6, 30, .everyDay), .clear]
        for _ in 0..<2_000 {
            // A random list of the strap's alarms over a few times, some of them equal to the request.
            var alarms: [ZeppAlarm] = []
            for slot in 0..<UInt8(10) where Int.random(in: 0..<3, using: &rng) != 0 {
                let hour: UInt8 = [6, 7, 8].randomElement(using: &rng)!
                let minute: UInt8 = [0, 30].randomElement(using: &rng)!
                let days: ZeppAlarmDays = [.once, .weekdays, .everyDay].randomElement(using: &rng)!
                alarms.append(alarm(slot, hour, minute, days, on: Bool.random(using: &rng),
                                    smartWake: Int.random(in: 0..<8, using: &rng) == 0))
            }
            let recordSlot = UInt8.random(in: 0..<10, using: &rng)
            let written = alarm(recordSlot, [6, 7].randomElement(using: &rng)!, [0, 30].randomElement(using: &rng)!,
                                [.once, .weekdays].randomElement(using: &rng)!)
            let strap = Bool.random(using: &rng) ? strapA : strapB
            let rec: ManagedStrapAlarm? = Int.random(in: 0..<4, using: &rng) == 0 ? nil : record(written, strap: strap)
            for request in requests {
                let p = plan(alarms, rec, request)
                let ownsSlot: Bool = {
                    guard let rec, rec.strapID == strapA, let onStrap = alarms.first(where: { $0.slot == rec.slot }) else { return false }
                    if onStrap.hasSameSetting(as: rec.alarm) { return true }
                    var reEnabled = onStrap
                    reEnabled.isEnabled = true
                    return rec.alarm.days == .once && rec.isEnabled && !onStrap.isEnabled && reEnabled.hasSameSetting(as: rec.alarm)
                }()
                switch p.action {
                case .replace(let target):
                    XCTAssertTrue(ownsSlot, "replace only the managed slot while it matches")
                    XCTAssertEqual(target.slot, rec?.slot)
                    XCTAssertFalse(target.smartWake)
                case .delete(let slot):
                    XCTAssertTrue(ownsSlot, "delete only the managed slot while it matches")
                    XCTAssertEqual(slot, rec?.slot)
                case .add:
                    XCTAssertFalse(alarms.count == 10, "an add needs a free slot")
                case .none, .refuse:
                    break
                }
                if p.forgetRecord { XCTAssertFalse(ownsSlot) }
            }
        }
    }

    // MARK: the Alarms screen's mark

    func testTheManagedSlotIsMarkedOnlyWhileItIsStillOurs() throws {
        let suite = "test.StrapWakeAlarmPlannerTests.mark"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StrapWakeAlarmStore(defaults: defaults)
        XCTAssertNil(store.managedSlot(strapID: strapA, alarms: [alarm(2, 6, 30)]))
        store.managed = record(alarm(2, 6, 30))
        XCTAssertEqual(store.managedSlot(strapID: strapA, alarms: [alarm(0, 6, 30), alarm(2, 6, 30)]), 2)
        XCTAssertEqual(store.managedSlot(strapID: strapA, alarms: [alarm(2, 6, 30, on: false)]), 2, "fired once")
        XCTAssertNil(store.managedSlot(strapID: strapA, alarms: [alarm(2, 6, 45)]), "edited")
        XCTAssertNil(store.managedSlot(strapID: strapB, alarms: [alarm(2, 6, 30)]), "another strap")
        // The state round-trips through its versioned key.
        let pending = StrapWakeAlarmRequest(.clear, madeAt: Date(timeIntervalSince1970: 1_789_900_000))
        store.pending = pending
        XCTAssertEqual(StrapWakeAlarmStore(defaults: defaults).state,
                       .init(managed: record(alarm(2, 6, 30)), pending: pending))
        XCTAssertNotNil(defaults.data(forKey: "helio.shortcutWakeAlarm.v1"))
    }

    // MARK: the descriptor (decision 51e)

    func testEachDeviceSaysWhetherItVibratesOnDemand() {
        for device in ActiveDeviceChoice.allCases {
            switch device {
            case .ringConn: XCTAssertEqual(device.onDemandVibration, .someModels(only: "the RingConn Gen 3"))
            case .helioStrap: XCTAssertEqual(device.onDemandVibration, .supported)
            }
        }
    }

    func testEachDeviceSaysWhetherItStoresAlarms() {
        for device in ActiveDeviceChoice.allCases {
            switch device {
            case .ringConn:
                XCTAssertEqual(device.wakeAlarm, .notStored(alternative: "A Gen 3 ring has OpenCircuit's own wake-up "
                    + "alarm instead: Profile ▸ Device Info ▸ Vibration & alarm."))
                XCTAssertFalse(device.wakeAlarm.isStoredOnDevice)
            case .helioStrap:
                XCTAssertEqual(device.wakeAlarm, .storedOnDevice)
                XCTAssertTrue(device.wakeAlarm.isStoredOnDevice)
            }
        }
    }

    // MARK: the one provider

    func testTheProviderStillListsTheThreeExistingShortcutsAndAddsTheThreeNewOnes() {
        let shortcuts = OpenCircuitAppShortcuts.appShortcuts
        XCTAssertEqual(shortcuts.count, 6)
        let described = shortcuts.map { Self.describe($0) }
        let expected = ["LogHeadacheIntent", "LogHeadacheYesterdayIntent", "ExportRingDataIntent",
                        "VibrateWearableIntent", "SetWakeAlarmOnWearableIntent", "ClearWakeAlarmOnWearableIntent"]
        for (index, name) in expected.enumerated() {
            XCTAssertTrue(described[index].contains(name), "shortcut \(index) is \(name)")
        }
    }

    func testTheActionsRunInTheBackgroundAndOnALockedPhone() {
        XCTAssertFalse(VibrateWearableIntent.openAppWhenRun)
        XCTAssertFalse(SetWakeAlarmOnWearableIntent.openAppWhenRun)
        XCTAssertFalse(ClearWakeAlarmOnWearableIntent.openAppWhenRun)
        XCTAssertEqual(WakeAlarmRepeatChoice.once.days, .once)
        XCTAssertEqual(WakeAlarmRepeatChoice.everyDay.days, .everyDay)
        XCTAssertEqual(WakeAlarmRepeatChoice.weekdays.days, .weekdays)
        XCTAssertEqual(WakeAlarmRepeatChoice.weekends.days, .weekend)
    }

    /// The intent type inside an `AppShortcut`, read by reflection (it has no public accessor).
    private static func describe(_ value: Any, depth: Int = 0) -> String {
        guard depth < 4 else { return "" }
        let mirror = Mirror(reflecting: value)
        var parts = [String(describing: type(of: value))]
        for child in mirror.children { parts.append(describe(child.value, depth: depth + 1)) }
        return parts.joined(separator: " ")
    }
}

/// A small deterministic generator (SplitMix64), so the property test is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
