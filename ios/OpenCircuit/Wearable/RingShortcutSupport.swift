import Foundation
import OpenCircuitKit
import ZeppKit

// The RingConn Gen 3 behind the Shortcuts actions (#260, decision 52g). Two seams, so the tests drive
// the ring path without CoreBluetooth (a `RingSession` needs a real `CBPeripheral`), and the record of
// what Shortcuts last set on the ring's wake-up alarm, so Clear can tell it is still Shortcuts' alarm.
// Nothing here changes `RingSession`'s guards: a buzz still goes through `vibrate(_:)`, which refuses
// while the ring syncs, measures, records a workout or charges.

/// The ring's session as Vibrate Wearable uses it. `RingSession` in the app.
@MainActor
protocol ShortcutRingSession: AnyObject {
    /// The link is up and the ring answered its first exchange.
    var ready: Bool { get }
    /// This connection's DIS read named a generation.
    var generationKnown: Bool { get }
    /// A Gen 3 (`RingVibration.isSupported`); false while the generation is unknown.
    var supportsVibration: Bool { get }
    /// Nothing visible holds the link: no history drain, live read, workout or calibration.
    var isIdleForShortcut: Bool { get }
    var lastVibrationBlock: RingAlarmBlock? { get }
    func vibrate(_ pattern: VibrationPattern) -> Bool
}

extension RingSession: ShortcutRingSession {
    var generationKnown: Bool { firmwareInfo.generation != .unknown }
    var isIdleForShortcut: Bool { !syncing && !monitoring && !livePreparing && !workoutHolding && !calibrationCapturing }
}

/// The ring's connection as Vibrate Wearable uses it. `RingScanner` in the app.
@MainActor
protocol ShortcutRingLink: AnyObject {
    var shortcutSession: (any ShortcutRingSession)? { get }
    /// A ring is the active saved one (`RingScanner.persistedActiveRingID`), so a connect that isn't
    /// issued yet (the central not powered on) is still armed (review-261b S-C).
    var hasActiveRing: Bool { get }
    /// Arm a connect to the saved ring; false when none was issued now (no central is created without
    /// a saved ring, #142).
    func connectForShortcut() -> Bool
}

extension RingScanner: ShortcutRingLink {
    var shortcutSession: (any ShortcutRingSession)? { session }
    var hasActiveRing: Bool { Self.persistedActiveRingID != nil }
    func connectForShortcut() -> Bool { reconnectKnownPeripheral() }
}

/// What Set Wake Alarm last put on the ring's wake-up alarm (`RingAlarmController`).
struct ShortcutRingAlarmRecord: Codable, Equatable {
    var hour: Int
    var minute: Int
    var weekdays: Set<Int>
    /// The one occurrence of a "Once" alarm (`RingAlarmController.oneShotOccurrence`); nil: repeating.
    var oneShot: Date?

    /// The alarm still holds what Shortcuts set: on, same time, days and one-shot.
    func matches(_ alarm: RingAlarm, oneShot current: Date?) -> Bool {
        alarm.isEnabled && alarm.hour == hour && alarm.minute == minute && alarm.weekdays == weekdays
            && current == oneShot
    }
}

/// The record, under its own versioned UserDefaults key (no SwiftData).
struct ShortcutRingAlarmStore {
    nonisolated static let key = "shortcuts.ringAlarm.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var record: ShortcutRingAlarmRecord? {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ShortcutRingAlarmRecord.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// The ring alarm screen's one line: "Once" for a one-shot, "Set by Shortcuts" while the alarm
    /// still holds what Shortcuts set. nil when neither applies.
    func note(alarm: RingAlarm, oneShot: Date?) -> String? {
        var parts: [String] = []
        if alarm.isEnabled, oneShot != nil { parts.append("Once") }
        if record?.matches(alarm, oneShot: oneShot) == true { parts.append("Set by Shortcuts") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension ZeppAlarmDays {
    /// The ring alarm's `Calendar` weekdays (1 = Sunday … 7 = Saturday) for these days; every day is the
    /// empty set (`RingAlarm.weekdays`). Once has none: the one-shot gets its occurrence's weekday.
    var ringWeekdays: Set<Int> {
        let map: [(ZeppAlarmDays, Int)] = [(.sunday, 1), (.monday, 2), (.tuesday, 3), (.wednesday, 4),
                                           (.thursday, 5), (.friday, 6), (.saturday, 7)]
        let days = Set(map.filter { contains($0.0) }.map(\.1))
        return days.count == 7 ? [] : days
    }
}
