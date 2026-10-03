import Foundation
import OpenCircuitKit
import ZeppKit

// What the Shortcuts actions do (#260, decision 52), apart from App Intents so the tests drive it
// against the simulated strap. The intents (`WearableShortcutIntents.swift`) only turn parameters into
// a call here and the result into a dialog.
//
// Reaching the strap: decision 1 first (the strap chosen AND saved, or nothing is created or
// connected), then the session that is there, ready, or the existing standing connect
// (`HelioConnection.reconnectForShortcut` → `reconnectKnown`, the background run's own connect), waited on for at most
// `reachTimeout`. Nothing here disconnects: a link this brings up stays up with its standing connect,
// exactly as a background run leaves it after a sync (B.5), and a link another run holds is used as
// it is. A buzz and an alarm write go over the chunked link (`…0016`/`…0017`, endpoints `0x001A` and
// `0x000F`) and a history fetch over `…0004`/`…0005`: `HelioSession.buzz()` and its alarm edits don't
// look at the fetch, and neither does the app's own Buzz button or Alarms screen, so a sync in progress
// is not waited for (`testABuzzAndAnAlarmWriteInsideTheFirstRoundLeaveTheSyncWhole` measures it).

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
    func connectForShortcut() -> Bool { reconnectForShortcut() }
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
    /// A ring was connected before (`RingScanner.hasSavedRingToRestore`, UserDefaults only). Only read
    /// with the ring chosen.
    var ringSaved: @MainActor () -> Bool
    /// The ring's cached generation (`RingMetadataStore`), nil when no connection ever named it. Set and
    /// Clear decide from it: they need no connection (decision 52g).
    var ringGeneration: @MainActor () -> RingGeneration?
    /// Only called with the ring chosen AND saved (decision 1, 52g).
    var ringLink: @MainActor () -> any ShortcutRingLink
    /// The ring's wake-up alarm. Only called with the ring chosen.
    var ringAlarm: @MainActor () -> RingAlarmController
    /// What Shortcuts last set on it.
    var ringShortcutStore = ShortcutRingAlarmStore()
    var applier: StrapWakeAlarmApplier
    var now: @MainActor () -> Date
    /// One wait between checks (250 ms in the app; the tests move the simulated strap along instead).
    var pause: @MainActor () async -> Void
    var isCancelled: @MainActor () -> Bool = { Task.isCancelled }
    /// Whether the phone has been unlocked once since it restarted (`FirstUnlockSentinel`). NOT whether
    /// it is locked now: a locked phone after its first unlock proceeds (steer 4).
    var firstUnlockProbe: @MainActor () -> FirstUnlockProbe = { .readable }
    /// Creates the sentinel when an action proceeds and finds none.
    var ensureFirstUnlockSentinel: @MainActor () -> Void = {}

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
            ringSaved: { RingScanner.hasSavedRingToRestore },
            ringGeneration: { RingGeneration(rawValue: RingMetadataStore().load().generation) },
            ringLink: { RingScanner.shared },
            ringAlarm: { RingAlarmController.shared },
            applier: .shared,
            now: { Date() },
            pause: { try? await Task.sleep(for: .milliseconds(250)) },
            firstUnlockProbe: { FirstUnlockSentinel().probe() },
            ensureFirstUnlockSentinel: { FirstUnlockSentinel().ensure() })
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
    /// How long an action waits for the strap to come up and be ready (review-261 Q4: 15 s, so reaching
    /// it plus an alarm write and re-read stay under 30 s).
    static let reachTimeout: TimeInterval = 15
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
        if let locked = lockedOut("vibrate") { return locked }
        let times = min(max(requested, 1), Self.maxTimes)
        let device = env.device()
        let result: WearableShortcutResult
        switch device.onDemandVibration {
        case .unsupported:
            result = .init(dialog: "Your \(device.displayName) can't be made to vibrate from OpenCircuit.",
                           outcome: "device can't vibrate")
        case .supported, .someModels:
            switch device {
            case .ringConn: result = await vibrateRing(times: times, device: device)
            case .helioStrap: result = await vibrateStrap(times: times, device: device)
            }
        }
        Self.log("vibrate", result)
        return result
    }

    /// The ring's motor (Gen 3, decision 52g): only with the ring chosen AND saved, through the saved
    /// ring's standing connect (`reconnectKnownPeripheral`) and the same bounded wait as the strap's,
    /// for a ready, idle session whose generation is known. One frame per buzz, nothing to stop
    /// afterwards; the action stays until the last one is sent, so iOS can't suspend the app between
    /// them. `RingSession.vibrate` keeps its own guards (busy, charging, link): a refusal for "busy"
    /// is waited out inside the same window, never forced.
    private func vibrateRing(times: Int, device: ActiveDeviceChoice) async -> WearableShortcutResult {
        let name = device.displayName
        guard env.ringSaved() else { return Self.noDevice(name, outcome: "no saved ring") }
        let deadline = env.now().addingTimeInterval(Self.reachTimeout)
        let session: any ShortcutRingSession
        switch await reachRing(deadline: deadline) {
        case .ready(let ready): session = ready
        case .noMotor:
            var dialog = "Your \(name) doesn't have a motor OpenCircuit can drive."
            if case .someModels(let only) = device.onDemandVibration { dialog += " Only \(only) has one." }
            return .init(dialog: dialog, outcome: "ring has no motor")
        case .unreachable(let why):
            return .init(dialog: Self.sentence(why, name) + " It didn't vibrate.", outcome: "unreachable: \(why.label)")
        }
        for index in 0..<times {
            if index > 0 { await wait(Self.ringBuzzGap) }
            if env.isCancelled() { return Self.cancelled(name, ran: index, of: times) }
            // `vibrate` declines while the ring syncs, measures or charges (its one-writer discipline).
            while !session.vibrate(.notification) {
                if session.lastVibrationBlock == .ringBusy, env.now() < deadline, !env.isCancelled() {
                    await env.pause()
                    continue
                }
                let done = index > 0 ? " It vibrated \(index) of \(times) times first." : ""
                return .init(dialog: Self.ringBlocked(session.lastVibrationBlock, name: name) + done,
                             outcome: "ring blocked: \(session.lastVibrationBlock?.rawValue ?? "unknown")")
            }
        }
        return Self.vibrated(name, times)
    }

    private enum RingReach {
        case ready(any ShortcutRingSession)
        case noMotor
        case unreachable(Unreachable)
    }

    /// The saved ring's session once it is ready, idle and knows its generation, before `deadline`.
    private func reachRing(deadline: Date) async -> RingReach {
        let link = env.ringLink()
        if link.shortcutSession?.ready != true, !link.connectForShortcut() { return .unreachable(.notConnecting) }
        while true {
            if let session = link.shortcutSession, session.ready, session.generationKnown {
                guard session.supportsVibration else { return .noMotor }
                if session.isIdleForShortcut { return .ready(session) }
            }
            if env.isCancelled() { return .unreachable(.cancelled) }
            if env.now() >= deadline {
                return .unreachable(link.shortcutSession?.ready == true ? .syncing : .timedOut)
            }
            await env.pause()
        }
    }

    /// The strap: find start, then the stop the session's own tick sends at `buzzLength` (decision 19).
    /// The action returns only once that `06` was handed to the link, plus `stopMargin`, so iOS can't
    /// suspend the app with the strap still buzzing. If the link drops mid-buzz anyway, decision 18's
    /// owed stop (`HelioFindState`, persisted) goes out first on the next connection; nothing here
    /// re-implements it.
    private func vibrateStrap(times: Int, device: ActiveDeviceChoice) async -> WearableShortcutResult {
        let name = device.displayName
        guard env.savedStrapID() != nil else { return Self.noStrap(name) }
        if let why = keyProblem() { return .init(dialog: Self.sentence(why, name) + " It didn't vibrate.", outcome: "unreachable: \(why.label)") }
        let session: HelioSession
        switch await reachStrap() {
        case .ready(let ready): session = ready
        case .unreachable(let why):
            return .init(dialog: Self.sentence(why, name) + " It didn't vibrate.", outcome: "unreachable: \(why.label)")
        }
        guard session.capabilities.contains(.vibration) else {
            return .init(dialog: "Your \(name) didn't report on this connection that it can buzz, so OpenCircuit sent nothing.",
                         outcome: "buzz not offered")
        }
        for index in 0..<times {
            if index > 0 { await wait(Self.strapBuzzGap) }
            // Review-261 S4: iOS ended the action. The buzz before this one already has its stop.
            if env.isCancelled() { return Self.cancelled(name, ran: index, of: times) }
            if let refusal = session.buzz() {
                return .init(dialog: refusal, outcome: "buzz refused")
            }
            let latest = env.now().addingTimeInterval(HelioFindState.configuration.buzzLength + 3)
            while session.isFinding, env.now() < latest, !env.isCancelled() { await env.pause() }
            // The tick sends the stop at `buzzLength`. Should it not have (iOS cancelled the action, or
            // the session's timer didn't run), send it now rather than return with the strap buzzing.
            if session.isFinding { session.stopFind() }
            if session.findPhase == .stopped(.linkLost) {
                return .init(dialog: "The connection to your \(name) dropped mid-buzz. OpenCircuit sends the stop as soon as it reconnects.",
                             outcome: "link dropped mid-buzz")
            }
            await wait(Self.stopMargin)
        }
        return Self.vibrated(name, times)
    }

    // MARK: Set / Clear Wake Alarm (52b, 52c)

    func setWakeAlarm(hour: Int, minute: Int, days: ZeppAlarmDays) async -> WearableShortcutResult {
        if let locked = lockedOut("set wake alarm") { return locked }
        let device = env.device()
        let name = device.displayName
        let result: WearableShortcutResult
        if case .notStored(let alternative) = device.wakeAlarm {
            result = Self.storesNoAlarms(name, alternative: alternative)
        } else if !(0..<24).contains(hour) || !(0..<60).contains(minute) || !days.isValid {
            result = .init(dialog: "That time isn't valid.", outcome: "invalid time")
        } else {
            let time = StrapWakeAlarmTime(hour: UInt8(hour), minute: UInt8(minute), days: days)
            switch (device.wakeAlarm, device) {
            case (.storedOnDevice, .helioStrap): result = await setOnStrap(time, name: name, noun: device.noun)
            case (.appDriven, .ringConn): result = setOnRing(time, name: name)
            case (.notStored, _), (.storedOnDevice, .ringConn), (.appDriven, .helioStrap):
                result = Self.storesNoAlarms(name, alternative: nil)   // not what today's descriptor says
            }
        }
        Self.log("set wake alarm", result)
        return result
    }

    func clearWakeAlarm() async -> WearableShortcutResult {
        if let locked = lockedOut("clear wake alarm") { return locked }
        let device = env.device()
        let name = device.displayName
        let result: WearableShortcutResult
        switch (device.wakeAlarm, device) {
        case (.notStored, _), (.storedOnDevice, .ringConn), (.appDriven, .helioStrap):
            result = .init(dialog: "Your \(name) doesn't store alarms on itself, so there's nothing to clear.",
                           outcome: "device stores no alarms")
        case (.storedOnDevice, .helioStrap):
            result = await clearOnStrap(name: name)
        case (.appDriven, .ringConn):
            result = clearOnRing(name: name)
        }
        Self.log("clear wake alarm", result)
        return result
    }

    // MARK: The ring's wake-up alarm (52g)

    /// Set and Clear decide from the cached generation (they need no connection): a known model
    /// without a motor is refused, and so is an unknown one, until a connection names it.
    private func ringAlarmRefusal(_ name: String) -> WearableShortcutResult? {
        guard env.ringSaved() else { return Self.noDevice(name, outcome: "no saved ring") }
        guard let generation = env.ringGeneration(), generation != .unknown else {
            return .init(dialog: "OpenCircuit doesn't know your \(name)'s model yet. Open the app with the ring "
                         + "connected once, then try again.", outcome: "ring model unknown")
        }
        guard RingVibration.isSupported(generation) else {
            return .init(dialog: "Your \(name) (\(generation.rawValue)) doesn't have a motor OpenCircuit can drive, so "
                         + "it can't have a wake-up alarm. Only the RingConn Gen 3 has one.", outcome: "ring has no motor")
        }
        return nil
    }

    /// OpenCircuit's own ring wake-up alarm (`RingAlarmController`), replaced: time, days and on; the
    /// person's pattern, burst and backup-alert settings stay. Nothing is stored on the ring.
    private func setOnRing(_ time: StrapWakeAlarmTime, name: String) -> WearableShortcutResult {
        if let refusal = ringAlarmRefusal(name) { return refusal }
        let controller = env.ringAlarm()
        let hour = Int(time.hour), minute = Int(time.minute)
        let once = time.days == .once
        let current = controller.alarm
        let when = Self.describe(time, now: env.now())
        // Already exactly this: nothing is rewritten, because storing marks a due occurrence handled.
        let sameSchedule = current.isEnabled && current.hour == hour && current.minute == minute
        let alreadySet = once
            ? sameSchedule && controller.oneShotOccurrence != nil
                && controller.oneShotOccurrence == RingAlarmController.oneShotOccurrence(hour: hour, minute: minute,
                                                                                          after: env.now(), calendar: .current)
            : sameSchedule && controller.oneShotOccurrence == nil && current.weekdays == time.days.ringWeekdays
        if alreadySet {
            return .init(dialog: "Your \(name)'s wake-up alarm is already set for \(when). Nothing changed.", outcome: "already set")
        }
        let stored = controller.setFromShortcut(hour: hour, minute: minute, weekdays: time.days.ringWeekdays, once: once,
                                                now: env.now())
        env.ringShortcutStore.record = ShortcutRingAlarmRecord(hour: hour, minute: minute, weekdays: stored.alarm.weekdays,
                                                               oneShot: stored.oneShot)
        helioLog.notice("shortcuts: ring wake-up alarm \(when, privacy: .private) set")
        let backup = stored.alarm.backupNotification
            ? "The backup notification is on."
            : "The backup notification is off, so nothing else goes off if the buzz is missed. Turn it on in "
                + "OpenCircuit: Profile ▸ Device Info ▸ Vibration & alarm."
        return .init(dialog: "Set OpenCircuit's wake-up alarm for your \(name): \(when). The app buzzes the ring; nothing "
                     + "is stored on the ring, so the buzz can be up to 15 minutes late, or missed if the ring isn't "
                     + "connected then. " + backup, outcome: "set")
    }

    /// Turns the ring's wake-up alarm off only while it still holds what Shortcuts last set (52c's rule).
    private func clearOnRing(name: String) -> WearableShortcutResult {
        if let refusal = ringAlarmRefusal(name) { return refusal }
        let store = env.ringShortcutStore
        guard let record = store.record else {
            return .init(dialog: "There's no wake-up alarm from Shortcuts for your \(name). An alarm you set in the app "
                         + "is never touched.", outcome: "nothing to clear")
        }
        let controller = env.ringAlarm()
        let alarm = controller.alarm
        store.record = nil
        guard alarm.isEnabled else {
            return .init(dialog: "The wake-up alarm Shortcuts set for your \(name) is already off.", outcome: "already off")
        }
        guard record.matches(alarm, oneShot: controller.oneShotOccurrence) else {
            return .init(dialog: "The wake-up alarm for your \(name) was changed in OpenCircuit since Shortcuts set it, "
                         + "so it was left as it is.", outcome: "changed in the app; left alone")
        }
        controller.turnOff()
        return .init(dialog: "Turned off the wake-up alarm Shortcuts set for your \(name).", outcome: "cleared")
    }

    private func setOnStrap(_ time: StrapWakeAlarmTime, name: String, noun: String) async -> WearableShortcutResult {
        guard env.savedStrapID() != nil else { return Self.noStrap(name) }
        // Decision 52b: the request is persisted FIRST, so a strap out of range, an expiry or a link
        // drop leaves it for the next connection (`StrapWakeAlarmApplier.attach`).
        let request = StrapWakeAlarmRequest(.set(time), strapID: env.savedStrapID(), madeAt: env.now())
        env.store.pending = request
        let when = Self.describe(time, now: env.now())
        helioLog.notice("shortcuts: wake alarm \(when, privacy: .private) saved; applying")
        switch await apply(request, name: name) {
        case .done(.set):
            return .init(dialog: "Set a wake alarm on your \(name) for \(when). It goes off on the \(noun) itself, even with your phone away.",
                         outcome: "set")
        case .done(.noWrite(.alreadySet)):
            return .init(dialog: "Your \(name) already has a wake alarm for \(when). Nothing changed.", outcome: "already set")
        case .done(.refused(.noFreeSlot)):
            return .init(dialog: "Not set: your \(name) already has 10 alarms. Delete one on its Alarms screen in OpenCircuit, then run this again.",
                         outcome: "no free slot")
        case .done(.writeFailed):
            return .init(dialog: "Your \(name) didn't accept the alarm. OpenCircuit kept the request and will try again the next time it connects.",
                         outcome: "write failed; pending")
        case .done(.cleared):
            // Decision 52f: the person's own alarm already holds this setting; the managed one went.
            return .init(dialog: "Your \(name) already has its own alarm for \(when), so OpenCircuit removed the one it had set. Only yours will go off.",
                         outcome: "already on the strap; managed slot cleared")
        case .done(.noWrite(.expired)):
            return .init(dialog: "Not set: \(when) passed before your \(name) could be reached.", outcome: "expired; dropped")
        case .done(.notConfirmed), .done(.noWrite):
            return .init(dialog: "Your \(name) didn't confirm the alarm when OpenCircuit read it back. OpenCircuit kept the request and will check again the next time it connects.",
                         outcome: "not confirmed; pending")
        case .kept(let why, let label):
            return .init(dialog: "Saved. \(why) The alarm will be set the next time it connects.", outcome: "pending: \(label)")
        case .superseded:
            return .init(dialog: "A newer wake alarm request replaced this one.", outcome: "superseded")
        }
    }

    private func clearOnStrap(name: String) async -> WearableShortcutResult {
        guard let strapID = env.savedStrapID() else { return Self.noStrap(name) }
        let state = env.store.state
        // Review-261 S1: a set whose write is out now, or an unconfirmed one (a candidate), may be on the
        // strap: the clear is queued behind it and goes through the strap, not answered "cancelled".
        let setInFlight = state.pending.map { env.applier.isWriting($0.id) } ?? false
        guard state.managed?.strapID == strapID || state.candidate?.strapID == strapID || setInFlight else {
            // Nothing of OpenCircuit's on this strap: no connection needed. A set still waiting for the
            // strap is withdrawn instead.
            if case .set? = state.pending?.kind {
                env.store.pending = nil
                return .init(dialog: "Cancelled the wake alarm that was waiting to be set on your \(name).",
                             outcome: "cancelled pending set")
            }
            if state.pending != nil { env.store.pending = nil }
            return .init(dialog: "There's no wake alarm from Shortcuts on your \(name). Alarms you made yourself are never touched.",
                         outcome: "nothing to clear")
        }
        let request = StrapWakeAlarmRequest(.clear, strapID: strapID, madeAt: env.now())
        env.store.pending = request
        switch await apply(request, name: name) {
        case .done(.cleared):
            return .init(dialog: "Removed the wake alarm OpenCircuit set on your \(name).", outcome: "cleared")
        case .done(.noWrite(.changedOnStrap)):
            return .init(dialog: "The wake alarm OpenCircuit set on your \(name) was changed or removed since, so it was left as it is.",
                         outcome: "changed on strap; left alone")
        case .done(.noWrite):
            return .init(dialog: "There's no wake alarm from Shortcuts on your \(name).", outcome: "nothing to clear")
        case .done(.writeFailed), .done(.notConfirmed), .done(.set), .done(.refused):
            return .init(dialog: "Your \(name) didn't confirm removing the alarm. OpenCircuit kept the request and will try again the next time it connects.",
                         outcome: "not confirmed; pending")
        case .kept(let why, let label):
            return .init(dialog: "Saved. \(why) The alarm will be removed the next time it connects.", outcome: "pending: \(label)")
        case .superseded:
            return .init(dialog: "A newer wake alarm request replaced this one.", outcome: "superseded")
        }
    }

    private enum Applied {
        case done(StrapWakeAlarmApplier.Outcome)
        /// Not applied on this run: the request stays pending for the next connection. `why` is said.
        case kept(why: String, label: String)
        /// Another run's request replaced this one before it was applied.
        case superseded
    }

    /// Applies `request` (already pending) through the strap's session, or leaves it pending.
    private func apply(_ request: StrapWakeAlarmRequest, name: String) async -> Applied {
        if let why = keyProblem() { return .kept(why: Self.sentence(why, name), label: why.label) }
        let session: HelioSession
        switch await reachStrap() {
        case .ready(let ready): session = ready
        case .unreachable(let why):
            // A connection that came up meanwhile may have applied it already (its setup hook).
            if let outcome = env.applier.outcome(for: request.id) { return .done(outcome) }
            return .kept(why: Self.sentence(why, name), label: why.label)
        }
        let deadline = env.now().addingTimeInterval(Self.alarmWriteTimeout)
        while true {
            if let outcome = env.applier.outcome(for: request.id) { return .done(outcome) }
            if env.store.pending?.id != request.id { return .superseded }
            guard session.isLinkConnected else {
                return .kept(why: "The connection to your \(name) dropped before it confirmed.", label: "link dropped")
            }
            if !env.applier.isWriting(request.id) {
                switch env.applier.applyPending(on: session) {
                case .clockNotSet:
                    return .kept(why: "Your \(name) didn't confirm its clock on this connection, so its alarms can't be changed now.",
                                 label: "clock not set")
                case .alarmsUnavailable:
                    return .kept(why: "Your \(name)'s alarms couldn't be read on this connection.", label: "alarms unavailable")
                case .finished, .nothingPending:
                    continue   // the outcome (or the newer request) is checked at the top
                case .writing, .reading, .busy:
                    break
                }
            }
            if env.isCancelled() {
                return .kept(why: "iOS ended the action before your \(name) confirmed.", label: "cancelled")
            }
            if env.now() >= deadline {
                return .kept(why: "Your \(name) didn't confirm in time.", label: "write timed out")
            }
            await env.pause()
        }
    }

    // MARK: Reaching the strap

    enum Unreachable: Equatable {
        case timedOut
        case notConnecting
        case busy
        case keyNeeded
        case keyRejected
        case unsupported
        case cancelled
        /// The ring is up but a history drain (or a live read) held it for the whole window.
        case syncing

        var label: String {
            switch self {
            case .timedOut: return "timed out"
            case .notConnecting: return "no connection"
            case .busy: return "busy"
            case .keyNeeded: return "key needed"
            case .keyRejected: return "key rejected"
            case .unsupported: return "unsupported"
            case .cancelled: return "cancelled"
            case .syncing: return "syncing"
            }
        }
    }

    private enum Reach {
        case ready(HelioSession)
        case unreachable(Unreachable)
    }

    /// The key, before any radio work (the background run's own quiet endings, decision 7).
    private func keyProblem() -> Unreachable? {
        switch env.strapKey() {
        case .saved: return nil
        case .missing: return .keyNeeded
        case .rejected: return .keyRejected
        }
    }

    /// The strap's session once it is ready (set up, idle or syncing), within `reachTimeout`. Only
    /// called with the strap chosen and saved. A strap that ended busy is not reconnected (decision 7:
    /// an automation firing on every message would otherwise be a re-auth loop).
    private func reachStrap() async -> Reach {
        let link = env.strapLink()
        if link.endedBusy { return .unreachable(.busy) }
        let deadline = env.now().addingTimeInterval(Self.reachTimeout)
        if link.session?.isLinkConnected != true, !link.connectForShortcut() { return .unreachable(.notConnecting) }
        while true {
            if let session = link.session, session.isLinkConnected {
                switch session.phase {
                case .ready, .syncing: return .ready(session)
                case .keyless: return .unreachable(.keyNeeded)
                case .keyRejected: return .unreachable(.keyRejected)
                case .strapBusy: return .unreachable(.busy)
                case .unsupported: return .unreachable(.unsupported)
                case .starting, .authenticating, .settingUp: break
                }
            }
            if env.isCancelled() { return .unreachable(.cancelled) }
            if env.now() >= deadline { return .unreachable(.timedOut) }
            await env.pause()
        }
    }

    private func wait(_ seconds: TimeInterval) async {
        let until = env.now().addingTimeInterval(seconds)
        while env.now() < until, !env.isCancelled() { await env.pause() }
    }

    // MARK: Copy (device-neutral: every name is the active device's `displayName`)

    static func sentence(_ why: Unreachable, _ name: String) -> String {
        switch why {
        case .timedOut: return "Couldn't reach your \(name) within \(Int(reachTimeout)) seconds; it may be out of range."
        case .notConnecting: return "Couldn't start a connection to your \(name)."
        case .busy: return "Your \(name) looks busy with another phone or app."
        case .keyNeeded: return "Your \(name) needs its key saved in OpenCircuit."
        case .keyRejected: return "Your \(name) rejected its key. Replace it in OpenCircuit."
        case .unsupported: return "Your \(name) doesn't offer what OpenCircuit needs over Bluetooth."
        case .cancelled: return "iOS ended the action before your \(name) answered."
        case .syncing: return "Your \(name) stayed busy syncing for \(Int(reachTimeout)) seconds; try again in a minute."
        }
    }

    /// F2 (review-261), fixed by steer 4: ONLY before the first unlock since boot, UserDefaults and the
    /// Keychain read as empty, so the device choice would read as the ring and the key as missing. Then
    /// nothing is read or persisted. A phone that is merely locked proceeds (`FirstUnlockGate`).
    private func lockedOut(_ action: String) -> WearableShortcutResult? {
        let probe = env.firstUnlockProbe()
        switch FirstUnlockGate.verdict(for: probe) {
        case .proceed:
            switch probe {
            case .failed(let status):
                helioLog.error("shortcuts: first-unlock sentinel unreadable (status \(status, privacy: .public)); proceeding")
            case .missing:
                env.ensureFirstUnlockSentinel()
            case .readable, .beforeFirstUnlock:
                break
            }
            return nil
        case .refuse:
            let result = WearableShortcutResult(dialog: "Unlock your iPhone once after restarting, then try again.",
                                                outcome: "before first unlock")
            Self.log(action, result)
            return result
        }
    }

    static func cancelled(_ name: String, ran: Int, of times: Int) -> WearableShortcutResult {
        .init(dialog: ran == 0 ? "iOS ended the action before your \(name) vibrated."
                               : "Vibrated your \(name) \(ran) of \(times) times; iOS ended the action before the rest.",
              outcome: "cancelled after \(ran) of \(times)")
    }

    static func noStrap(_ name: String) -> WearableShortcutResult { noDevice(name, outcome: "no saved strap") }

    static func noDevice(_ name: String, outcome: String) -> WearableShortcutResult {
        .init(dialog: "No \(name) is set up in OpenCircuit yet. Set it up in the app first.", outcome: outcome)
    }

    static func storesNoAlarms(_ name: String, alternative: String?) -> WearableShortcutResult {
        .init(dialog: (["Your \(name) doesn't store alarms on itself."] + [alternative].compactMap { $0 }).joined(separator: " "),
              outcome: "device stores no alarms")
    }

    static func vibrated(_ name: String, _ times: Int) -> WearableShortcutResult {
        .init(dialog: times == 1 ? "Vibrated your \(name)." : "Vibrated your \(name) \(times) times.", outcome: "vibrated \(times)")
    }

    static func ringBlocked(_ block: RingAlarmBlock?, name: String) -> String {
        switch block {
        case .ringOnCharger: return "Your \(name) is in its charging case, so it didn't vibrate."
        case .ringUnsupported: return "Your \(name) doesn't have a motor OpenCircuit can drive."
        case .linkNotReady: return "Your \(name) isn't connected right now, so it didn't vibrate."
        case .ringBusy, .none: return "Your \(name) is busy syncing, so it didn't vibrate. Try again in a minute."
        }
    }

    /// "7:00 AM, once", in the phone's locale.
    static func describe(_ time: StrapWakeAlarmTime, now: Date, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: Int(time.hour), minute: Int(time.minute), second: 0, of: now) ?? now
        let repeats: String
        switch time.days {
        case .once: repeats = "once"
        case .everyDay: repeats = "every day"
        case .weekdays: repeats = "on weekdays"
        case .weekend: repeats = "on weekends"
        default: repeats = "on " + HelioAlarmsView.daysText(time.days)
        }
        return "\(date.formatted(date: .omitted, time: .shortened)), \(repeats)"
    }

    /// The outcome is public; nothing here carries a time of day (that is logged `.private`).
    private static func log(_ action: String, _ result: WearableShortcutResult) {
        helioLog.notice("shortcuts: \(action, privacy: .public): \(result.outcome, privacy: .public)")
    }
}
