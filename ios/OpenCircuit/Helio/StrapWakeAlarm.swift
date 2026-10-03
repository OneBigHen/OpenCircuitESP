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
    /// The strap it was made for (`HelioSession.identityID`, the saved strap's id). A request for
    /// another strap, or for none, is dropped at apply (review-261 S5).
    let strapID: String?
    let madeAt: Date
    /// The strap acknowledged this request's set (review-261b U-A). From then on it is never ADDED again:
    /// at most one extra slot can ever be used, whatever the strap reads back. nil in older records.
    var acknowledged: Bool?

    init(_ kind: Kind, strapID: String?, madeAt: Date, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.strapID = strapID
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
        /// Decision 52e: a once-request whose time passed before it could be applied. Dropped, never
        /// written, so the strap is untouched and no alarm goes off a day late.
        case expired
        /// The request was made for another strap, or for none (review-261 S5). Dropped, nothing sent.
        case otherStrap
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

    /// The managed slot as the strap's list shows it.
    enum ManagedSlot: Equatable {
        /// No record, or a record for another strap (treated as absent, and kept for that strap).
        case none
        /// The slot holds exactly what was written.
        case matches(ZeppAlarm)
        /// A once-alarm that matches except that it is now disabled. The strap may disable a once-alarm
        /// after it fires (what it does is 🔴 unknown, ZEPP_PROTOCOL.md §12.3, §13.5), so this is still
        /// OpenCircuit's: a set re-enables it with a replace, and a clear deletes it.
        case firedOnce(ZeppAlarm)
        /// The slot was edited (on the Alarms screen, in Zepp) or is empty: no longer OpenCircuit's.
        case lost
    }

    static func managedSlot(alarms: [ZeppAlarm], strapID: String, record: ManagedStrapAlarm?) -> ManagedSlot {
        guard let record, record.strapID == strapID else { return .none }
        guard let onStrap = alarms.first(where: { $0.slot == record.slot }) else { return .lost }
        let written = record.alarm
        if onStrap.hasSameSetting(as: written) { return .matches(onStrap) }
        // Review-261b U-A (a): the fired once-alarm is recognised by its slot, time and smart wake, whatever
        // repeat byte the strap wrote into it (🔴 what it writes is unknown, §13.5).
        if written.days == .once, written.isEnabled, !onStrap.isEnabled, onStrap.hour == written.hour,
           onStrap.minute == written.minute, onStrap.smartWake == written.smartWake {
            return .firedOnce(onStrap)
        }
        return .lost
    }

    /// Decision 52e: "a pending once-request carries the instant it was made; it is dropped (never
    /// written) at apply time if the next occurrence of its hour:minute after the request instant is
    /// already in the past. Repeating requests (Every Day / Weekdays / Weekends) never expire."
    /// The next occurrence is in `calendar`'s time zone (the phone's, which the strap's clock follows,
    /// decision 9). One that can't be computed counts as passed: a late alarm is what 52e rules out.
    /// "In the past" includes the minute itself having come (`<= now`): written then, it would fire a
    /// day late.
    static func isExpired(_ request: StrapWakeAlarmRequest, now: Date, calendar: Calendar) -> Bool {
        guard case .set(let time) = request.kind, time.days == .once else { return false }
        guard let next = calendar.nextDate(after: request.madeAt,
                                           matching: DateComponents(hour: Int(time.hour), minute: Int(time.minute)),
                                           matchingPolicy: .nextTime) else { return true }
        return next <= now
    }

    /// The rules, in order:
    /// - a request made for another strap, or for none (review-261 S5): nothing is written;
    /// - an expired once-request (decision 52e, `isExpired`): nothing is written;
    /// - a set whose exact alarm (time, days, enabled, no smart wake) the MANAGED slot already holds:
    ///   nothing is written;
    /// - a set whose exact alarm an UNMANAGED slot holds (decision 52f): nothing is added, and the
    ///   managed slot is deleted if it still matches its record, so only the person's alarm fires (the
    ///   record goes when the strap's re-read confirms the delete); a managed slot that no longer
    ///   matches is left alone and its record forgotten. The person's slot is never touched, and never
    ///   adopted as the managed one;
    /// - a managed slot that still holds what was written (or that fired once-alarm): it is replaced;
    /// - a managed slot that no longer does: the record is forgotten, and a new alarm is added in the
    ///   lowest free slot, or the set is refused when there is none;
    /// - a clear deletes the managed slot only while it is still OpenCircuit's;
    /// - no other slot is ever named: an add takes a free slot, and replace and delete only the managed one.
    static func plan(alarms: [ZeppAlarm], strapID: String, record: ManagedStrapAlarm?,
                     request: StrapWakeAlarmRequest, now: Date, calendar: Calendar = .current) -> Plan {
        guard request.strapID == strapID else { return Plan(action: .none(.otherStrap), forgetRecord: false) }
        let managed = managedSlot(alarms: alarms, strapID: strapID, record: record)
        let forget = managed == .lost
        switch request.kind {
        case .clear:
            switch managed {
            case .matches(let alarm), .firedOnce(let alarm):
                return Plan(action: .delete(slot: alarm.slot), forgetRecord: false)
            case .lost:
                return Plan(action: .none(.changedOnStrap), forgetRecord: true)
            case .none:
                return Plan(action: .none(.nothingToClear), forgetRecord: false)
            }
        case .set(let time):
            if isExpired(request, now: now, calendar: calendar) {
                return Plan(action: .none(.expired), forgetRecord: false)
            }
            let holdsRequest = { (alarm: ZeppAlarm) in
                alarm.hasSameSetting(as: ZeppAlarm(slot: alarm.slot, hour: time.hour, minute: time.minute,
                                                   days: time.days, isEnabled: true))
            }
            let ours: ZeppAlarm?
            switch managed {
            case .matches(let alarm), .firedOnce(let alarm): ours = alarm
            case .lost, .none: ours = nil
            }
            if let ours, holdsRequest(ours) { return Plan(action: .none(.alreadySet), forgetRecord: false) }
            if alarms.contains(where: { $0.slot != ours?.slot && holdsRequest($0) }) {
                guard let ours else { return Plan(action: .none(.alreadySet), forgetRecord: forget) }
                return Plan(action: .delete(slot: ours.slot), forgetRecord: false)
            }
            if let ours {
                // `smartWake` is kept as the slot has it (false: OpenCircuit never sets it, and a slot
                // that gained it no longer matches the record).
                return Plan(action: .replace(ZeppAlarm(slot: ours.slot, hour: time.hour, minute: time.minute,
                                                        days: time.days, isEnabled: true, smartWake: ours.smartWake)),
                            forgetRecord: false)
            }
            let used = Set(alarms.map(\.slot))
            guard (0..<ZeppAlarm.slotCount).contains(where: { !used.contains($0) }) else {
                return Plan(action: .refuse(.noFreeSlot), forgetRecord: forget)
            }
            return Plan(action: .add(time), forgetRecord: forget)
        }
    }
}

// MARK: - Persistence

/// The managed record, the pending request and a candidate, under one versioned UserDefaults key (no
/// SwiftData).
struct StrapWakeAlarmStore {
    /// v2 (review-261 S5): the pending request names its strap, and a candidate was added.
    nonisolated static let key = "helio.shortcutWakeAlarm.v2"
    /// v1, before the request named its strap. Read once: its managed record is kept (it names its
    /// strap), its pending request is dropped (it names none, so the apply-time rule would drop it anyway).
    nonisolated static let legacyKey = "helio.shortcutWakeAlarm.v1"

    struct State: Codable, Equatable {
        var managed: ManagedStrapAlarm?
        var pending: StrapWakeAlarmRequest?
        /// A set the strap may have applied but never confirmed (review-261 S2): adopted as managed at a
        /// later list read only if its slot holds exactly this content, else dropped.
        var candidate: ManagedStrapAlarm?
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: State {
        get {
            if let data = defaults.data(forKey: Self.key) {
                return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
            }
            guard let legacy = defaults.data(forKey: Self.legacyKey) else { return State() }
            let old = try? JSONDecoder().decode(State.self, from: legacy)
            let migrated = State(managed: old?.managed, pending: nil, candidate: nil)
            if old?.pending != nil {
                helioLog.notice("shortcuts: a v1 wake alarm request named no strap; dropped")
            }
            if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: Self.key) }
            defaults.removeObject(forKey: Self.legacyKey)
            return migrated
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

    var candidate: ManagedStrapAlarm? {
        get { state.candidate }
        nonmutating set { state.candidate = newValue }
    }

    /// The managed slot on `strapID`'s list, for the Alarms screen's "Set by Shortcuts" mark: the
    /// record's slot while it still holds what was written (or that once-alarm, disabled after it fired).
    func managedSlot(strapID: String, alarms: [ZeppAlarm]) -> UInt8? {
        switch StrapWakeAlarmPlanner.managedSlot(alarms: alarms, strapID: strapID, record: managed) {
        case .matches(let alarm), .firedOnce(let alarm): return alarm.slot
        case .none, .lost: return nil
        }
    }
}

// MARK: - Applying a request on a session

/// Runs the pending request on a strap session and keeps the record honest: the record changes only
/// when the strap's re-read confirms the written slot AND every other slot unchanged
/// (`.writeChecked(slotMatches && otherSlotsUnchanged)`). Any other outcome keeps the request pending
/// for the next connection, and nothing is ever retried on the same connection.
///
/// Review-261:
/// - B1: any alarm write that is not this applier's own, to the managed slot (or the candidate's),
///   forgets that record. The slot is the person's from then on, even if they put an identical alarm
///   back in it (the Alarms screen gives the lowest free slot).
/// - S2: every set this applier sends is persisted as a candidate before it goes out. A confirming
///   re-read promotes it to the record; otherwise it stays, and the next list read adopts it only if
///   its slot holds exactly that content, else drops it. So an alarm the strap applied but never
///   confirmed (a lost ack, a drop before the re-read, another central's change) isn't left unmanaged.
/// - N2: its writes are quiet: the Alarms screen's notice is the person's own edits only.
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
        /// The write was acknowledged, but the re-read didn't confirm it (or failed). A set is finished
        /// (never re-added, review-261b U-A); a delete stays pending.
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

    /// The clock and calendar decision 52e's expiry is judged by (the tests' own; the phone's in the app).
    private let now: @MainActor () -> Date
    private let calendar: Calendar

    init(store: StrapWakeAlarmStore = StrapWakeAlarmStore(), now: @escaping @MainActor () -> Date = { Date() },
         calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
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
        reconcileCandidate(alarms: alarms, strapID: strapID)
        let plan = StrapWakeAlarmPlanner.plan(alarms: alarms, strapID: strapID, record: store.managed, request: pending,
                                              now: now(), calendar: calendar)
        if plan.forgetRecord {
            store.managed = nil
            helioLog.notice("shortcuts: the managed alarm slot no longer matches what was written; forgotten")
        }
        if pending.acknowledged == true, case .add = plan.action {
            // U-A (b): the strap acknowledged this set once already and the list doesn't show it as
            // written. Adding it again could repeat at every connection: finished, never re-added.
            helioLog.error("shortcuts: wake alarm the strap acknowledged isn't on it as written; not added again")
            finish(pending.id, .notConfirmed)
            return .finished
        }
        let error: String?
        switch plan.action {
        case .none(let reason):
            if reason == .expired {
                // Decision 52e: dropped, nothing sent. The outcome only: no time of day in the log.
                helioLog.notice("shortcuts: wake alarm request expired before it could be applied; dropped, strap untouched")
            } else if reason == .otherStrap {
                helioLog.notice("shortcuts: wake alarm request was made for another strap; dropped, strap untouched")
            }
            finish(pending.id, .noWrite(reason))
            return .finished
        case .refuse(let reason):
            finish(pending.id, .refused(reason))
            return .finished
        case .add(let time):
            // The editor adds in the lowest free slot (`ZeppAlarmEditor.add`); the planner saw one.
            if let slot = editor.freeSlots.first {
                store.candidate = ManagedStrapAlarm(strapID: strapID, alarm: ZeppAlarm(slot: slot, hour: time.hour,
                                                                                      minute: time.minute, days: time.days))
            }
            error = session.addAlarm(hour: time.hour, minute: time.minute, days: time.days, quiet: true)
        case .replace(let alarm):
            store.candidate = ManagedStrapAlarm(strapID: strapID, alarm: alarm)
            error = session.replaceAlarm(alarm, quiet: true)
        case .delete(let slot):
            error = session.deleteAlarm(slot: slot, quiet: true)
        }
        if let error {
            switch plan.action {
            case .add, .replace: store.candidate = nil   // nothing went out
            case .delete, .none, .refuse: break
            }
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
        case .listRead(let alarms):
            // A later list read (S2); not one racing this applier's own write on this session.
            if inFlight?.session !== session { reconcileCandidate(alarms: alarms, strapID: session.identityID) }
            guard awaitingRead === session else { return }
            awaitingRead = nil
            applyPending(on: session)
        case .listUnreadable:
            guard awaitingRead === session else { return }
            awaitingRead = nil
            readFailed = session
        case .changedOnStrap:
            break
        case .writeAcknowledged(let write):
            guard let current = inFlight, current.session === session else { return forgetRecords(touching: write.slot, on: session) }
            // U-A: remember the strap took this set, so no later connection adds it again.
            if case .set = write, var pending = store.pending, pending.id == current.requestID {
                pending.acknowledged = true
                store.pending = pending
            }
        case .writeFailed(let write, let failure):
            guard let request = takeInFlight(session, write) else { return forgetRecords(touching: write.slot, on: session) }
            outcomes[request.requestID] = .writeFailed
            // S-A (review-261b): a status refusal means the strap applied nothing, so the candidate goes;
            // a missing ack (`.noAck`) leaves it, since the strap may have applied the write.
            if case .status = failure { store.candidate = nil }
            helioLog.error("shortcuts: wake alarm write to slot \(write.slot, privacy: .public) failed (\(String(describing: failure), privacy: .public)); kept pending")
        case .writeUnverified(let write, _):
            guard let request = takeInFlight(session, write) else { return forgetRecords(touching: write.slot, on: session) }
            unconfirmed(request, write)
        case .writeChecked(let check):
            guard let request = takeInFlight(session, check.write) else {
                return forgetRecords(touching: check.write.slot, on: session)
            }
            guard check.slotMatches, check.otherSlotsUnchanged else {
                helioLog.error("shortcuts: wake alarm re-read: matches \(check.slotMatches, privacy: .public), others unchanged \(check.otherSlotsUnchanged, privacy: .public)")
                unconfirmed(request, check.write)
                return
            }
            switch check.write {
            case .set(let alarm):
                var state = store.state
                state.managed = ManagedStrapAlarm(strapID: request.strapID, alarm: alarm)
                state.candidate = nil
                store.state = state
                finish(request.requestID, .set(alarm))
            case .delete(let slot):
                store.managed = nil
                finish(request.requestID, .cleared(slot: slot))
            }
            // A newer request that arrived while this one was out goes next, on the list just read.
            if store.pending != nil { applyPending(on: session) }
        }
    }

    /// The strap acknowledged this applier's write, but its re-read didn't confirm it (or failed).
    /// - A set is FINISHED as "couldn't confirm" (review-261b U-A, option b): never re-added at a later
    ///   connection, so at most one extra slot is ever used. Its candidate stays, and a later list read
    ///   adopts it if the slot holds exactly what was written.
    /// - A delete stays pending: deleting again can't use a slot.
    private func unconfirmed(_ request: InFlight, _ write: ZeppAlarmEditor.Write) {
        switch write {
        case .set:
            helioLog.error("shortcuts: wake alarm in slot \(write.slot, privacy: .public) couldn't be confirmed; finished, not added again")
            finish(request.requestID, .notConfirmed)
        case .delete:
            outcomes[request.requestID] = .notConfirmed
            helioLog.error("shortcuts: wake alarm delete in slot \(write.slot, privacy: .public) not confirmed; kept pending")
        }
    }

    /// B1: a write this applier didn't make, to the managed slot (or the candidate's) on this strap,
    /// makes that slot the person's: the record goes, whatever the write's outcome.
    private func forgetRecords(touching slot: UInt8, on session: HelioSession) {
        var state = store.state
        let strapID = session.identityID
        var changed = false
        if let managed = state.managed, managed.strapID == strapID, managed.slot == slot {
            state.managed = nil
            changed = true
        }
        if let candidate = state.candidate, candidate.strapID == strapID, candidate.slot == slot {
            state.candidate = nil
            changed = true
        }
        guard changed else { return }
        store.state = state
        helioLog.notice("shortcuts: another write reached the managed alarm slot \(slot, privacy: .public); it is no longer OpenCircuit's")
    }

    /// S2: a candidate on this strap is adopted as the record if its slot holds exactly what was written,
    /// else dropped. A candidate for another strap waits for that strap.
    private func reconcileCandidate(alarms: [ZeppAlarm], strapID: String) {
        var state = store.state
        guard let candidate = state.candidate, candidate.strapID == strapID else { return }
        state.candidate = nil
        let adopted = alarms.first(where: { $0.slot == candidate.slot })?.hasSameSetting(as: candidate.alarm) == true
        if adopted { state.managed = candidate }
        store.state = state
        helioLog.notice("shortcuts: unconfirmed wake alarm in slot \(candidate.slot, privacy: .public) \(adopted ? "found as written; now managed" : "not on the strap as written; dropped", privacy: .public)")
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
