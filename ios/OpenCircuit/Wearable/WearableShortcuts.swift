import Foundation
import OpenCircuitKit
import ZeppKit

// What the Shortcuts actions do (#260, decision 52), apart from App Intents so the tests drive it
// against the simulated strap. The intents (`WearableShortcutIntents.swift`) only turn parameters into
// a call here and the result into a dialog.
//
// Reaching the strap: decision 1 first (the strap chosen AND saved, or nothing is created or
// connected), then the session that is there, ready, or the existing standing connect
// (`HelioConnection.reconnectKnown`, the background run's own connect), waited on for at most
// `reachTimeout`. Nothing here disconnects: a link this brings up stays up with its standing connect,
// exactly as a background run leaves it after a sync (B.5), and a link another run holds is used as
// it is. A buzz and an alarm write go over the chunked link (`…0016`/`…0017`, endpoints `0x001A` and
// `0x000F`) and a history fetch over `…0004`/`…0005`: `HelioSession.buzz()` and its alarm edits don't
// look at the fetch, and neither does the app's own Buzz button or Alarms screen, so a sync in progress
// is not waited for (`testABuzzAndAnAlarmWriteDuringASyncLeaveTheSyncWhole` measures it).

/// The strap's connection as the Shortcuts actions use it. `HelioConnection` in the app.
@MainActor
protocol ShortcutStrapLink: AnyObject {
    var session: HelioSession? { get }
    /// The last connection in this launch ended with the strap busy (decision 7).
    var endedBusy: Bool { get }
    /// Arm a connect to the saved strap by identifier (no scan); false when there is none.
    func connectForShortcut() -> Bool
}

extension HelioConnection: ShortcutStrapLink {
    func connectForShortcut() -> Bool { reconnectKnown() }
}

/// The key as a Shortcut needs to know it, read before any radio work.
enum StrapKeyState: Equatable {
    case saved
    case missing
    case rejected
}

/// Everything the actions read from the app, injectable for the tests.
@MainActor
struct WearableShortcutEnvironment {
    var device: @MainActor () -> ActiveDeviceChoice
    /// The saved strap's identity (`HelioConnection.savedPeripheralID`), nil when none was ever connected.
    var savedStrapID: @MainActor () -> String?
    var strapKey: @MainActor () -> StrapKeyState
    /// Only called with the strap chosen and saved (decision 1).
    var strapLink: @MainActor () -> any ShortcutStrapLink
    /// Only called with the ring chosen; never connects (the ring path uses a ready session only).
    var ringSession: @MainActor () -> RingSession?
    var applier: StrapWakeAlarmApplier
    var now: @MainActor () -> Date
    /// One wait between checks (250 ms in the app; the tests move the simulated strap along instead).
    var pause: @MainActor () async -> Void
    var isCancelled: @MainActor () -> Bool = { Task.isCancelled }

    var store: StrapWakeAlarmStore { applier.store }

    static var live: WearableShortcutEnvironment {
        WearableShortcutEnvironment(
            device: { ActiveDeviceChoiceStore.persisted() },
            savedStrapID: { HelioConnection.savedPeripheralID },
            strapKey: {
                let keys = HelioConnection.shared.keyStore
                if keys.load() == nil { return .missing }
                return keys.isRejected ? .rejected : .saved
            },
            strapLink: { HelioConnection.shared },
            ringSession: { RingScanner.shared.session },
            applier: .shared,
            now: { Date() },
            pause: { try? await Task.sleep(for: .milliseconds(250)) })
    }
}

/// What one action run did, for its dialog and its log line.
struct WearableShortcutResult: Equatable {
    /// Said to the person.
    let dialog: String
    /// For the log: the outcome only, no time of day (`privacy: .public`).
    let outcome: String
}

@MainActor
struct WearableShortcuts {
    /// Decision 52 / the brief: how long an action waits for the strap to come up and be ready.
    static let reachTimeout: TimeInterval = 20
    /// How long an alarm write may take once the strap is ready: the editor's ack and re-read
    /// timeouts (5 s each, `ZeppAlarmEditor.Configuration`) plus a margin.
    static let alarmWriteTimeout: TimeInterval = 12
    /// After the stop (`06`) is handed to the link: time for it to leave the radio before the action
    /// returns and iOS may suspend the app (the margin `HelioConnection.disconnect` gives a find stop).
    static let stopMargin: TimeInterval = 0.5
    /// The pause between two buzzes when "Times" is more than 1.
    static let strapBuzzGap: TimeInterval = 1
    /// The ring's: its alarm burst never spaces buzzes closer than 2 s (`RingAlarm.clampedBurstSpacing`).
    static let ringBuzzGap: TimeInterval = 2
    static let maxTimes = 5

    let env: WearableShortcutEnvironment

    init(_ env: WearableShortcutEnvironment) {
        self.env = env
    }

    init() {
        env = .live
    }

    // MARK: Vibrate Wearable (52a)

    func vibrate(times requested: Int) async -> WearableShortcutResult {
        .init(dialog: "", outcome: "stub")   // RED: stub
    }

    // MARK: Set / Clear Wake Alarm (52b, 52c)

    func setWakeAlarm(hour: Int, minute: Int, days: ZeppAlarmDays) async -> WearableShortcutResult {
        .init(dialog: "", outcome: "stub")   // RED: stub
    }

    func clearWakeAlarm() async -> WearableShortcutResult {
        .init(dialog: "", outcome: "stub")   // RED: stub
    }
}
