import Foundation
import ZeppKit

// Shortcuts' wake alarm on the strap (#260, decision 52b, 52c): ONE alarm slot OpenCircuit manages,
// written only through `ZeppAlarmEditor` (read, one slot, re-read; ZEPP_PROTOCOL.md §15.2). The strap
// then fires it by itself (§12: 60 s of vibration, tap to stop), with no phone needed at wake time.
//
// Three parts:
// - `StrapWakeAlarmPlanner`: pure. The strap's list, the managed record and the request in; what to
//   write (at most one slot) out.
// - `StrapWakeAlarmStore`: the managed record and the pending request, in UserDefaults.
// - `StrapWakeAlarmApplier`: runs a plan on a session and records the result from the strap's re-read.
//
// §15.1 says nothing is written at session setup. Decision 52b makes the one exception: a request the
// person made from a Shortcut while the strap was away is applied at the next connection that has set
// the clock and read the list (`HelioSession.onSetupAlarmsRead`). It is still one explicit request for
// one slot, and it never touches a slot OpenCircuit didn't write.

/// A time and repeat days for the wake alarm, in the strap's local wall-clock time (§12.3).
struct StrapWakeAlarmTime: Codable, Equatable {
    var hour: UInt8
    var minute: UInt8
    var daysRaw: UInt8

    init(hour: UInt8, minute: UInt8, days: ZeppAlarmDays) {
        self.hour = hour
        self.minute = minute
        daysRaw = days.rawValue
    }

    var days: ZeppAlarmDays { ZeppAlarmDays(rawValue: daysRaw) }
}

/// One Shortcut run's request. Only the latest is kept: a newer request replaces an older pending one.
struct StrapWakeAlarmRequest: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case set(StrapWakeAlarmTime)
        case clear
    }

    let id: UUID
    let kind: Kind
    let madeAt: Date

    init(_ kind: Kind, madeAt: Date, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.madeAt = madeAt
    }
}

/// What OpenCircuit last wrote, and the strap read back, in its managed slot.
struct ManagedStrapAlarm: Codable, Equatable {
    /// The strap's identity (`HelioSession.identityID`): a record for another strap is no record.
    var strapID: String
    var slot: UInt8
    var hour: UInt8
    var minute: UInt8
    var daysRaw: UInt8
    var isEnabled: Bool

    init(strapID: String, alarm: ZeppAlarm) {
        self.strapID = strapID
        slot = alarm.slot
        hour = alarm.hour
        minute = alarm.minute
        daysRaw = alarm.days.rawValue
        isEnabled = alarm.isEnabled
    }

    /// The alarm as written (smart wake is never set by OpenCircuit, §14).
    var alarm: ZeppAlarm {
        ZeppAlarm(slot: slot, hour: hour, minute: minute, days: ZeppAlarmDays(rawValue: daysRaw), isEnabled: isEnabled)
    }
}

// MARK: - The planner

/// Decision 52b, 52c as a pure function, like `StrapLiveHeartRate`'s rules: no session, no defaults.
enum StrapWakeAlarmPlanner {
    enum Action: Equatable {
        /// Nothing to write.
        case none(NoWrite)
        /// A new alarm in the lowest free slot (the editor picks it).
        case add(StrapWakeAlarmTime)
        /// Rewrite the managed slot.
        case replace(ZeppAlarm)
        /// Delete the managed slot.
        case delete(slot: UInt8)
        case refuse(Refusal)
    }

    enum NoWrite: Equatable {
        /// The strap already has this exact alarm, enabled.
        case alreadySet
        /// No managed slot (for this strap): nothing of OpenCircuit's to clear.
        case nothingToClear
        /// The managed slot was changed or removed on the strap (or in the app's Alarms screen): it is
        /// no longer OpenCircuit's, so a clear leaves it as it is.
        case changedOnStrap
    }

    enum Refusal: Equatable {
        /// All 10 slots hold alarms OpenCircuit doesn't manage (§12.4).
        case noFreeSlot
    }

    struct Plan: Equatable {
        let action: Action
        /// The managed record no longer describes the strap: drop it whatever happens next.
        let forgetRecord: Bool
    }

    static func plan(alarms: [ZeppAlarm], strapID: String, record: ManagedStrapAlarm?,
                     request: StrapWakeAlarmRequest.Kind) -> Plan {
        Plan(action: .none(.nothingToClear), forgetRecord: false)   // RED: stub
    }
}

// MARK: - Persistence

/// The managed record and the pending request, under one versioned UserDefaults key (no SwiftData).
struct StrapWakeAlarmStore {
    nonisolated static let key = "helio.shortcutWakeAlarm.v1"

    struct State: Codable, Equatable {
        var managed: ManagedStrapAlarm?
        var pending: StrapWakeAlarmRequest?
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: State {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
            return state
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    var pending: StrapWakeAlarmRequest? {
        get { state.pending }
        nonmutating set { state.pending = newValue }
    }

    var managed: ManagedStrapAlarm? {
        get { state.managed }
        nonmutating set { state.managed = newValue }
    }

    /// The managed slot on `strapID`'s list, for the Alarms screen's "Set by Shortcuts" mark: the
    /// record's slot while it still holds what was written (or that once-alarm, disabled after it fired).
    func managedSlot(strapID: String, alarms: [ZeppAlarm]) -> UInt8? {
        nil   // RED: stub
    }
}

// MARK: - Applying a request on a session

/// Runs the pending request on a strap session and keeps the record honest: the record changes only
/// when the strap's re-read confirms the written slot AND every other slot unchanged
/// (`.writeChecked(slotMatches && otherSlotsUnchanged)`). Any other outcome keeps the request pending
/// for the next connection, and nothing is ever retried on the same connection.
@MainActor
final class StrapWakeAlarmApplier {
    static let shared = StrapWakeAlarmApplier()

    /// How a request ended on a session.
    enum Outcome: Equatable {
        /// The strap's re-read confirmed the alarm in its slot; the record is now this alarm.
        case set(ZeppAlarm)
        /// The strap's re-read confirmed the managed slot empty; there is no record any more.
        case cleared(slot: UInt8)
        case noWrite(StrapWakeAlarmPlanner.NoWrite)
        case refused(StrapWakeAlarmPlanner.Refusal)
        /// The strap refused the write or never acknowledged it. The request stays pending.
        case writeFailed
        /// The write was acknowledged, but the re-read didn't confirm it (or failed). Pending.
        case notConfirmed
    }

    /// Why `applyPending` did or didn't write now.
    enum Progress: Equatable {
        case nothingPending
        /// A write for the pending request is out; its outcome follows the strap's reply.
        case writing
        /// The list is being read first (it changed on the strap since the last read).
        case reading
        /// Another alarm read or write is in flight (the person's own edit, say): try again shortly.
        case busy
        /// The request ended on this session: `outcome(for:)` has it.
        case finished
        /// Alarms can't be written on this connection. The request stays pending for the next one.
        case clockNotSet
        case alarmsUnavailable
    }

    let store: StrapWakeAlarmStore

    private struct InFlight {
        weak var session: HelioSession?
        let requestID: UUID
        let strapID: String
    }

    private var inFlight: InFlight?
    /// The session this applier asked to re-read the list, and one whose list couldn't be read.
    private weak var awaitingRead: HelioSession?
    private weak var readFailed: HelioSession?
    private var outcomes: [UUID: Outcome] = [:]

    init(store: StrapWakeAlarmStore = StrapWakeAlarmStore()) {
        self.store = store
    }

    /// Every strap session gets this before `start()` (`HelioConnection.makeSession`).
    func attach(to session: HelioSession) {
        session.onSetupAlarmsRead = { [weak self, weak session] in
            guard let self, let session else { return }
            let progress = self.applyPending(on: session)
            if progress != .nothingPending {
                helioLog.notice("shortcuts: wake alarm at connection: \(String(describing: progress), privacy: .public)")
            }
        }
        session.alarmEventObserver = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handle(event, from: session)
        }
    }

    /// The outcome of request `id`, once it ended on some session in this process.
    func outcome(for id: UUID) -> Outcome? { outcomes[id] }

    /// A write for request `id` is out on a live session.
    func isWriting(_ id: UUID) -> Bool {
        guard let inFlight, inFlight.session?.isLinkConnected == true else { return false }
        return inFlight.requestID == id
    }

    /// Plans the pending request against `session`'s list and writes at most one slot.
    @discardableResult
    func applyPending(on session: HelioSession) -> Progress {
        guard let pending = store.pending else { return .nothingPending }
        if let current = inFlight {
            if current.session === session, session.isLinkConnected {
                return current.requestID == pending.id ? .writing : .busy
            }
            inFlight = nil   // its session is gone: the request stayed pending
        }
        guard session.isLinkConnected, let editor = session.alarmEditor, editor.capabilities.isSupported(.alarms),
              editor.malformedList == nil else { return .alarmsUnavailable }
        guard editor.isTimeSet else { return .clockNotSet }
        if editor.isBusy { return awaitingRead === session ? .reading : .busy }
        guard let alarms = editor.alarms, !editor.isListStale else {
            if readFailed === session { return .alarmsUnavailable }
            awaitingRead = session
            session.readAlarms()
            return .reading
        }

        let strapID = session.identityID
        let plan = StrapWakeAlarmPlanner.plan(alarms: alarms, strapID: strapID, record: store.managed, request: pending.kind)
        if plan.forgetRecord {
            store.managed = nil
            helioLog.notice("shortcuts: the managed alarm slot no longer matches what was written; forgotten")
        }
        let error: String?
        switch plan.action {
        case .none(let reason):
            finish(pending.id, .noWrite(reason))
            return .finished
        case .refuse(let reason):
            finish(pending.id, .refused(reason))
            return .finished
        case .add(let time):
            error = session.addAlarm(hour: time.hour, minute: time.minute, days: time.days)
        case .replace(let alarm):
            error = session.replaceAlarm(alarm)
        case .delete(let slot):
            error = session.deleteAlarm(slot: slot)
        }
        if let error {
            // The editor refused before anything was sent (checked above, so not expected): pending.
            helioLog.error("shortcuts: wake alarm write not sent (\(error, privacy: .public)); kept pending")
            outcomes[pending.id] = .writeFailed
            return .finished
        }
        inFlight = InFlight(session: session, requestID: pending.id, strapID: strapID)
        return .writing
    }

    private func handle(_ event: ZeppAlarmEditor.Event, from session: HelioSession) {
        switch event {
        case .listRead:
            guard awaitingRead === session else { return }
            awaitingRead = nil
            applyPending(on: session)
        case .listUnreadable:
            guard awaitingRead === session else { return }
            awaitingRead = nil
            readFailed = session
        case .changedOnStrap, .writeAcknowledged:
            break
        case .writeFailed(let write, let failure):
            guard let request = takeInFlight(session, write) else { return }
            outcomes[request.requestID] = .writeFailed
            helioLog.error("shortcuts: wake alarm write to slot \(write.slot, privacy: .public) failed (\(String(describing: failure), privacy: .public)); kept pending")
        case .writeUnverified(let write, _):
            guard let request = takeInFlight(session, write) else { return }
            outcomes[request.requestID] = .notConfirmed
            helioLog.error("shortcuts: wake alarm write to slot \(write.slot, privacy: .public) not read back; kept pending")
        case .writeChecked(let check):
            guard let request = takeInFlight(session, check.write) else { return }
            guard check.slotMatches, check.otherSlotsUnchanged else {
                outcomes[request.requestID] = .notConfirmed
                helioLog.error("shortcuts: wake alarm re-read: matches \(check.slotMatches, privacy: .public), others unchanged \(check.otherSlotsUnchanged, privacy: .public); kept pending")
                return
            }
            switch check.write {
            case .set(let alarm):
                store.managed = ManagedStrapAlarm(strapID: request.strapID, alarm: alarm)
                finish(request.requestID, .set(alarm))
            case .delete(let slot):
                store.managed = nil
                finish(request.requestID, .cleared(slot: slot))
            }
            // A newer request that arrived while this one was out goes next, on the list just read.
            if store.pending != nil { applyPending(on: session) }
        }
    }

    private func takeInFlight(_ session: HelioSession, _ write: ZeppAlarmEditor.Write) -> InFlight? {
        guard let current = inFlight, current.session === session else { return nil }
        inFlight = nil
        return current
    }

    /// The request ended: record its outcome, and drop it if it is still the pending one.
    private func finish(_ id: UUID, _ outcome: Outcome) {
        outcomes[id] = outcome
        if store.pending?.id == id { store.pending = nil }
    }
}
